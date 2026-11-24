# Bancada de busca

Mede como a agente responde perguntas sobre o passado da conversa com cada
ferramenta de busca. Nada aqui entra no build de produção.

- `dados.py`: histórico sintético da Marta (valência, mensagens sem acento,
  erros de digitação, um fato corrigido) com 14 fatos plantados e 16
  perguntas, 4 delas sobre o que nunca foi dito. Tudo inventado.
- `bancada.py`: o laço da agente (prompt montado pela Supernova num
  cenário do harness, as 11 ferramentas reais, janela de 100 mensagens),
  as variantes de busca, o porteiro e o juiz.
- `../busca_bench.erl`: a `buscar_conversa` real, chamada por linha de
  stdin; e um banco sem LLM (`busca_bench:main/0`).

Variantes: `nenhuma`, `buscar_antiga` (descrição e resultado de antes desta
mudança), `buscar_nova`, `grepmem` (porta do GrepMem), `grep_conversa`
(regex com mensagens vizinhas), `lembrar` (Gemini Decision 1 sobre a
conversa em trechos de 10 mensagens) e `ambas` (`lembrar` e
`buscar_conversa`).

Condições: `natural` (prompt de hoje), `busca` (uma regra a mais pedindo
para procurar) e `porteiro` (o Decision decide se a mensagem pergunta
sobre o passado; se sim, a primeira chamada é obrigatoriamente a busca) e
`prebusca` (o mesmo porteiro; se dispara, a bancada chama o `lembrar` com a
mensagem e entrega o resultado no turno, como se a agente o tivesse
chamado).

Chaves em `.env.bench`, na raiz (fora do git): `OPENROUTER_API_KEY`,
`GEMINI_API_KEY`. O DeepSeek usa a chave do `.env` da Supernova.

    gleam build
    python3 -I dev/bancada/bancada.py rodar --modelos deepseek \
        --variantes buscar_nova,lembrar --condicoes porteiro --reps 3 \
        --saida /tmp/rodada.jsonl
    python3 -I dev/bancada/bancada.py resumo /tmp/rodada.jsonl
    python3 -I dev/bancada/bancada.py porteiro

`longmemeval.py`: a mesma camada de busca no LongMemEval S (ver o cabeçalho).

Resultados: `docs/relatorios/BUSCA-bancada.md`.

## Referências

- Z. Yang, T. Shi, J. Zhao. *Forget Freely, Grep Later: Lossless,
  Index-Free Memory for Long-Horizon LLM Agents*. arXiv:2611.25123, 2026.
  <https://arxiv.org/abs/2611.25123>. Código (MIT):
  <https://github.com/limenlp/GrepMem>. Origem da variante `grepmem`.
- Google. *Gemini Decisions API* e o modelo `gemini-decision-1`, 11/11/2026.
  <https://blog.google/innovation-and-ai/technology/developers-tools/gemini-decisions-api/>,
  documentação em <https://aistudio.google.com/docs/decisions-api>.
  Origem da variante `lembrar` e do porteiro.
