"""Camada de busca no LongMemEval S (amostra): lista curta e pergunta geral (W1).

D. Wu et al., LongMemEval, ICLR 2025, arXiv:2410.10813. Dados (MIT):
https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned
(longmemeval_s_cleaned.json, ~280 MB; fora do git).

Amostra usada no relatório: 10 perguntas de cada tipo (random.Random(11))
mais as 30 de abstenção, gravadas num JSON. Uso:

  python3 -I dev/bancada/longmemeval.py amostra.json saida.jsonl cache-vetores.jsonl

Mede, por pergunta: posição do trecho com a resposta no vetor, se ele
entra na lista curta (30 por vetor + 10 por palavras), a probabilidade
geral com a conversa inteira e com a lista curta, e os tokens.
"""
import sys, os, json, re, math, hashlib, threading, concurrent.futures as cf, statistics as st, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bancada

KEY = os.environ["GEMINI_API_KEY"]
AMOSTRA, SAIDA, CACHE = sys.argv[1], sys.argv[2], sys.argv[3]
W1 = ("In this conversation, has the user already told the assistant, or have the two already talked "
      "about, what this message asks? Message: «{m}»")
TRECHO_CHARS, MSG_CHARS, K_VEC, K_LEX = 2000, 3000, 30, 10

def trechos(d):
    out = []
    for sid, data, sess in zip(d["haystack_session_ids"], d["haystack_dates"], d["haystack_sessions"]):
        atual, tam, gold = [], 0, False
        for t in sess:
            linha = ("P: " if t["role"] == "user" else "A: ") + t["content"].replace("\n", " ")[:MSG_CHARS]
            if atual and tam + len(linha) > TRECHO_CHARS:
                out.append((data, atual, gold)); atual, tam, gold = [], 0, False
            atual.append(linha); tam += len(linha); gold = gold or bool(t.get("has_answer"))
        if atual:
            out.append((data, atual, gold))
    return [(f"### Trecho {k+1}, {data}\n" + "\n".join(ls), g) for k, (data, ls, g) in enumerate(out)]

cache, trava = {}, threading.Lock()
POOL = cf.ThreadPoolExecutor(12)
if os.path.exists(CACHE):
    for l in open(CACHE):
        h, v = json.loads(l); cache[h] = v

def embed(texto, tarefa):
    h = hashlib.sha1((tarefa + texto).encode()).hexdigest()
    with trava:
        if h in cache: return cache[h]
    r = bancada.post("https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent",
                     {"content": {"parts": [{"text": texto}]}, "taskType": tarefa, "outputDimensionality": 256},
                     {"x-goog-api-key": KEY}, tentativas=8)
    v = [round(x, 4) for x in r["embedding"]["values"]]
    with trava:
        cache[h] = v
        with open(CACHE, "a") as f: f.write(json.dumps([h, v]) + "\n")
    return v

def cos(a, b):
    return sum(x*y for x, y in zip(a, b)) / (math.sqrt(sum(x*x for x in a)) * math.sqrt(sum(y*y for y in b)))

PARADAS = set("the a an and or of to in on for with about what which when where who how did do does was were is are my me i you your that this it have has had from at by as be been can could would should we our there their them they any some much many".split())
def palavras(t): return [w for w in re.findall(r"[a-z0-9]+", t.lower()) if len(w) >= 4 and w not in PARADAS]

def lexical(pergunta, textos, k):
    ps = set(w[:6] for w in palavras(pergunta))
    pont = sorted(((len(ps & set(w[:6] for w in palavras(t))), -i, i) for i, t in enumerate(textos)), reverse=True)
    return [i for s, _, i in pont[:k] if s > 0]

def decidir(textos_idx, todos, pergunta):
    blocos = [(i, todos[i]) for i in textos_idx]
    grupos, atual, tam = [], [], 0
    for i, t in blocos:
        if atual and (tam + len(t) > 700000 or len(atual) >= 900):
            grupos.append(atual); atual, tam = [], 0
        atual.append((i, t)); tam += len(t)
    grupos.append(atual)
    gerais, tok = [], 0
    for g in grupos:
        qs = {"falado": {"type": "noul", "instructions": W1.format(m=pergunta)}}
        r = bancada.post("https://generativelanguage.googleapis.com/v1beta/decisions",
                         {"model": "gemini-decision-1", "input": "\n\n".join(t for _, t in g), "questions": qs},
                         {"x-goog-api-key": KEY}, tentativas=8)
        gerais.append(r["answers"]["falado"]["noul"]); tok += r["usage"]["total_input_tokens"]
    return max(gerais), tok, len(grupos)

def uma(d):
    tr = trechos(d)
    textos = [t for t, _ in tr]; gold = {i for i, (_, g) in enumerate(tr) if g}
    q = d["question"]
    qv = embed(q, "RETRIEVAL_QUERY")
    vs = list(POOL.map(lambda t: embed(t, "RETRIEVAL_DOCUMENT"), textos))
    ordem = sorted(range(len(textos)), key=lambda i: -cos(qv, vs[i]))
    lex = lexical(q, textos, K_LEX)
    lista = list(dict.fromkeys(ordem[:K_VEC] + lex))
    rank = min((ordem.index(i) + 1 for i in gold), default=None)
    p_full, tok_full, ch = decidir(range(len(textos)), textos, q)
    p_lista, tok_lista, _ = decidir(sorted(lista), textos, q)
    return dict(id=d["question_id"], tipo=d["question_type"] + ("_abs" if d["question_id"].endswith("_abs") else ""),
                n_trechos=len(textos), n_gold=len(gold), rank_vec=rank,
                vec_ok=bool(gold & set(ordem[:K_VEC])) if gold else None,
                lex_ok=bool(gold & set(lex)) if gold else None,
                lista_ok=bool(gold & set(lista)) if gold else None,
                todos_gold_na_lista=(gold <= set(lista)) if gold else None,
                p_full=p_full, p_lista=p_lista, tok_full=tok_full, tok_lista=tok_lista, chamadas_full=ch)

if __name__ == "__main__":
    A = json.load(open(AMOSTRA))
    feitos = {json.loads(l)["id"] for l in open(SAIDA)} if os.path.exists(SAIDA) else set()
    pend = [d for d in A if d["question_id"] not in feitos]
    print(len(pend), "pendentes", flush=True)
    def run(d):
        try:
            r = uma(d)
        except Exception as e:
            print("erro", d["question_id"], str(e)[:200], flush=True); return
        with trava:
            with open(SAIDA, "a") as f: f.write(json.dumps(r) + "\n")
        print(r["id"], r["tipo"], r["rank_vec"], r["lista_ok"], round(r["p_full"], 2), round(r["p_lista"], 2), flush=True)
    with cf.ThreadPoolExecutor(3) as ex:
        list(ex.map(run, pend))
