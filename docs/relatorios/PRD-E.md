# PRD-E: relatório final

[PRD](../prd/PRD-E-endurecimento.md) · PR #70 e #73 · 25/11

## Resumo

A auditoria de março apontou sete achados (A1 a A7). A PRD-E fechou os sete em
seis histórias, sem mudar a arquitetura: os processos únicos, o gateway e as
tools continuaram onde estavam, mas cada um passou a negar ou a avisar em vez
de perder a mensagem em silêncio.

- **E-01 (A1), fila cheia:** a mensagem recusada pela fila do chat não é mais
  marcada como feita. Ela volta com espera crescente, de 1 s a 64 s; depois
  disso a pessoa recebe uma vez "Estou com muitas mensagens agora; já te
  respondo." e as tentativas seguem a cada 2 min por mais 20 min. Se nada
  aceitar, a mensagem continua pendente no inbox e é atendida no próximo boot.
- **E-02 (A2), SSRF:** a `url_guard` resolve o nome (A e AAAA) e bloqueia se
  qualquer endereço for interno: loopback, privado, CGNAT, link-local, ULA,
  multicast ou IPv4 embutido em IPv6. Formas numéricas ambíguas e nomes de um
  rótulo só, como os serviços do compose (`grafana`, `computador`), também
  caem. O `web_fetch` desliga o redirect explicitamente e recusa corpo acima
  de 2 MB.
- **E-03 (A3), teto e tempo:** toda saída de tool é cortada em 20.000
  caracteres, com aviso. Toda tool roda num processo próprio, morto ao passar
  do tempo-limite: 60 s por padrão, 300 s para o computador, ajustável em
  `tools.timeouts`.
- **E-04 (A4, A5), sem política, nega:** o gateway nega tools e syscalls sem
  política de orçamento quando há manifest, ou seja, em produção. O executor
  recusa o turno sem contexto de grupo fechado nos três caminhos: turno,
  nascimento e nome. Um teste de arquitetura impede gateway de produção sem
  política.
- **E-05 (A6), tool `gateway`:** a tool sai porque fingia ler e escrever
  arquivos. Nenhuma syscall fabrica sucesso: todas respondem "not implemented"
  até alguma PRD ligá-las a uma ação real. O nome continua aceito em
  `capabilities`, para não quebrar configuração antiga.
- **E-06 (A7), documentação:** README, STATUS, INTERACTION, ARCHITECTURE e
  COMPONENTS dizem que só o Telegram (e o sim) recebem. O Discord e os demais
  só enviam.

## Medição final

Esta PRD não tem bancada: nenhum critério dela é de desempenho. O único número
medido é a cobertura de linha, e ele não prova ganho nenhum aqui.

| | Cobertura |
|---|---|
| master + E-01, antes das demais histórias | 80,26% |
| depois da E-06 | 80,39% |

Ressalva registrada no commit da E-04: a mesma árvore mediu entre 80,27% e
80,35% em rodadas seguidas, e a E-04 mediu 80,35% contra os 80,38% da E-03.
A diferença entre as histórias está dentro do ruído da medição.

**Testes:** nenhum usa rede. O teste de URL pública que dependia de DNS de
verdade passou a usar um resolvedor falso (`test/core/url_guard_test.gleam`).

## Critérios da PRD (seção 7)

| Critério | Meta | Resultado |
|---|---|---|
| Fila cheia | nenhuma mensagem marcada feita sem turno | **Atingido.** `test/channel/rejected_retry_test.gleam` cobre recusa, espera crescente, aviso único e a mensagem que segue pendente. |
| `web_fetch` para `http://grafana:3000`, `http://10.0.0.1`, nome que resolve para 127.0.0.1 | negado | **Atingido.** Os três casos estão em `test/core/url_guard_test.gleam`, com resolvedor falso. |
| Saída de tool | ≤ teto do D2 em todo caminho | **Atingido.** `max_output_chars = 20_000` em `core/tool_limits.gleam`, aplicado no corte comum, com teste em `test/core/tool_limits_test.gleam`. |
| Gateway sem budget em produção | nega | **Atingido.** `test/architecture/tool_gateway_test.gleam` e os testes de syscall. |
| README | nenhum canal "Supported" sem entrada | **Atingido.** A E-06 reescreveu as cinco páginas; o critério foi conferido na leitura, não por teste. |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| E-01 | `a1c77d8` | mensagem recusada pela fila volta com espera crescente e aviso único |
| E-02 | `b25139e` | `url_guard` resolve o nome; `web_fetch` sem redirect e com teto de 2 MB |
| E-03 | `d8bf830` | teto de 20.000 caracteres e tempo-limite em toda tool, em processo próprio |
| E-04 | `29624a8` | gateway e executor negam quando falta a política, nos três caminhos |
| E-05 | `e29bbc2` | sai a tool `gateway`; syscalls respondem "not implemented" |
| E-06 | `03e6fa9` | README, STATUS, INTERACTION, ARCHITECTURE e COMPONENTS dizem a verdade |

A PRD entrou no master duas vezes: primeiro como squash na #69
(`a59f0f8`), depois com os commits originais na #73 (`efdcf71`), para que o
histórico ficasse um commit por história. O conteúdo é o mesmo.

## Corridas resolvidas

- **Mensagem perdida com a fila cheia.** A recusa da fila era tratada como
  conclusão: a mensagem era marcada como feita sem nenhum turno ter rodado.
  Era uma perda silenciosa sob carga, e o teste antigo não a pegava porque
  olhava o inbox, não a marca de concluída.
- **Falha aberta no gateway e no executor.** Sem política de orçamento ou sem
  grupo fechado, o caminho seguia liberado. Era o oposto da regra do
  `AGENTS.md`. Agora, com manifest, nega; sem manifest (desenvolvimento e
  testes), segue como antes.
- **Sucesso fabricado nas syscalls.** `run_op` devolvia resultado de leitura e
  escrita sem tocar o disco. Um modelo podia agir sobre um "arquivo lido" que
  nunca existiu. Toda operação devolve falha honesta até ser ligada de
  verdade.

## O que fica

- **DNS rebinding.** Entre a checagem da E-02 e a conexão, o nome pode
  resolver para outro endereço. Está documentado no módulo. A mitigação
  definitiva é de rede: a Supernova numa rede Docker que não alcança o
  Grafana, o Prometheus nem o computador além das portas que ela usa.
- **Turnos longos legítimos** podem bater no tempo-limite de 60 s; o
  computador tem 300 s e o valor é configurável.
- **Nada foi rodado no piloto.** A PRD inteira foi verificada por testes e por
  leitura; nenhum critério foi exercitado contra a instância real.
