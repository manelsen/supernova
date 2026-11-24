# Busca no passado da conversa: bancada

[Bancada](../../dev/bancada/README.md) · 23/11

## Pergunta

A Selene responde bem quando a pessoa pergunta algo que contou antes, fora
das 100 mensagens que ela vê? E a `buscar_conversa` é a melhor ferramenta
para isso, ou um grep (como no GrepMem [1]) ou um modelo de decisão (Gemini
Decision 1 [2]) faria melhor?

## Resumo

1. **O gargalo é a agente decidir buscar, não a busca.** Com o prompt de
   hoje, o DeepSeek (modelo da Selene) chamou a `buscar_conversa` em 6%
   das perguntas sobre o passado e acertou 8%.
2. **Um porteiro resolve isso.** O Decision lê só a mensagem que chegou e
   diz se ela pergunta sobre o passado. Em mensagens novas, não usadas para
   ajustar a pergunta, pegou 15 de 15 perguntas sobre o passado e disparou
   em 0 de 30 mensagens comuns. Com o porteiro, a agente sempre busca, e o
   acerto do DeepSeek com a `buscar_conversa` vai de 8% para 67%.
3. **O Decision como busca (`lembrar`) acertou 60 de 60 perguntas sobre
   fatos** com o porteiro, nos três modelos, e 24 de 24 com um histórico
   4,6× maior. As outras buscas perdem quando a pessoa pergunta com outras
   palavras ("cirurgia", quando disse "operada").
4. **Grep não substitui a `buscar_conversa`.** Com mensagens vizinhas,
   empata; sem elas (GrepMem fiel), perde. E, sem porteiro, a agente quase
   nunca chama o grep.
5. **O erro que sobra é negar com certeza** o que nunca foi dito, ou o que
   foi dito de outro jeito. Esta PR põe o tom no resultado da busca, onde a
   agente lê na hora de responder. O efeito é na direção certa e pequeno.

## Como foi medido

**Histórico.** Sintético, da Marta com a agente: episódios com valência
(dias bons, ruins, neutros), 35% das mensagens dela sem acento, 10% com erro
de digitação, abreviações ("vc", "fds", "kkk"). 14 fatos plantados, um
deles corrigido depois (a dermatologista é terça, não quinta), um com erro
de digitação ("prezente"), vários ditos de um jeito e perguntados de outro.
Armadilhas: "cachorro" aparece 31 vezes (o da vizinha), "chefe" 87 (o
nome nunca). 16 perguntas; 4 sobre o que nunca foi dito. Tudo inventado.

**Agente.** O prompt montado pela Supernova num cenário do harness (núcleo,
regras, lembranças, humor), as 11 ferramentas reais, a janela de 100
mensagens. Até 5 chamadas de ferramenta por pergunta.

**Variantes de busca.**

| Variante | O que é |
|---|---|
| `buscar_conversa` | a ferramenta real: todas as palavras, sem acento nem maiúscula, mensagem anterior e duas seguintes, mais recentes primeiro |
| `grepmem` | porta do `grep_history` do GrepMem [1]: regex, uma mensagem por entrada, mais antigas primeiro, paginação |
| `grep_conversa` | o mesmo regex, com as mensagens vizinhas como contexto |
| `lembrar` | Decision 1 [2] sobre a conversa em trechos de 10 mensagens: uma pergunta sim/não por trecho, numa chamada; devolve a probabilidade e os 3 trechos mais prováveis, literais |

**Condições.** `natural` (prompt de hoje); `busca` (uma regra a mais:
"qualquer pergunta que possa depender do que vocês já conversaram justifica
procurar"); `porteiro` (o Decision decide; se sim, a primeira chamada é a
busca, com as palavras que a agente escolher).

**Modelos.** DeepSeek V4.1 Flash (o da Selene, 3 repetições), Nemotron 3
Ultra e ERNIE 5.5 Flash (gratuitos no OpenRouter, 1 repetição).

**Juiz.** DeepSeek, com gabarito: acertou, não lembra, negou (afirma com
certeza que não foi dito), errou, inventou. Não buscar conta como falha.

## Resultados

### Sem LLM

Consultas escritas à mão, 20 mil mensagens, 10 fatos: `buscar_conversa`
7/10 com as palavras como a pessoa fala; grep com regex ingênua 1/10 (sem
contexto) e 3/10 (com contexto); com regex caprichada, 7/10 e 8/10. Em
português, uma regex sem `[eé]` quase nunca acerta.

### Decidir buscar

DeepSeek, `buscar_conversa`, 48 perguntas por linha:

| Condição | Buscou | Acertou |
|---|---|---|
| natural | 6% | 8% |
| regra de busca | 44% | 40% |
| porteiro | 100% | 67% |

O Nemotron busca sozinho bem mais (69–75% no natural); o ERNIE, pouco
(19%). Com o porteiro, os três buscam sempre.

**Porteiro.** Pergunta ao Decision: "Esta mensagem é uma pergunta sobre o
passado da conversa (algo que a pessoa disse, contou ou combinou antes)?",
limiar 0,1. Uma formulação mais larga ("a agente precisa lembrar de algo?")
disparou em 8 de 10 mensagens comuns ("kkkkk": 0,82). Validação em 45
mensagens novas: 15/15 e 0/30 com qualquer limiar entre 0,05 e 0,3.

### Qual busca, com o porteiro

Perguntas sobre fatos, os três modelos somados (60 por variante):

| Variante | Acertou |
|---|---|
| `buscar_conversa` (antes desta PR) | 44 |
| `buscar_conversa` (com a descrição nova) | 48 |
| `grep_conversa` | 51 |
| `grepmem` | 37 |
| **`lembrar`** | **60** |

Por pergunta (DeepSeek e gratuitos, 5 por célula), onde elas se separam:

| Pergunta | `buscar_conversa` | `grep_conversa` | `grepmem` | `lembrar` |
|---|---|---|---|---|
| a cirurgia (disse "operada") | 0/5 | 0/5 | 0/5 | 5/5 |
| a prova (disse "concurso") | 1/5 | 2/5 | 0/5 | 5/5 |
| fisioterapia (disse "fisio") | 2/5 | 5/5 | 3/5 | 5/5 |
| o cardiologista (nome 2 mensagens depois) | 5/5 | 5/5 | 0/5 | 5/5 |

### Escala

DeepSeek com o porteiro, histórico de 12.040 mensagens (2 repetições):

| Variante | 2.641 mensagens | 12.040 mensagens |
|---|---|---|
| `buscar_conversa` | 67% | 59% |
| `grep_conversa` | 67% | 69% |
| `lembrar` | 85% | 84% (fatos: 24/24) |

**Custo do `lembrar`** (US$ 0,10 por milhão de tokens): com 2.641
mensagens, ~93 mil tokens por consulta (US$ 0,009), 1,6 s de mediana; com
12.040, ~425 mil tokens em 2 chamadas paralelas (US$ 0,04), 3 s. O custo
cresce com o histórico; com 100 mil mensagens, a consulta plana passaria de
US$ 0,30. Concorrência alta esbarra no limite de tokens por minuto.

### O tom do "não achei" (PR #65)

Antes, a descrição dizia "Finding nothing means it was not said". Agora a
descrição pede para tentar sinônimo, palavra mais curta, singular; e o
próprio resultado termina com o tom: vazio, "Pode ter sido dito com outras
palavras: tente outras. Se ainda assim não achar, diga que não se lembra,
não que nunca foi dito."; com trechos, "Se nenhum trecho acima responde à
pergunta, diga que não se lembra; não diga que nunca foi dito."

| | Negou com certeza, antes → depois | Fatos acertados, antes → depois |
|---|---|---|
| DeepSeek, regra de busca (48) | 21% → 12% | 12 → 14 de 36 |
| DeepSeek, porteiro (48) | 12% → 8% | 28 → 27 de 36 |
| Nemotron, regra de busca (32) | 9% → 6% | 12 → 13 de 24 |
| Nemotron, porteiro (32) | 19% → 3% | 17 → 16 de 24 |

A negação com certeza cai nas quatro linhas. As amostras são pequenas: é
tendência, não prova. Nenhum acerto se perde além da variação entre
repetições. O Nemotron com o porteiro passa a dizer "não lembro" mais vezes
(16% → 38%), parte delas em fatos que antes negava.

### Porteiro: obrigar a buscar ou pré-buscar

Com o porteiro disparado, (a) a primeira chamada da agente é obrigatoriamente
uma busca; (b) a Supernova chama o `lembrar` com a mensagem da pessoa e
entrega o resultado no turno, como se a agente o tivesse chamado. "Ambas" é
a agente com `lembrar` e `buscar_conversa`. DeepSeek com 3 repetições,
Nemotron com 2.

| | Fatos | Nunca dito | Negou | Tempo (mediana) |
|---|---|---|---|---|
| DeepSeek, (a) `lembrar` | 36/36 | 3/12 | 10% | 3,0 s |
| DeepSeek, (a) ambas | 35/36 | 4/12 | 8% | 2,7 s |
| DeepSeek, (b) `lembrar` | 36/36 | 5/12 | 8% | 2,2 s |
| DeepSeek, **(b) ambas** | **36/36** | **6/12** | **6%** | **2,2 s** |
| Nemotron, (a) `lembrar` | 24/24 | 4/8 | 6% | 10,9 s |
| Nemotron, (a) ambas | 19/24 | 4/8 | 6% | 6,8 s |
| Nemotron, (b) `lembrar` | 24/24 | 4/8 | 3% | 4,5 s |
| Nemotron, **(b) ambas** | **24/24** | 3/8 | **3%** | **4,8 s** |

(b) empata ou ganha, sem a ida a mais ao LLM. O Decision levou 1,4 s de
mediana (p90 1,6 s). Os casos de ~78 s são esperas por limite de requisições
na própria bancada.

### "Já falamos disso?": a pergunta geral

O `lembrar` faz ao Decision uma pergunta geral, além das por trecho. Três
formulações, sobre a conversa inteira, nas 16 perguntas e em mais 8 sobre o
que nunca foi dito:

| Formulação | Nunca dito (12) | Fatos (12) |
|---|---|---|
| W0: "falaram sobre isto: {mensagem}" | ≤ 0,14 | ≥ 0,17 |
| **W1: "a pessoa já contou à agente, ou as duas já conversaram, sobre o que esta mensagem pergunta?"** | **≤ 0,16** (11 de 12) | **≥ 0,92** |
| W2: "a resposta para esta pergunta está nesta conversa?" | ≤ 0,17 (11 de 12) | ≥ 0,73 |

A exceção nas três é "o que eu te contei do **meu** cachorro?" (0,8–0,9): o
da vizinha aparece 31 vezes. Os trechos mostram de quem é; probabilidade
alta não obriga a agente a afirmar nada.

### Custo: formato enxuto e lista curta

Metade da entrada era cabeçalho: `[30/07/2026 15:17] pessoa:` em cada
mensagem (49% dos caracteres; 38% das mensagens têm menos de 25). Duas
mudanças:

- **Formato enxuto:** a data uma vez por trecho, `P:` e `A:`. De 96 para 54
  mil tokens por consulta, com as probabilidades praticamente iguais.
- **Lista curta:** os 30 trechos mais próximos pelo vetor
  (`gemini-embedding-2`, 256 dimensões) mais os 10 com mais palavras em
  comum. O Decision lê só esses: 6,3 mil tokens, 15× menos. Na bancada, o
  trecho certo veio em 1º pelo vetor nas 12 perguntas sobre fatos; por
  palavras, a cirurgia ("operada") e a dermatologista ("dermato") ficavam
  de fora.

### LongMemEval

O 1º lugar em 12 de 12 é otimista: o enchimento da bancada é repetitivo.
Para conferir num corpus que não escrevemos, a mesma camada de busca rodou
no LongMemEval S [5] (MIT): históricos de chat com ~115 mil tokens, 500
perguntas escritas à mão; amostra de 10 por tipo mais as 30 de abstenção
(1 delas recusada pelo filtro de segurança da Google; 89 medidas). Em
inglês, sem agente: só a lista curta e a pergunta geral (W1).

| Tipo | Trecho certo na lista de 40 | Só por palavras |
|---|---|---|
| fato dito pela pessoa | 10/10 | 10/10 |
| fato dito pelo assistente | 10/10 | 9/10 |
| atualização | 9/9 | 9/9 |
| várias sessões (todas as partes) | 10/10 | 9/10 |
| temporal | 10/10 | 8/10 |
| preferência | 10/10 | 2/10 |
| **total** | **59/59** | 47/59 |

O trecho certo veio em 1º pelo vetor em 37 de 59; o pior, em 24º. A lista
curta usa 11 mil tokens contra 115 mil.

A pergunta geral separa menos aqui: as abstenções do LongMemEval são
quase-acertos (coisas parecidas com o que foi dito), e perguntas de
preferência ou de conta ("quantos dias entre...") não são "já falamos
disso?". Com a lista curta:

| Corte | Respondíveis abaixo (o "nunca" falso) | Abstenções abaixo |
|---|---|---|
| 0,2 | 2/59 (3%) | 17/30 |
| 0,3 | 7/59 (12%) | 24/30 |

Por isso a faixa "acho que não" fica abaixo de 0,2, e diz "acho que não",
nunca "não".

### Versão barata com a agente

Pré-busca, `lembrar` e `buscar_conversa`, DeepSeek com 3 repetições, as 16
perguntas mais 8 sobre o nunca dito. O resultado do `lembrar` agora traz o
tom pela probabilidade geral (< 0,2: "acho que não, sem afirmar com
certeza"; 0,2 a 0,75: "não lembro bem"; ≥ 0,75: confiante).

| | `lembrar` plano | **`lembrar` barato** |
|---|---|---|
| Fatos | 36/36 | **36/36** |
| Tokens por consulta (mediana) | ~93 mil | **6,4 mil** |
| Tempo do Decision (mediana) | 1,4 s | **0,65 s** (p90 0,85 s) |
| Turno inteiro (mediana) | 2,2 s | **1,4 s** |

Nunca dito, as mesmas 8 perguntas novas, 3 repetições:

| | Plano, sem faixas de tom | **Barato, com faixas** |
|---|---|---|
| Nega sem dúvida ("você nunca me contou") | 6/24 | **1/24** |
| Nega com dúvida ("acho que você nunca me contou") | 1/24 | 5/24 |
| Não lembra, não encontrou | 17/24 | 18/24 |

**Critério do juiz.** "Acho que você nunca me disse o nome dele" é o tom
que o mantenedor quer; o juiz marcava como negação pela palavra "nunca".
Respostas a perguntas sobre o nunca dito que negam com "acho que" foram
reclassificadas como "não lembra" (8 na versão barata, 1 na plana). Uma
delas é um erro de verdade que a regra esconde: "acho que nunca falamos da
Carla" (falaram; só os filhos dela nunca apareceram). Com o critério novo,
a versão barata nega sem dúvida em 1 de 36 perguntas sobre o nunca dito; a
plana, sem faixas, em 16 de 48 (rodada anterior, 16 perguntas).

O Nemotron fica para outra rodada: o limite diário gratuito do OpenRouter
acabou.

### Supernova real (PRD-M executada)

A bancada passou a chamar o porteiro e o `lembrar` da própria Supernova
(`--lembrar supernova`), pela ponte Erlang. DeepSeek, pré-busca, 24
perguntas, 2 repetições: **24/24 fatos**, **0/24 negações sem dúvida**, 0
falhas do Decision. Decision em 1,6 s de mediana; turno inteiro em 3,4 s.

**Harness** (`buscar_antigo`, DeepSeek, juiz Opus, 3 execuções de cada lado):

| | Aprovadas |
|---|---|
| sem memória | 1/3 |
| com memória (`buscar_antigo_memoria`) | 3/3 |

Nas reprovadas sem memória, a agente diz "Não sei. Nunca me contou o nome
dele" e, adiante, se corrige: "fui procurar, e me enganei na resposta
anterior".

### Linha de base, determinismo e calibração

Crítica de uma instância irmã, que trabalha com o mesmo modelo noutra
bancada: faltava comparar o porteiro com um LLM barato, medir a calibração e
dar intervalos.

**Porteiro, Decision contra DeepSeek sim/não** (mesma pergunta):

| | Decision (corte 0,1) | DeepSeek sim/não |
|---|---|---|
| Validação (15 + 30, fora do ajuste) | 15/15, 0/30 | 14/15, 0/30 |
| Ajuste (16 + 10) | 16/16, 0/10 | 10/16, 0/10 |
| Tempo, mediana (p90) | 0,21 s (0,29) | 0,24 s (0,54) |

Fora da amostra, quase empate. O DeepSeek perde as perguntas implícitas
("qual é a senha do wifi?"), em que o Decision dá entre 0,15 e 0,6, acima de
um corte baixo. Um porteiro resolve; o modelo de decisão é uma boa escolha,
não a única. Com 0/30, o limite superior de 95% para falso alarme é de ~10%.

**Determinismo:** 71 mensagens, 3 execuções do Decision, probabilidades
idênticas.

**Calibração da pergunta geral no LongMemEval** (respondível ou abstenção):
Brier de 0,157 lendo a conversa inteira e de 0,132 com a lista curta; AUC de
0,889 e 0,936.

| Faixa | 0,0–0,2 | 0,2–0,4 | 0,4–0,6 | 0,6–0,8 | 0,8–1,0 |
|---|---|---|---|---|---|
| Previsto | 0,13 | 0,28 | 0,49 | 0,69 | 0,89 |
| Observado | 0,11 | 0,44 | 0,83 | 0,93 | 1,00 |

Bem calibrado embaixo, onde fica o "acho que não"; subconfiante no meio. A
palavra "calibrado" fica para a faixa baixa. O que o modelo faz bem é
ordenar.

### Gemini Decision 1 × Perplexity Decider v1.3

O Decider v1.3 [6] é da mesma família de modelos de decisão, com pesos
abertos (Apache 2.0), 27B e Flash (4B), a US$ 0,02 e 0,01 por milhão de
tokens (Gemini: 0,10). Pela API direta e pelo OpenRouter (só a variante
`:free` serve o v1.3; o alias `~perplexity/pplx-decider-latest` ainda
apontava para o v1.2), as probabilidades são idênticas e determinísticas.

**Pergunta geral do `lembrar`, LongMemEval, validação cruzada** (corte
escolhido numa metade, testado na outra, 20 sorteios; ~5% de "nunca"
falso):

| | Abstenções pegas |
|---|---|
| Gemini, sim/não | 62% |
| Gemini, três saídas (falaram / parecido / nunca) | 32% |
| Decider 27B, sim/não ou três saídas | 72% |
| Decider Flash, sim/não | 76% |

As três saídas pareciam ganhar no Decider (26/30) com o corte escolhido nos
mesmos dados; fora da amostra empatam com o sim/não.

**`locate`** (trecho literal, só no v1.3 e só pela API da Perplexity): quando
devolve um trecho, ele está certo (27B 32/35; Flash 15/15), mas na dúvida
devolve vazio (27B acha 25/60 no LongMemEval, 1/10 em várias sessões, 0/10 em
preferências). Não substitui as perguntas por trecho.

**Porteiro.** Com a pergunta sim/não, o Decider perdia perguntas implícitas
("qual é o telefone da clínica?"): em 60 mensagens novas, Gemini 20/20 e 0/40,
Decider 27B 17/20, Flash 16/20 e 3/40. Cinco formulações foram ajustadas em
131 mensagens já vistas; a de **múltipla escolha** ("o que é esta mensagem?":
dado pessoal, lembrança, conhecimento geral, conversa; soma das duas
primeiras) separou com folga no 27B (perguntas do passado ≥ 0,67, comuns
≤ 0,09; margem de 3,6 log-odds, contra < 1 nas outras). Corte fixado em
0,25 e validado uma vez em 60 mensagens escritas antes do ajuste: **20/20
(implícitas 12/12) e 0/40**, igual ao Gemini. O Flash não separou em
nenhuma formulação.

**Embeddings.** `pplx-embed-v2-context-0.6b` (US$ 0,02 por milhão, ZDR por
padrão) contra `gemini-embedding-2` (US$ 0,20): lista curta com a resposta em
59/60 contra 59/59 no LongMemEval (a de diferença, temporal, ficou em 55º
no vetor); 1º lugar em 39 contra 37; bancada, os 12 fatos em 1º ou 3º.

**Escolha (D6):** Perplexity como padrão, Decider 27B no porteiro (múltipla
escolha) e no `lembrar`, embeddings da Perplexity. O Gemini fica por
configuração, com os cortes dele.

## Limites

- Um histórico sintético e uma semente; 16 perguntas. Mostra
  comportamentos, não taxas de produção.
- O juiz é um LLM (DeepSeek); revisei algumas amostras e ele erra às vezes.
- O prompt é o de uma agente sim nascida no harness, não o da Selene.
- O ajuste da pergunta do porteiro foi feito nas 16 perguntas; a validação
  em 45 mensagens novas é pequena.
- O Decision foi medido com a chave paga; a gratuita (50 mil tokens por
  minuto) não comporta uma consulta com histórico grande.
- O LongMemEval mede só a camada de busca, em inglês. A agente com o prompt
  da Selene foi medida só na bancada em português.
- O filtro de segurança da Google recusou 1 de 90 conversas do LongMemEval.
  Numa agente de companhia, a taxa pode ser bem maior.

## O que fica

A PRD-M ([docs/prd/PRD-M-memoria.md](../prd/PRD-M-memoria.md)) leva para a
Supernova: porteiro, pré-busca, `lembrar` barato com índice vetorial por
pessoa, faixas de tom e a medição no piloto (disparos, faixas, correções e
recusas por segurança, sem texto).

## Referências

1. Z. Yang, T. Shi, J. Zhao. *Forget Freely, Grep Later: Lossless,
   Index-Free Memory for Long-Horizon LLM Agents*. arXiv:2611.25123, 2026.
   <https://arxiv.org/abs/2611.25123>. Código (MIT):
   <https://github.com/limenlp/GrepMem>.
2. Google. *Gemini Decisions API*, modelo `gemini-decision-1`, 11/11/2026.
   <https://blog.google/innovation-and-ai/technology/developers-tools/gemini-decisions-api/>;
   documentação: <https://aistudio.google.com/docs/decisions-api>.
3. H. Chen, R. Pasunuru, J. Weston, A. Celikyilmaz. *Walking Down the
   Memory Maze: Beyond Context Limit through Interactive Reading*.
   arXiv:2310.05029, 2023. <https://arxiv.org/abs/2310.05029>.
4. A. L. Zhang, T. Kraska, O. Khattab. *Recursive Language Models*.
   arXiv:2512.24601, 2025. <https://arxiv.org/abs/2512.24601>.
5. D. Wu, H. Wang, W. Yu, Y. Zhang, K.-W. Chang, D. Yu. *LongMemEval:
   Benchmarking Chat Assistants on Long-Term Interactive Memory*. ICLR 2025.
   arXiv:2410.10813. <https://arxiv.org/abs/2410.10813>. Dados (MIT):
   <https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned>.
6. Perplexity. *Decisions API* e os modelos `pplx-decider-v1.3` e
   `pplx-decider-flash-v1.3`, 11/2026. <https://docs.perplexity.ai/docs/decisions/quickstart>;
   pesos (Apache 2.0): <https://huggingface.co/perplexity-ai/pplx-decider-v1.3>.
