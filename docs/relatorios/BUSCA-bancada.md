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

### O tom do "não achei" (esta PR)

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

## Limites

- Um histórico sintético e uma semente; 16 perguntas. Mostra
  comportamentos, não taxas de produção.
- O juiz é um LLM (DeepSeek); revisei algumas amostras e ele erra às vezes.
- O prompt é o de uma agente sim nascida no harness, não o da Selene.
- O ajuste da pergunta do porteiro foi feito nas 16 perguntas; a validação
  em 45 mensagens novas é pequena.
- O Decision foi medido com a chave paga; a gratuita (50 mil tokens por
  minuto) não comporta uma consulta com histórico grande.

## O que fica

1. **Porteiro na Supernova.** Na fase anterior ao LLM, que já roda na fila
   de cada chat (PRD-P). Precisa de PRD: configuração, falha do Gemini
   (seguir sem porteiro), ZDR e chave paga.
2. **`lembrar` como ferramenta**, ao lado da `buscar_conversa` (o exato
   continua com ela). O tom calibrado (a probabilidade) vira o grau de
   dúvida da agente.
3. **Custo com histórico grande:** bisseção e árvore de resumos (como no
   MemWalker [3]; em linha com os Recursive Language Models [4]), medidas
   contra o `lembrar` plano com 12 mil mensagens.
4. **Nunca dito:** medir de novo com mais perguntas desse tipo; o efeito do
   tom ainda é tendência.

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
