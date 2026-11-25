# PRD-F: inventário das ferramentas e linha de base (F-00)

Levantado em 25/11/2026 no código da master, depois da PRD-D.

## Ferramentas

"Prazo próprio" é o limite que já existe hoje, dentro da ferramenta ou do
FFI dela. **Por cima dele, o executor já corta toda chamada** desde a PRD-E
(E-03): `tool_limits`, 60 s por padrão e 300 s para o `computador`,
configuráveis em `tools.timeouts`. A chamada roda num processo à parte, que é
morto no estouro (`executor.within`). "Tempo típico" é estimativa pela
natureza da operação, salvo onde está marcado como medido.

| Ferramenta | Prazo próprio | Tempo típico | Efeitos | Paralela consigo mesma | D3 |
|---|---|---|---|---|---|
| `agenda` | nenhum | ms (lê e grava `agenda.json` da pessoa) | grava no disco, com `.tmp` e `rename`, sob trava por pessoa | sim: a trava serializa a mesma agenda | instantânea |
| `file_system` | nenhum | ms | lê e grava no workspace da pessoa (política de workspace) | sim, em arquivos diferentes | instantânea |
| `canvas` | nenhum | ms (só monta texto) | nenhum | sim | instantânea |
| `buscar_conversa` | nenhum | dezenas a centenas de ms; lê e decodifica a conversa inteira (medido na PRD-P: teto de vazão do estresse) | lê o disco | sim | segundo plano |
| `lembrar` | `recall_timeout_ms`, 15 s | ms com o índice pronto; ~13 s na primeira consulta, que monta o índice (medido na PRD-M) | lê e grava `recall.idx`; rede (vetores, porteiro) | sim; a montagem do índice é por pessoa | segundo plano |
| `web` (`web_fetch`) | conexão 8 s, resposta 30 s (FFI) | 1 a 5 s | rede (com `url_guard`) | sim | segundo plano |
| `browser` | por operação, `timeout_ms` do chamador | segundos | processo externo (Chromium via porta), rede | não na mesma sessão de navegador | segundo plano |
| `github` | nenhum explícito (o do `hackney`) | 1 a 3 s | rede (API REST por `hackney`, **não** o `gh`) | sim | segundo plano |
| `computador` | 60 s, até 300 s (`timeout_s`) | segundos a minutos | rede até o computador da pessoa (gVisor); grava arquivos de imagem | não no mesmo computador | segundo plano |
| `safe_shell` | 10 s (FFI) | ms a segundos | processo externo no host, no workspace | sim | segundo plano |
| `git_inspect` | 10 s (pelo `safe_shell`) | ms | processo externo (`git`), só leitura | sim | segundo plano |
| `process` | 10 s (FFI) | ms | **lista e mata processos do sistema**, com política de workspace | sim | segundo plano |

### O que isso muda no desenho

- **O prazo já existe (PRD-E).** A PRD-F foi escrita em 23/11; a PRD-E, que
  trouxe o prazo por ferramenta, foi executada em 24/11. A D1 (120 s) fica
  substituída pela decisão da PRD-E (60 s, `computador` 300 s,
  configurável), que é mais recente. O que falta é o resto da F-02: matar as
  chamadas quando o turno morre (hoje o processo da chamada é iniciado sem
  vínculo e sobrevive ao turno), vagas por ferramenta e por agente, e o
  desfecho `timeout` e `cancelado` no ledger e no audit.

- **D7 e o `github`.** A D7 contava o `github` "via `gh`" entre os processos
  externos a isolar. Ele fala com a API por HTTP, dentro da BEAM: não há
  processo para o `bwrap`. A F-08 fica com `safe_shell`, `git_inspect` e
  `process`.
- **`process` mata processos do sistema.** No container, isso é a árvore da
  própria Supernova (o Chromium do `browser`, por exemplo). Dentro do `bwrap`,
  com o próprio namespace de PIDs, ela só veria o que ela mesma iniciou: o
  `list` e o `kill` perdem o sentido. A F-08 decide se o `process` entra no
  sandbox ou fica fora dele com a política de workspace.
- **Escrita no meio de um corte (risco da seção 10).** A `agenda` já grava
  com `.tmp` e `rename`, sob trava por pessoa. O `file_system` grava direto
  (`file:write_file`). Pelo D3 ele não vai para segundo plano, mas a F-02 pode
  cortá-lo por prazo. Com prazo de 120 s e tempo de milissegundos, o corte no
  meio de uma escrita é improvável; o `.tmp` com `rename` entra no
  `file_system` antes da F-02 mesmo assim, como a seção 10 pede.

## Linha de base do estresse

**A primeira medição desta seção era inválida.** O mock do LLM decidia que a
rodada de ferramentas já tinha acontecido se houvesse *qualquer* resultado de
ferramenta na conversa. Desde a #59 o histórico guarda os resultados, então,
depois da primeira busca de cada agente, as outras mensagens `[mock-busca]`
eram respondidas sem buscar. O efeito cresce com a duração da rodada. A F-01
corrigiu o mock (só conta o que veio depois da última mensagem da pessoa).
As medições da PRD-P também tinham esse viés, em menor grau (rodadas curtas,
uma ou duas buscas por agente): a conclusão dela, de que a busca é o teto da
vazão, fica de pé e fica mais forte.

| Medição (master `b3f4ab7`, comando da PRD-P) | Carga | Turnos/s | p50 com busca | p95 todos |
|---|---|---|---|---|
| com o mock antigo (inválida) | 3,0 | 56,5 | 3070 ms | 10030 ms |
| com o mock corrigido, rodada 1 | 5,9 | 17,9 | 16703 ms | 22417 ms |
| com o mock corrigido, rodada 2 | 32,5 | 8,0 | 24314 ms | 36282 ms |

As rodadas corrigidas caíram numa tarde em que a VPS (6 núcleos) estava
ocupada por outros projetos: carga 5,9 e depois 32,5. Elas mostram a ordem de
grandeza (a busca de verdade custa muito: p50 de 17 s), mas não servem de
referência fina.

**Como a F-03 compara.** A/B intercalado, como manda `docs/ESTRESSE.md`:
cópias congeladas da master e da branch, rodadas alternadas na mesma janela,
com a carga anotada. A F-03 traz as duas colunas.

**Processo com a maior fila.** Nas amostras com fila acima de 20 aparecem o
coletor de stream do canal `sim` e o log (`safe_println`). Nenhum é
supervisor de ferramenta, porque ainda não existe nenhum: o critério da
seção 9 é que continue assim depois da F-02.
