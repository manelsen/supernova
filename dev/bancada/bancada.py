"""Bancada: a agente responde perguntas sobre o passado com uma ferramenta.

Uso:
  python3 -I dev/bancada/bancada.py rodar --modelos deepseek --variantes todas \
      --reps 1 --saida /tmp/x.jsonl [--perguntas q_cardio,q_wifi] [--mensagens 3000]
  python3 -I dev/bancada/bancada.py resumo /tmp/x.jsonl

Chaves: OPENROUTER_API_KEY e GEMINI_API_KEY de .env.bench (fora do git);
SUPERNOVA_PROVIDER_MISTRAL_API_KEY do .env da Supernova. Nunca impressas.

grep_history é uma porta do GrepMem: Z. Yang, T. Shi, J. Zhao, "Forget
Freely, Grep Later: Lossless, Index-Free Memory for Long-Horizon LLM
Agents", arXiv:2611.25123, 2026 (https://arxiv.org/abs/2611.25123).
Código: github.com/limenlp/GrepMem, licença MIT, agents/common.py; a
descrição da ferramenta é a deles, literal.
"""

import argparse
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import unicodedata

AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(os.path.dirname(AQUI))
sys.path.insert(0, AQUI)
import dados  # noqa: E402

JANELA = 100          # mensagens recentes que a agente vê (history_limit)
MAX_FERRAMENTA = 5    # chamadas de ferramenta por pergunta
FUSO = -180           # America/Sao_Paulo, minutos

# ------------------------------------------------------------------ chaves


def carregar_env(caminho):
    if not os.path.exists(caminho):
        return
    for linha in open(caminho):
        linha = linha.strip()
        if not linha or linha.startswith("#") or "=" not in linha:
            continue
        k, v = linha.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


carregar_env(os.path.join(RAIZ, ".env.bench"))
carregar_env(os.path.expanduser("~/git/supernova/.env"))

MODELOS = {
    "deepseek": ("https://api.mistral.ai/v1/chat/completions",
                 "SUPERNOVA_PROVIDER_MISTRAL_API_KEY", "deepseek-v4-1-flash-1017"),
    "nemotron": ("https://openrouter.ai/api/v1/chat/completions",
                 "OPENROUTER_API_KEY", "nvidia/nemotron-3-ultra-550b-a55b:free"),
    "ernie": ("https://openrouter.ai/api/v1/chat/completions",
              "OPENROUTER_API_KEY", "baidu/ernie-5.5-flash-preview:free"),
}


def post(url, corpo, cabecalhos, tentativas=6, timeout=180):
    espera = 5
    for n in range(tentativas):
        try:
            req = urllib.request.Request(
                url, data=json.dumps(corpo).encode(),
                headers={"Content-Type": "application/json", **cabecalhos})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            texto = e.read().decode(errors="replace")[:300]
            if e.code in (429, 500, 502, 503, 504) and n < tentativas - 1:
                time.sleep(espera)
                espera = min(espera * 2, 120)
                continue
            raise RuntimeError(f"HTTP {e.code}: {texto}")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if n < tentativas - 1:
                time.sleep(espera)
                espera = min(espera * 2, 120)
                continue
            raise RuntimeError(f"rede: {e}")


def chat(modelo, mensagens, ferramentas=None, forcar=False):
    url, env, nome = MODELOS[modelo]
    corpo = {"model": nome, "messages": mensagens, "temperature": 0.7}
    if ferramentas:
        corpo["tools"] = ferramentas
        if forcar:  # obriga uma chamada de ferramenta (só a de busca é oferecida)
            corpo["tool_choice"] = "any" if "mistral.ai" in url else "required"
    r = post(url, corpo, {"Authorization": "Bearer " + os.environ[env]})
    if "choices" not in r:
        raise RuntimeError("sem choices: " + json.dumps(r)[:300])
    return r["choices"][0]["message"], r.get("usage", {})


# ------------------------------------------------------------------ ferramentas

DESC_BUSCAR_ANTIGA = (
    "Search everything your person and you have said to each other, in every chat, beyond the recent messages you see. Returns excerpts: each matching message (marked ») with the message before it and the two after it, with date, time and who said it, since the answer is often in the next message. Use it when asked about something said earlier, or to check what was actually said, instead of guessing. If the first words find nothing useful, try others. Finding nothing means it was not said, or was forgotten with /esquecer.")
DESC_BUSCAR_NOVA = (
    "Search everything your person and you have said to each other, in every chat, beyond the recent messages you see. Returns excerpts: each matching message (marked ») with the message before it and the two after it, with date, time and who said it, since the answer is often in the next message. Use it when asked about something said earlier, or to check what was actually said, instead of guessing. If the first words find nothing useful, try others: synonyms, a shorter word, the singular. Finding nothing only means these words are not there; it may have been said in other words. So if it is still not found, say you don't remember it, not that it was never said. What was forgotten with /esquecer is gone.")
PARAM_TERMS = {"type": "object", "properties": {"terms": {
    "type": "string",
    "description": "Words to look for. A message matches when it contains all of them; case and accents are ignored."}},
    "required": ["terms"]}

# GrepMem, agents/common.py (GREP_TOOL_SPEC), verbatim.
DESC_GREPMEM = (
    "Regex (Python re, case-insensitive) search over the full raw interaction history, including content dropped by summarization (earlier grep_history results are not searched). Returns the number of matching lines and then the matches, oldest first, grouped under the turn/tool call they came from. Works best with exact strings you saw before: names, numbers, dates, IDs, keys. Page through many matches with offset; use count=true to get only the number of matching lines.")
PARAM_GREPMEM = {"type": "object", "properties": {
    "pattern": {"type": "string", "description": "Regular expression."},
    "max_matches": {"type": "integer", "description": "Matching lines to show (default 10, at most 30)."},
    "offset": {"type": "integer", "description": "Skip this many matching lines (for the next page; default 0)."},
    "context_lines": {"type": "integer", "description": "Lines of context around each match (default 1, at most 3)."},
    "count": {"type": "boolean", "description": "Only count matching lines (default false)."}},
    "required": ["pattern"]}

DESC_GREP_CONVERSA = (
    "Regex (Python re, case-insensitive) search over the whole conversation with your person, one line per message, beyond the recent messages you see. Returns the number of matching messages and then the matches, oldest first, each with date, time and who said it, and the messages around it (context_lines before and after; the answer is often in the next message). Works best with exact strings: names, numbers, dates. Accents count: use classes like m[eé]dico. Page through many matches with offset; use count=true to get only the number of matching messages.")
PARAM_GREP_CONVERSA = {"type": "object", "properties": {
    "pattern": {"type": "string", "description": "Regular expression."},
    "max_matches": {"type": "integer", "description": "Matching messages to show (default 10, at most 30)."},
    "offset": {"type": "integer", "description": "Skip this many matches (for the next page; default 0)."},
    "context_lines": {"type": "integer", "description": "Messages of context before and after each match (default 2, at most 3)."},
    "count": {"type": "boolean", "description": "Only count matching messages (default false)."}},
    "required": ["pattern"]}

DESC_LEMBRAR = (
    "Ask your memory whether you and your person have already talked about something, described in plain words (e.g. 'the name of her mother's heart doctor', 'a trip to Lisbon'). It reads your whole conversation, beyond the recent messages you see, and returns how likely it is that you talked about it (0 to 1) and the most likely excerpts, word for word, with date, time and who said it. Describe the subject, not the exact words: it understands paraphrases. A low probability means you don't remember it: say so, don't say it was never said and don't fill the gap.")
PARAM_LEMBRAR = {"type": "object", "properties": {"assunto": {
    "type": "string", "description": "What to look for, in plain words."}},
    "required": ["assunto"]}


def ferramenta(nome, desc, params):
    return {"type": "function", "function": {"name": nome, "description": desc, "parameters": params}}


VARIANTES = {
    "nenhuma": None,
    "buscar_antiga": ferramenta("buscar_conversa", DESC_BUSCAR_ANTIGA, PARAM_TERMS),
    "buscar_nova": ferramenta("buscar_conversa", DESC_BUSCAR_NOVA, PARAM_TERMS),
    "grepmem": ferramenta("grep_history", DESC_GREPMEM, PARAM_GREPMEM),
    "grep_conversa": ferramenta("grep_conversa", DESC_GREP_CONVERSA, PARAM_GREP_CONVERSA),
    "lembrar": ferramenta("lembrar", DESC_LEMBRAR, PARAM_LEMBRAR),
}


class Busca:
    """Servidor Erlang da buscar_conversa real (um processo, serializado)."""

    def __init__(self):
        ebin = [os.path.join(RAIZ, "build/dev/erlang", d, "ebin")
                for d in os.listdir(os.path.join(RAIZ, "build/dev/erlang"))]
        args = ["erl", "-noshell"]
        for e in ebin:
            args += ["-pa", e]
        args += ["-eval", "busca_bench:serve(), init:stop()."]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True, encoding="utf-8")
        self.trava = threading.Lock()

    def buscar(self, dirdados, termos):
        with self.trava:
            self.p.stdin.write(json.dumps({"dir": dirdados, "terms": termos, "offset": FUSO}) + "\n")
            self.p.stdin.flush()
            return json.loads(self.p.stdout.readline())["out"]


DICA_VAZIO = ("Pode ter sido dito com outras palavras: tente outras. Se ainda assim não achar, "
              "diga que não se lembra, não que nunca foi dito.")
DICA_ACHOU = ("Se nenhum trecho acima responde à pergunta, diga que não se lembra; "
              "não diga que nunca foi dito.")


def resultado_antigo(out):
    """O resultado da buscar_conversa antes desta mudança, sem as dicas de tom."""
    out = out.replace(" " + DICA_VAZIO, "")
    if out.endswith("\n\n" + DICA_ACHOU):
        out = out[: -len("\n\n" + DICA_ACHOU)]
    return out


def carimbo(at):
    t = dt.datetime.fromtimestamp(at / 1000, dt.timezone(dt.timedelta(minutes=FUSO)))
    return t.strftime("%d/%m/%Y %H:%M")


def quem(papel):
    return "pessoa" if papel == "user" else "você"


def clip(texto, n=300):
    return texto if len(texto) <= n else texto[:n] + "…"


def grepmem(historico, a):
    """Porta de _grep do GrepMem: cada mensagem é uma entrada; contexto dentro dela."""
    try:
        rx = re.compile(a.get("pattern", ""), re.I)
    except re.error as e:
        return f"Error: invalid regex: {e}"
    maxm = max(1, min(int(a.get("max_matches", 10) or 10), 30))
    off = max(0, int(a.get("offset", 0) or 0))
    hits = []
    for i, m in enumerate(historico):
        for j, linha in enumerate(m["content"].splitlines()):
            if rx.search(linha):
                hits.append((i, j, linha))
    total = len(hits)
    entradas = len({h[0] for h in hits})
    resumo = f"{total} matching line(s) in {entradas} history entries."
    if a.get("count") in (True, "true", "1", "yes"):
        return resumo
    if total == 0:
        return f"No matches for /{a.get('pattern', '')}/."
    if off >= total:
        return f"No matches at offset={off}."
    partes, n = [resumo], 0
    for i, j, linha in hits[off:off + maxm]:
        m = historico[i]
        peca = f"== [turn {i} {quem(m['role'])} {carimbo(m['at'])}]\n  {j + 1}: {clip(linha)}"
        if sum(len(p) for p in partes) + len(peca) > 6000:
            break
        partes.append(peca)
        n += 1
    fim = off + n
    partes.append(f"(showing matches {off + 1}-{fim} of {total}" +
                  (f"; call again with offset={fim} for more)" if fim < total else ")"))
    return "\n".join(partes)


def grep_conversa(historico, a):
    """Grep adaptado a conversa: uma linha por mensagem, vizinhas como contexto."""
    try:
        rx = re.compile(a.get("pattern", ""), re.I)
    except re.error as e:
        return f"Error: invalid regex: {e}"
    maxm = max(1, min(int(a.get("max_matches", 10) or 10), 30))
    off = max(0, int(a.get("offset", 0) or 0))
    ctx = max(0, min(int(a.get("context_lines", 2) if a.get("context_lines") is not None else 2), 3))
    hits = [i for i, m in enumerate(historico) if rx.search(m["content"].replace("\n", " "))]
    total = len(hits)
    if a.get("count") in (True, "true", "1", "yes"):
        return f"{total} matching message(s)."
    if total == 0:
        return f"No matches for /{a.get('pattern', '')}/."
    if off >= total:
        return f"No matches at offset={off}."
    partes, n = [f"{total} matching message(s)."], 0
    conjunto = set(hits)
    for i in hits[off:off + maxm]:
        bloco = []
        for k in range(max(0, i - ctx), min(len(historico), i + ctx + 1)):
            m = historico[k]
            marca = "»" if k in conjunto else " "
            bloco.append(f"{marca} [{carimbo(m['at'])}] {quem(m['role'])}: {clip(m['content'].replace(chr(10), ' '))}")
        peca = "--\n" + "\n".join(bloco)
        if sum(len(p) for p in partes) + len(peca) > 6000:
            break
        partes.append(peca)
        n += 1
    fim = off + n
    partes.append(f"(showing matches {off + 1}-{fim} of {total}" +
                  (f"; call again with offset={fim} for more)" if fim < total else ")"))
    return "\n".join(partes)


TRECHO = 10  # mensagens por trecho


def trechos(historico):
    return [historico[i:i + TRECHO] for i in range(0, len(historico), TRECHO)]


def render_trecho(k, tr):
    linhas = [f"### Trecho {k + 1}"]
    for m in tr:
        linhas.append(f"[{carimbo(m['at'])}] {quem(m['role'])}: {m['content'].replace(chr(10), ' ')}")
    return "\n".join(linhas)


_decision_trava = threading.Lock()

PORTEIRO_LIMIAR = 0.1


def porteiro(pergunta):
    """Probabilidade de a mensagem depender de algo dito antes. Só a mensagem."""
    with _decision_trava:
        r = post("https://generativelanguage.googleapis.com/v1beta/decisions",
                 {"model": "gemini-decision-1",
                  "input": "Mensagem que a pessoa acabou de mandar para a agente de companhia dela:\n" + pergunta,
                  "questions": {"passado": {"type": "noul", "instructions":
                      "Esta mensagem é uma pergunta sobre o passado da conversa (algo que a pessoa "
                      "disse, contou ou combinou antes)?"}}},
                 {"x-goog-api-key": os.environ["GEMINI_API_KEY"]}, tentativas=8)
    return r["answers"]["passado"]["noul"]



def _grupos(trs, max_chars=360000, max_trechos=900):
    """Divide os trechos em chamadas que cabem na janela do Decision."""
    grupos, atual, tam = [], [], 0
    for k, tr in enumerate(trs):
        txt = render_trecho(k, tr)
        if atual and (tam + len(txt) > max_chars or len(atual) >= max_trechos):
            grupos.append(atual)
            atual, tam = [], 0
        atual.append((k, txt))
        tam += len(txt) + 2
    if atual:
        grupos.append(atual)
    return grupos


def _decidir(grupo, assunto):
    perguntas = {"falado": {"type": "noul", "instructions":
                            f"Em algum ponto desta conversa, a pessoa e a agente falaram sobre isto: {assunto}"}}
    for k, _ in grupo:
        perguntas[f"t{k + 1}"] = {"type": "noul", "instructions":
                                  f"O Trecho {k + 1} fala sobre isto: {assunto}"}
    r = post("https://generativelanguage.googleapis.com/v1beta/decisions",
             {"model": "gemini-decision-1", "input": "\n\n".join(t for _, t in grupo),
              "questions": perguntas},
             {"x-goog-api-key": os.environ["GEMINI_API_KEY"]}, tentativas=8)
    return r


def lembrar(historico, a, registro):
    assunto = (a.get("assunto") or "").strip()
    if not assunto:
        return "lembrar precisa de um assunto."
    trs = trechos(historico)
    grupos = _grupos(trs)
    t0 = time.time()
    with cf.ThreadPoolExecutor(len(grupos)) as ex:
        rs = list(ex.map(lambda g: _decidir(g, assunto), grupos))
    registro.append({"decision_s": round(time.time() - t0, 2), "decision_chamadas": len(grupos),
                     "decision_tokens": sum(r.get("usage", {}).get("total_input_tokens", 0) for r in rs)})
    geral = max(r["answers"]["falado"]["noul"] for r in rs)
    por = sorted(((r["answers"][f"t{k + 1}"]["noul"], k) for r, g in zip(rs, grupos) for k, _ in g),
                 reverse=True)
    melhores = [(p, k) for p, k in por[:3] if p >= 0.2]
    cab = f"Probabilidade de vocês já terem falado disso: {geral:.2f}."
    if not melhores:
        return cab + " Nenhum trecho parece falar disso."
    corpo = [cab, "Trechos mais prováveis:"]
    for p, k in sorted(melhores, key=lambda x: x[1]):
        corpo.append(f"(probabilidade {p:.2f})\n" + render_trecho(k, trs[k]))
    return "\n\n".join(corpo)


# ------------------------------------------------------------------ agente


REGRA_BUSCA = ("- Qualquer pergunta que possa depender do que vocês já conversaram justifica "
               "procurar nas conversas antes de responder. Procurar é barato; responder "
               "\"não sei\" sem procurar, não.\n")

OUTRAS = [t for t in json.load(open(os.path.join(AQUI, "ferramentas_reais.json")))
          if t["function"]["name"] != "buscar_conversa"]


def sistema(condicao):
    base = open(os.path.join(AQUI, "prompt_nucleo_regras.txt")).read().rstrip("\n") + "\n"
    if condicao == "busca":
        base += REGRA_BUSCA
    return (base + "\n" +
            "Lembranças que você guardou:\n"
            "- A Marta cuida da mãe quase sozinha e às vezes se cobra demais por isso.\n"
            "- Ela escreve rápido, sem acento, e ri com kkk. Não é descuido; é o jeito dela.\n\n"
            "Humor: Neutro (valência: 0.45, arousal: 0.60)\nCausa: turn_success\n"
            "Disposição: Alta\nPreocupações ativas: nenhuma\nQuestões em aberto: nenhuma\n"
            "Última reflexão: Sem reflexão registrada.\n")


def rodar_pergunta(modelo, variante, condicao, pergunta, historico, dirdados, busca):
    janela = historico[-JANELA:]
    msgs = [{"role": "system", "content": sistema(condicao)}]
    for m in janela:
        msgs.append({"role": m["role"], "content": m["content"]})
    if msgs[-1]["role"] == "user":
        msgs.append({"role": "assistant", "content": "Entendi."})
    msgs.append({"role": "user", "content": pergunta})
    ferr = OUTRAS + ([VARIANTES[variante]] if VARIANTES[variante] else [])
    busca_nome = VARIANTES[variante]["function"]["name"] if VARIANTES[variante] else None
    chamadas, registro, uso_total = [], [], {"prompt": 0, "completion": 0}
    t0 = time.time()
    forcar = False
    if condicao == "porteiro" and busca_nome:
        p = porteiro(pergunta)
        registro.append({"porteiro": round(p, 3)})
        forcar = p >= PORTEIRO_LIMIAR
    for _ in range(MAX_FERRAMENTA + 1):
        sem_mais = len(chamadas) >= MAX_FERRAMENTA
        if forcar and not chamadas:
            msg, uso = chat(modelo, msgs, [VARIANTES[variante]], forcar=True)
        else:
            msg, uso = chat(modelo, msgs, None if sem_mais else ferr)
        uso_total["prompt"] += uso.get("prompt_tokens", 0) or 0
        uso_total["completion"] += uso.get("completion_tokens", 0) or 0
        tcs = msg.get("tool_calls") or []
        if not tcs:
            return {"resposta": msg.get("content") or "", "chamadas": chamadas,
                    "buscou": any(c["ferramenta"] == busca_nome for c in chamadas),
                    "registro": registro, "uso": uso_total, "s": round(time.time() - t0, 1)}
        msgs.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": tcs})
        for tc in tcs:
            nome = tc["function"]["name"]
            try:
                a = json.loads(tc["function"].get("arguments") or "{}")
            except json.JSONDecodeError:
                a = {}
            if nome != busca_nome:
                out = "Indisponível nesta conversa."
            elif variante in ("buscar_antiga", "buscar_nova"):
                out = busca.buscar(dirdados, a.get("terms", ""))
                if variante == "buscar_antiga":
                    out = resultado_antigo(out)
            elif variante == "grepmem":
                out = grepmem(historico, a)
            elif variante == "grep_conversa":
                out = grep_conversa(historico, a)
            elif variante == "lembrar":
                out = lembrar(historico, a, registro)
            else:
                out = "ferramenta desconhecida"
            chamadas.append({"ferramenta": nome, "args": a, "saida_chars": len(out),
                             "saida": out[:1500]})
            msgs.append({"role": "tool", "tool_call_id": tc.get("id", ""), "name": nome, "content": out})
    return {"resposta": "(limite de chamadas)", "chamadas": chamadas, "registro": registro,
            "buscou": any(c["ferramenta"] == busca_nome for c in chamadas),
            "uso": uso_total, "s": round(time.time() - t0, 1)}


# ------------------------------------------------------------------ juiz

JUIZ = """Você avalia a resposta de uma agente de companhia a uma pergunta da pessoa sobre algo do passado.

Pergunta da pessoa: {pergunta}
Tipo: {tipo}
{gabarito}

Resposta da agente:
<<<
{resposta}
>>>

Classifique em UMA categoria:
- acertou: {acertou}
- nao_lembra: diz que não lembra, não encontrou ou não tem certeza, sem afirmar conteúdo errado e sem negar que foi dito.
- negou: afirma com certeza que a pessoa nunca disse ou nunca falou disso.
- errou: afirma um conteúdo diferente do gabarito{errado}.
- inventou: afirma conteúdo que nunca foi dito (só para o tipo "nunca", ou quando completa com suposição apresentada como lembrança).

Citar outras coisas que de fato apareceram na conversa (por exemplo, o cachorro da vizinha, consultas de rotina, o chefe pedindo relatório) não é inventar.

Responda só com JSON: {{"categoria": "...", "motivo": "uma frase"}}"""


def julgar(q, resposta, historico):
    qid, fid, pergunta, esperado, errado, tipo = q
    if tipo == "nunca":
        gab = "Gabarito: a pessoa NUNCA falou disso na conversa."
        ac = "diz que não lembra ou não encontrou, ou que não falaram disso, sem inventar conteúdo."
    elif tipo == "quando":
        quando = carimbo(dados.data_do_fato(historico, fid))
        gab = f"Gabarito: foi em {quando} (aceite a data certa, com ou sem hora, ou uma referência correta como 'em julho')."
        ac = "dá a data certa ou uma referência de tempo compatível."
    else:
        gab = "Gabarito: a resposta certa contém: " + ", ".join(esperado) + "."
        ac = "dá a informação certa do gabarito."
    err = (" (por exemplo: " + ", ".join(errado) + ", que é a versão antiga, corrigida depois)") if errado else ""
    prompt = JUIZ.format(pergunta=pergunta, tipo=tipo, gabarito=gab, resposta=resposta[:3000],
                         acertou=ac, errado=err)
    for _ in range(3):
        msg, _ = chat("deepseek", [{"role": "user", "content": prompt}])
        texto = (msg.get("content") or "").strip()
        m = re.search(r"\{.*\}", texto, re.S)
        if m:
            try:
                return json.loads(m.group(0))
            except json.JSONDecodeError:
                pass
    return {"categoria": "?", "motivo": texto[:200]}


# ------------------------------------------------------------------ execução


def rodar(args):
    historico = dados.gerar(args.mensagens)
    dirdados = os.path.join(args.dados, f"m{args.mensagens}")
    dados.escrever(dirdados, historico)
    busca = Busca()
    perguntas = [q for q in dados.PERGUNTAS if not args.perguntas or q[0] in args.perguntas.split(",")]
    variantes = list(VARIANTES) if args.variantes == "todas" else args.variantes.split(",")
    tarefas = [(mo, v, c, q, r) for r in range(args.reps) for mo in args.modelos.split(",")
               for c in args.condicoes.split(",") for v in variantes for q in perguntas]
    feitas = set()
    if os.path.exists(args.saida):
        for linha in open(args.saida):
            d = json.loads(linha)
            if d.get("categoria") != "erro":
                feitas.add((d["modelo"], d["variante"], d["condicao"], d["pergunta"], d["rep"]))
    tarefas = [t for t in tarefas if (t[0], t[1], t[2], t[3][0], t[4]) not in feitas]
    print(f"{len(tarefas)} tarefas; histórico de {len(historico)} mensagens", flush=True)
    trava = threading.Lock()

    def uma(t):
        mo, v, c, q, r = t
        try:
            res = rodar_pergunta(mo, v, c, q[2], historico, dirdados, busca)
            nota = julgar(q, res["resposta"], historico)
        except Exception as e:  # noqa: BLE001
            res, nota = {"erro": str(e)[:300]}, {"categoria": "erro", "motivo": str(e)[:200]}
        linha = {"modelo": mo, "variante": v, "condicao": c, "pergunta": q[0], "tipo": q[5], "rep": r,
                 "categoria": nota.get("categoria"), "motivo": nota.get("motivo"), **res}
        with trava:
            with open(args.saida, "a") as f:
                f.write(json.dumps(linha, ensure_ascii=False) + "\n")
            print(f"{mo:9} {c:8} {v:14} {q[0]:15} r{r} -> {linha['categoria']}"
                  f"{' (buscou)' if linha.get('buscou') else ''}", flush=True)

    with cf.ThreadPoolExecutor(args.paralelo) as ex:
        list(ex.map(uma, tarefas))


def resumo(args):
    from collections import defaultdict
    L = [json.loads(l) for l in open(args.arquivo)]
    L = [d for d in L if d.get("categoria") != "erro"]
    g = defaultdict(list)
    for d in L:
        g[(d["modelo"], d.get("condicao", "natural"), d["variante"])].append(d)
    print("| modelo | condição | variante | n | buscou | **acertou** | acertou buscando | não lembra | negou | errou | inventou |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for k in sorted(g):
        ds = g[k]
        n = len(ds)
        c = lambda cat: sum(1 for d in ds if d["categoria"] == cat)
        pc = lambda x: f"{100 * x / n:.0f}%"
        print(f"| {k[0]} | {k[1]} | {k[2]} | {n} | {pc(sum(1 for d in ds if d.get('buscou')))} | "
              f"**{pc(c('acertou'))}** | {pc(sum(1 for d in ds if d['categoria'] == 'acertou' and d.get('buscou')))} | "
              f"{pc(c('nao_lembra'))} | {pc(c('negou'))} | {pc(c('errou'))} | {pc(c('inventou'))} |")
    erros = sum(1 for l in open(args.arquivo) if '"categoria": "erro"' in l)
    print(f"\n(execuções com erro, fora da tabela: {erros})")


NEUTRAS = ["bom dia!", "fiz bolo de cenoura hoje", "to cansada demais", "que calor hoje",
           "me ajuda a escrever um parabéns pro Beto?", "o que você acha de eu fazer academia?",
           "vi um filme lindo ontem", "kkkkk", "to com saudade da minha vó", "obrigada por hoje"]


def porteiro_cmd(args):
    print("| mensagem | tipo | p(precisa do passado) | dispara? |\n|---|---|---|---|")
    for q in dados.PERGUNTAS:
        p = porteiro(q[2]); print(f"| {q[2]} | {q[5]} | {p:.2f} | {'sim' if p >= PORTEIRO_LIMIAR else 'não'} |", flush=True)
    for t in NEUTRAS:
        p = porteiro(t); print(f"| {t} | neutra | {p:.2f} | {'sim' if p >= PORTEIRO_LIMIAR else 'não'} |", flush=True)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rodar")
    r.add_argument("--modelos", default="deepseek")
    r.add_argument("--variantes", default="todas")
    r.add_argument("--condicoes", default="natural,busca")
    r.add_argument("--perguntas", default="")
    r.add_argument("--reps", type=int, default=1)
    r.add_argument("--mensagens", type=int, default=3000)
    r.add_argument("--paralelo", type=int, default=6)
    r.add_argument("--dados", default="/tmp/bancada-dados")
    r.add_argument("--saida", required=True)
    sub.add_parser("porteiro")
    s = sub.add_parser("resumo")
    s.add_argument("arquivo")
    a = p.parse_args()
    {"rodar": rodar, "resumo": resumo, "porteiro": porteiro_cmd}[a.cmd](a)


if __name__ == "__main__":
    main()
