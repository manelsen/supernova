[PRD]
# PRD M: A agente lembra do que foi dito

> **Situação em 24/11/2026:** aprovada pelo mantenedor e executada (M-00 a
> M-08, branch `prd-m/execucao`). D1 a D5 decididas (seção 5). Ligar no
> piloto é decisão do mantenedor: chave paga do Gemini (conferir o
> faturamento do projeto; no plano gratuito o Google pode usar o conteúdo)
> e `conversation.recall.enabled: true`.

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio. Se a sessão for interrompida, retome pela
> primeira história sem commit, conferindo `git log --oneline` contra os
> títulos de commit.

## 1. Contexto

A pessoa pergunta algo que contou há semanas, fora das 100 mensagens que a
agente vê. A conversa inteira está no disco, e a `buscar_conversa` procura
nela por palavras. A bancada de busca
([relatório](../relatorios/BUSCA-bancada.md), [código](../../dev/bancada))
mediu o que acontece, com histórico sintético e o modelo da Selene:

1. **A agente quase nunca busca.** Com o prompt de hoje, o DeepSeek chamou a
   `buscar_conversa` em 6% das perguntas sobre o passado e acertou 8%. No
   resto, respondeu "não sei" ou negou com certeza.
2. **Um porteiro resolve.** O Gemini Decision 1 lê só a mensagem que chegou
   e diz se ela pergunta sobre o passado. Em 45 mensagens que não serviram
   para ajustá-lo, pegou 15 de 15 perguntas e disparou em 0 de 30 mensagens
   comuns. Com ele, a agente sempre busca.
3. **Busca por palavras perde na paráfrase.** "A cirurgia da minha mãe",
   quando ela disse "vai ser operada": 0 de 5 com a `buscar_conversa` e com
   grep. O Decision lendo a conversa em trechos (`lembrar`) acertou 60 de 60
   perguntas sobre fatos nos três modelos, e 24 de 24 com um histórico de 12
   mil mensagens.
4. **O erro que sobra é negar.** Sobre o que nunca foi dito, a agente diz
   "você nunca me falou disso" em vez de "acho que não". Com a
   probabilidade do Decision virando o tom no resultado do `lembrar`, a
   negação sem dúvida caiu de 6 em 24 para 1 em 24 ("acho que você nunca me
   disse o nome dele" é o tom aprovado).
5. **Dá para fazer barato.** Lendo só 40 trechos escolhidos por vetor e por
   palavras, em formato enxuto, o Decision usa 15× menos tokens (~US$ 0,0006
   por consulta), responde em 0,65 s e mantém 36 de 36 fatos. No
   LongMemEval [relatório], a lista curta conteve a resposta em 59 de 59
   perguntas.

## 2. Objetivo

Quando a pessoa pergunta sobre o passado, a agente procura sempre, acha o
que foi dito mesmo com outras palavras, e, quando não acha, diz que não se
lembra com a dúvida certa. Mensagens que não falam do passado seguem como
hoje, sem custo nem atraso perceptível.

## 3. Fora de escopo

- **Árvore de resumos ou bisseção** (D3). Com a lista curta, o custo por
  consulta não cresce com a conversa; a árvore volta se a lista curta
  deixar de conter a resposta (métrica de correção, 6.6).
- **Índice** para a `buscar_conversa`.
- **Trocar a `buscar_conversa`.** Ela fica: acha o exato (números, códigos)
  e é a reserva quando o Decision não responde.
- **Mudar o núcleo de regras** (`priv/constellation`).

## 4. Quality gates

Obrigatórios ao fim de **toda** história:

```bash
gleam format --check src test
gleam build --warnings-as-errors
gleam test
make coverage
git status --short    # nenhum arquivo novo gerado pelos testes
```

**Regras:**
- **Sem rede, tokens ou serviços reais** nos testes. O cliente do Decision
  recebe a função que faz a chamada; os testes passam uma falsa.
- **Subjects do Erlang:** só o processo dono recebe num subject.
- **Sem `process.sleep` fixo** para estabelecer estado concorrente.
- **TDD:** o teste falha pelo motivo esperado antes da implementação; a
  falha vai na mensagem de commit.
- **Cobertura** nunca abaixo do valor do início da história.
- **Nada da conversa em log ou auditoria**: só probabilidades, tamanhos,
  tempos e custos.

## 5. Decisões do mantenedor

- **D1. O que o porteiro faz quando dispara.**
  - (a) Obriga a agente a buscar: a primeira chamada do turno é uma
    ferramenta de busca, com as palavras que ela escolher.
  - (b) Pré-busca: a Supernova chama o `lembrar` com a mensagem da pessoa e
    põe o resultado no turno como se a agente o tivesse chamado, antes da
    primeira chamada ao LLM.
  - **Recomendação: (b).** Empata ou ganha em tudo, sem ida a mais ao LLM e
    sem depender de cada provedor forçar ferramenta.
  - **Medição** (bancada, 16 perguntas; DeepSeek 3 repetições, Nemotron 2;
    "ambas" é `lembrar` + `buscar_conversa`):

    | | Fatos | Nunca dito | Negou | Tempo (mediana) |
    |---|---|---|---|---|
    | DeepSeek, (a) ambas | 35/36 | 4/12 | 8% | 2,7 s |
    | DeepSeek, **(b) ambas** | **36/36** | **6/12** | **6%** | **2,2 s** |
    | Nemotron, (a) ambas | 19/24 | 4/8 | 6% | 6,8 s |
    | Nemotron, **(b) ambas** | **24/24** | 3/8 | **3%** | **4,8 s** |

    O Decision levou 1,4 s de mediana (p90 1,6 s) com ~93 mil tokens. Os
    casos de ~78 s na bancada são esperas por limite de requisições com
    execuções em paralelo, não o modelo; no produto, o tempo-limite de 15 s
    (D5) corta isso e o turno segue com a `buscar_conversa`.
- **D2. Privacidade.** Cada `lembrar` manda a conversa da pessoa ao Gemini.
  **Aprovado:** chave paga com ZDR basta.
- **D3. Árvore de resumos.** **Aprovado:** fica para o futuro (seção 3).
- **D4. Nome da ferramenta.** **Aprovado:** `lembrar`.
- **D5. Quando o Decision não responde.** **Aprovado (esqueleto):** o turno
  segue sem ele. Queda é improvável; o caso real é lentidão (na bancada, 6
  consultas grandes simultâneas levaram o p90 a 78 s pelo limite de tokens
  por minuto). **Aprovado:** tempo-limite do porteiro, 2 s; do `lembrar`,
  15 s.

## 6. Desenho

### 6.1 Cliente do Decision

`supernova/memory/decision`: uma chamada `POST
/v1beta/decisions` com `model: gemini-decision-1`, um `input` e perguntas
`noul`. Devolve as probabilidades por chave, ou um erro (tempo esgotado,
HTTP, limite). A chave vem de `SUPERNOVA_GEMINI_API_KEY`. Recebe a função de
transporte, para os testes.

### 6.2 Configuração

```yaml
conversation:
  history_limit: 100
  recall:
    enabled: false            # porteiro e lembrar
    gate_threshold: 0.1
    gate_timeout_ms: 2000
    recall_timeout_ms: 15000
```

`enabled: true` sem a chave no ambiente é erro de configuração no boot.
Com `enabled: false`, nada muda em relação a hoje (I5).

### 6.3 Porteiro

Na fase anterior ao LLM, que já roda na fila de cada chat (PRD-P, P-05),
antes de o turno começar. Pergunta, só sobre a mensagem que chegou:

> Esta mensagem é uma pergunta sobre o passado da conversa (algo que a
> pessoa disse, contou ou combinou antes)?

Dispara com probabilidade ≥ `gate_threshold`. Num grupo, a mensagem é só a
da pessoa. Mensagens de comando (`/esquecer`) não passam pelo porteiro. A
auditoria registra a probabilidade e o tempo, nunca o texto.

### 6.4 `lembrar`

Ferramenta nova, ao lado da `buscar_conversa`, com o mesmo escopo: só as
conversas da própria pessoa (privado e o lado dela nos grupos), só o que foi
dito (usuário e agente, sem chamadas de ferramenta).

**Trechos.** A conversa vira trechos de 10 mensagens em formato enxuto: a
data uma vez por trecho (e de novo quando o dia muda), `P:` e `A:` no lugar
do papel. Metade do texto no formato com data e hora em cada mensagem era
cabeçalho; o enxuto corta ~45% dos tokens sem mudar as probabilidades
(relatório, "Custo").

**Índice.** Cada trecho fechado é vetorizado uma vez
(`gemini-embedding-2`, 256 dimensões, US$ 0,20 por milhão de tokens) e
guardado junto das conversas da pessoa. O trecho aberto é vetorizado de
novo quando muda. O `/esquecer` apaga o índice com as conversas (I4).

**Lista curta.** Para cada consulta: os 30 trechos mais próximos pelo vetor
mais os 10 com mais palavras em comum (sem acento, prefixo de 5 letras), sem
repetir. No LongMemEval, a lista conteve o trecho com a resposta em 59 de 59
perguntas (o pior, 24º no vetor); só por palavras, 47 de 59; preferências,
2 de 10 por palavras e 10 de 10 pelo vetor.

**Decision.** Uma chamada sobre a lista curta: a pergunta geral

> Nesta conversa, a pessoa já contou à agente, ou as duas já conversaram,
> sobre o que esta mensagem pergunta? Mensagem: «{assunto}»

e uma pergunta por trecho. ~6 mil tokens no tamanho da bancada, ~11 mil no
LongMemEval, contra ~93 mil e ~115 mil lendo a conversa inteira.

**Resultado.** O tom pela probabilidade geral, depois até 3 trechos com
probabilidade ≥ 0,2, literais, em ordem de tempo:

- < 0,2: "Pouco provável que vocês tenham falado disso. Diga que acha que
  não, sem afirmar com certeza que nunca foi dito." No LongMemEval, só 2 de
  59 perguntas respondíveis caíram aqui.
- 0,2 a 0,75: "Talvez. Se os trechos abaixo não respondem, diga que não se
  lembra bem e pergunte."
- ≥ 0,75: "Provável que vocês já tenham falado disso", os trechos e a dica
  da `buscar_conversa` ("se nenhum trecho responde...").

**Descrição** (a da bancada): descrever o assunto, não as palavras exatas.

**Recusa por segurança.** O Decision recusa entradas com "palavras
sensíveis" (1 de 90 no LongMemEval, conversa inteira recusada). Tratada
como falha (I6): o resultado diz para usar a `buscar_conversa`, e a recusa
é contada (6.6).

### 6.5 Pré-busca (D1 = b)

Quando o porteiro dispara, a Supernova chama o `lembrar` com a mensagem da
pessoa como assunto e acrescenta ao turno uma chamada de ferramenta e seu
resultado, como se a agente os tivesse feito. Ela continua com as duas
ferramentas para buscar de novo com outras palavras. Fica no histórico como
qualquer chamada de ferramenta.

### 6.6 Medição no piloto

A bancada é sintética (português) e o LongMemEval é curado (inglês); a
distribuição que importa é a do piloto. Contadores agregados, no `/metrics`
que já existe (Prometheus, `src/supernova/health/server.gleam`) e na
telemetria (`core/telemetry`), nunca com texto nem por pessoa identificável:

- **Porteiro:** mensagens avaliadas, disparos, tempo (histograma),
  tempos-limite.
- **`lembrar`:** chamadas (pré-busca e pela agente), probabilidade geral
  em faixas (< 0,2; 0,2–0,75; ≥ 0,75), trechos devolvidos, tamanho da lista
  curta, tokens, custo, tempo, erros, tempos-limite e **recusas por
  segurança**.
- **Índice:** trechos vetorizados, tokens e custo de embeddings.
- **Correção:** depois de um turno com `lembrar`, a próxima mensagem da
  pessoa passa por uma pergunta ao Decision, com a resposta da agente e a
  mensagem como entrada: "A pessoa está corrigindo ou contestando o que a
  agente disse lembrar?". Conta-se só o resultado (sim/não, em faixas).
  Mesma chave e mesma ZDR (D2).

Painel no Grafana (`monitoring/grafana`): taxa de disparo, faixas de
probabilidade, taxa de correção, custo por dia.

### 6.7 Custo

Cada chamada ao Decision (tokens de entrada × US$ 0,10 por milhão) e aos
embeddings (× US$ 0,20 por milhão) é registrada no `resource_ledger`, contra
o orçamento diário da pessoa e da instância. No tamanho da bancada, uma
consulta custa ~US$ 0,0006, e o índice da conversa inteira ~US$ 0,01, uma
vez. Orçamento esgotado: porteiro e `lembrar` desligam para a pessoa
até o dia seguinte, e a `buscar_conversa` continua.

## 7. Invariantes

- **I1.** O porteiro nunca segura um turno mais que `gate_timeout_ms`.
- **I2.** Nenhum texto da conversa em log, auditoria ou métrica.
- **I3.** O `lembrar` só lê as conversas da pessoa que chamou.
- **I4.** `/esquecer` não deixa nada para trás: o Decision e a API de
  embeddings não guardam estado, e o índice vetorial da pessoa é apagado
  com as conversas.
- **I5.** Com `recall.enabled: false`, o comportamento é o de hoje, byte a
  byte nas mensagens ao LLM.
- **I6.** Falha do Decision nunca vira resposta de erro para a pessoa.
- **I7.** As métricas do piloto são contadores e histogramas: nenhum
  rótulo carrega texto, principal ou chat.

## 8. Histórias

### M-00: Medir D1 (feita)
Bancada: (a) contra (b), com o `lembrar` sozinho e junto da
`buscar_conversa`. Resultado na seção 5 e no relatório.

### M-01: Cliente do Decision e configuração
6.1 e 6.2. Testes com transporte falso: sucesso, tempo esgotado, HTTP 400,
429. Boot recusa `enabled: true` sem chave.

### M-02: `lembrar`
6.4, como ferramenta registrada no `tool_dispatch` e no syscall (escopo
pelo principal, como a `buscar_conversa`), com o índice vetorial por pessoa.
Testes: formato enxuto, índice incremental (só o trecho aberto é refeito),
lista curta (vetor e palavras), faixas de tom, escopo (I3), `/esquecer`
apaga o índice (I4), falha e recusa por segurança viram mensagem para a
agente sugerindo a `buscar_conversa`.

### M-03: Porteiro
6.3, com tempo-limite (I1) e auditoria sem texto (I2). Testes com Decision
falso: dispara, não dispara, lento, erro.

### M-04: Pré-busca
6.5. Teste de turno completo com LLM mock: a mensagem sobre o passado chega
ao LLM já com o resultado do `lembrar`; uma mensagem comum chega igual a
hoje (I5).

### M-05: Custo
6.7. Testes: registro no ledger, orçamento esgotado desliga.

### M-06: Harness e bancada
Cenário `buscar_antigo` com `recall.enabled: true` no harness. Bancada
apontada para o código da Supernova (não para a reimplementação em Python)
e rodada de novo; números no relatório.

### M-07: Medição no piloto
6.6. Testes: cada contador sobe no caso certo; nenhum rótulo com texto ou
principal (I7); a pergunta de correção só roda depois de um turno com
`lembrar`. Painel no Grafana.

### M-08: Documentação
`supernova.yaml.example`, `ARCHITECTURE.md`, `PENDENCIAS.md` (árvore com
gatilho). Ligar no piloto é decisão do mantenedor, fora desta PRD.

## 9. Critérios de aceite

| Critério | Meta |
|---|---|
| Fatos achados (bancada, DeepSeek) | ≥ 80% das perguntas sobre fatos |
| Negar com certeza (bancada, DeepSeek) | ≤ 5% |
| Porteiro em mensagens comuns | 0 disparos em 30 mensagens novas |
| Atraso em mensagens comuns | p95 do porteiro ≤ 1 s |
| Custo por `lembrar` no tamanho do piloto | mediana ≤ US$ 0,002 |
| Lista curta (LongMemEval, amostra de 59 respondíveis) | contém a resposta em ≥ 58 |
| Falha do Decision | nenhuma resposta de erro à pessoa (I6) |
| Harness | `buscar_antigo` passa, com e sem `recall` |
| Piloto, primeira semana | taxa de correção medida e registrada (sem meta: é a linha de base) |

## 10. Riscos

- **API nova (v1beta, de 11/11/2026).** Pode mudar. O cliente fica isolado
  em um módulo.
- **Injeção.** O texto da pessoa vai ao Decision; a documentação avisa que
  ele pode "argumentar" pela própria classificação. O pior caso aqui é
  buscar à toa ou não buscar, sem efeito além disso.
- **Custo com histórico grande.** A lista curta deixa o Decision num tamanho
  fixo; o que cresce é só o índice, vetorizado uma vez. A árvore (D3) fica
  para quando a lista curta deixar de conter a resposta.
- **Recusa por segurança.** Uma agente de companhia ouve sobre doença, luto,
  sexo, violência; a taxa de recusa no piloto pode ser bem maior que 1 em
  90. Pode ser o maior limite do Decision aqui. A métrica (6.6) responde;
  a lista curta ajuda, porque manda menos texto.
- **Lista curta perde a resposta.** Aí o Decision diz "pouco provável" com
  confiança, o erro que mais queremos evitar. 59/59 no LongMemEval, mas o
  piloto pode ser diferente; a taxa de correção (6.6) é o alarme.
- **Português.** A bancada mediu em português informal; nada mede outras
  línguas.
- **Plano gratuito sem saber.** Uma chave pode estar no plano gratuito sem
  que ninguém saiba; a API só revela no erro de limite ("on Free Tier").
  Nesse plano, os termos permitem ao Google usar o conteúdo. Conferir o
  faturamento antes de mandar conversa real.
