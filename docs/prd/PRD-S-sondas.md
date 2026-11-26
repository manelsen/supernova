[PRD]
# PRD S: sondas, os subagentes do par

> **Situação em 25/11/2026:** segunda versão, com histórias. S1 a S13
> decididas em 24/11. S14 a S20, S22 e S24 decididas em 25/11. **S21 e S23
> esperam o mantenedor** (seção 3.3). Nada é executado antes disso.
>
> **Depende de:** fase B da [PRD-F](PRD-F-ferramentas-atores.md) (F-05 a
> F-07, a `tarefa`), que entra **antes** desta PRD (S14). A fase A da F (prazo,
> cancelamento e vagas por chamada) já está no master (#80).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio. Se a sessão for interrompida, retome pela
> primeira história sem commit, conferindo `git log --oneline` contra os
> títulos de commit. **Não improvise decisões:** o que não estiver decidido
> aqui volta ao mantenedor como pergunta.

## 1. Visão

A agente é alguém de alguém: conversa, lembra, esquece quando pedem. As
**sondas** são as mãos dela. Uma sonda é uma máquina que a agente dispara
para fazer uma coisa em benefício do par (a pessoa e a agente): procurar
na web, mexer em arquivos no computador, escrever e rodar código. Ela não é
uma segunda agente: não tem nome, caráter nem memória; tem instruções, faz
o trabalho e devolve o resultado.

Sem as sondas, a agente só tem o `web_fetch` de uma URL que ela já conhece:
vira navegação por procuração. Com elas, ela busca, lê, junta, guarda e
calcula, sem prender a conversa.

É aqui que o "sistema operacional" que sobrou na Supernova (ledger com
admissão, orçamento, capacidades, isolamento, auditoria) passa a ter o
trabalho para o qual foi feito: gente pedindo, máquinas trabalhando, e o
kernel garantindo que ninguém gaste, veja ou toque o que não deve.

## 2. Contexto (conferido em 25/11 no master `6830668`)

### 2.1 O que existe

- **Computador** (`tools/computador.gleam`, `computador/agent.mjs`,
  [`operations/COMPUTADOR.md`](../operations/COMPUTADOR.md)): um container
  gVisor **por instância**, sem segredos, com shell, arquivos em
  `~/trabalho` e um Chromium. A Supernova fala com ele por `POST /v1/run`,
  com token e recusa de requisições vindas do navegador (`Origin`, corpo que
  não é JSON). Imagem `mcr.microsoft.com/playwright:v1.48.0-jammy`,
  `playwright` 1.48.0. Limites: 2 GB, 2 CPUs, 512 processos. Membros não
  têm a capacidade `computador` (`config.default_capabilities_config`).
- **Ferramentas de um membro hoje:** `web`, `web_fetch`, `file_system`,
  `canvas`, `github`, `agenda`, `buscar_conversa`, `lembrar`. **Nenhuma
  busca na web.** A Perplexity só é usada pela memória.
- **Fase A da PRD-F:** cada chamada de ferramenta roda sob um guarda com
  prazo (`core/tool_runner`), morre com o turno, é auditada uma vez, e
  respeita vagas por ferramenta e por agente (`core/tool_slots`).
- **Fase B da PRD-F** (por fazer, antes desta PRD): a `tarefa` em segundo
  plano, dona do processo da agente (`self/desk`), registrada em
  `agents/<pessoa>/self/tasks.jsonl`, entregue por `registry.inject` como
  mensagem no chat de origem, cancelada pelo `/esquecer`, avisada no
  restart.
- **Executor:** `executor.run_with_context` roda um laço de modelo e
  ferramentas com um `RunContext` (admissão no ledger, uso, falha, chamada
  de ferramenta pelo gateway). A reflexão e o drift já o usam com
  `purpose` próprio: é o caminho do condutor.
- **Cliente MCP** (`adapters/mcp_manager.gleam`, `adapters/mcp/stdio.gleam`):
  vivo no boot, sem servidor configurado. Defeitos:
  - descarta o esquema das tools (`parameters: []`, linha 269);
  - só aceita o protocolo `2024-11-05` (o SDK oficial 1.32.2 está em
    `2025-11-25` e aceita `2025-06-18`, `2025-03-26`, `2024-11-05`);
  - abre o processo com `env` sem herdar o ambiente;
  - `tools/list` que falha vira lista vazia, sem log.
- **`provider.ToolParam`** só descreve parâmetros planos (`string`,
  `integer`, `number`, `boolean`). As tools do Playwright MCP usam arrays e
  objetos: o esquema JSON precisa passar inteiro até o provedor
  (`providers/openai.gleam`, `providers/anthropic.gleam`, `llm/stream.gleam`).
- `core/sub_agent` (523 linhas) é código morto da visão antiga; não é a
  base desta PRD.

### 2.2 Servidores conferidos (npm, PyPI e Docker Hub, 25/11)

| Servidor | Versão | Licença | Uso |
|---|---|---|---|
| `@playwright/mcp` (Microsoft) | 0.0.86 (18/11); 0.0.85 (09/11) | Apache-2.0 | Navegador da sonda web. Depende sempre de um `playwright` alfa (0.0.86 → 1.66.0-alpha), que baixa o próprio Chromium. Stdio por padrão; `--isolated` mantém o perfil só em memória. |
| `@modelcontextprotocol/server-filesystem` | 2.4.0 (18/11) | MIT, em transição para Apache-2.0 | Arquivos da sonda disco, presos a uma pasta. |
| SearXNG (`searxng/searxng`) | tags diárias (`2026.11.23-…`) | AGPL-3.0 | Busca da sonda web (S17). JSON precisa ser ligado em `search.formats`. Usado sem modificação, como serviço à parte. |
| Tavily (API) | — | serviço pago, ~1.000 créditos/mês grátis | Segunda opção de busca (S17), com chave na Supernova. |
| `@perplexity-ai/mcp-server` | 1.5.0 | MIT | **Não entra** (S16): exigiria a chave dentro do computador. |
| `mcp-server-git` | 2026.11.18 | MIT | Não entra (S22): a sonda código tem o `git` do shell. |

### 2.3 Busca gratuita por API hoje

A Custom Search do Google não aceita clientes novos e acaba em 01/01/2027;
a Bing Search API foi aposentada em 11/08/2025; a Brave trocou o plano
grátis por US$ 5 mensais de crédito, com cartão. Daí a S17.

## 3. Decisões

### 3.1 Do desenho (24/11)

- **S1. A sonda é do par.** Age em nome da pessoa e da agente dela; herda o
  isolamento (nunca vê outra pessoa), gasta do orçamento da pessoa, passa
  pela admissão no ledger em cada chamada de modelo.
- **S2. Sem memória.** A sonda tem instruções a cumprir. O que importa volta
  para a conversa; a memória continua sendo da agente.
- **S3. Assíncrona, sempre.** A agente dispara e segue conversando; o
  resultado chega depois, como mensagem na fila do chat.
- **S4. Começa pelo computador; o MCP tem de funcionar.** Corrigir o
  cliente MCP é parte desta PRD, não opcional.
- **S5. Uma LLM conduz a sonda**, mesmo quando o trabalho é um script: ela
  dispara atores responsáveis por cada passo determinístico e decide o
  próximo. Os atores são as chamadas de ferramenta da fase A da PRD-F.
- **S6. Especializadas por função:** **disco**, **web**, **código**.
- **S7. Até 7 sondas simultâneas por par.** Duração máxima por tipo,
  configurável: disco 2 min, código 15 min, web 30 min.
- **S8. Modelo do condutor selecionável**, com o da agente como padrão.
- **S9. Membros e admins** disparam sondas, cada um no próprio orçamento
  (com o limite da S15).
- **S10. Os arquivos ficam** no computador ao fim da sonda, para a pessoa
  ver depois.
- **S11. Servidores MCP das sondas rodam dentro do computador**, nunca no
  container da Supernova.
- **S12. Custo máximo por sonda:** US$ 0,20 por padrão, configurável por
  tipo.
- **S13. Primeiro servidor MCP: navegador (Playwright MCP)**, dentro do
  computador, para a sonda web.

### 3.2 Decididas em 25/11

- **S14. Fase B da PRD-F primeiro; a sonda em cima.** A `tarefa` (F-05 a
  F-07) entra como está na PRD-F, antes desta PRD. A sonda é uma tarefa cujo
  trabalho é o condutor: herda o registro, o limite de 7, a entrega, o
  `/esquecer` e o aviso de restart. Esta PRD não refaz nada disso.
- **S15. Web e disco para todos; código só para quem tem `computador`.**
  Enquanto o computador é um só na instância:
  - **web:** para todos, com um navegador **isolado por sonda**
    (`--isolated`, perfil em memória, encerrado no fim);
  - **disco:** para todos, **sem shell**: só o servidor MCP de arquivos,
    preso a `~/pessoas/<id da pessoa>/` (S19);
  - **código:** só para quem tem a capacidade `computador` (hoje, admins),
    porque o shell alcança o computador inteiro. Muda quando houver um
    computador por pessoa (item 4 do roadmap), sem mudar a sonda.
- **S16. Transporte MCP pela porta autenticada.** O serviço do computador
  (`agent.mjs`) abre cada servidor por stdio, um por sonda, e o expõe em
  `POST /v1/mcp`, com o mesmo token e a mesma recusa de requisições vindas do
  navegador. Nenhuma porta nova. Nenhuma chave entra no computador.
- **S17. Busca: SearXNG primeiro, Tavily como segunda opção.** A sonda web
  ganha a ferramenta `buscar`. Por padrão ela consulta um SearXNG
  auto-hospedado; com `search.provider: "tavily"` e a chave em
  `SUPERNOVA_TAVILY_API_KEY`, consulta a Tavily. A chamada parte da
  Supernova; a chave nunca vai para o computador. O Playwright pode ser
  atualizado (autorizado pelo mantenedor).

### 3.3 Recomendações (S18 a S20, S22 e S24 aceitas em 25/11)

- **S18. Onde roda o SearXNG.** Recomendação: um container próprio,
  `searxng`, no perfil `computador` do compose, na rede `computador_net`
  (sai para a internet, não alcança o host nem a LAN pelas mesmas regras de
  firewall), imagem fixada por digest numa tag com pelo menos duas semanas,
  `limiter` desligado e JSON ligado, sem porta publicada. A Supernova fala
  com ele por `http://searxng:8080/search?format=json`. Alternativa: dentro
  do computador, o que mistura um serviço de rede com a máquina que lê
  páginas hostis.
- **S19. A pasta de cada pessoa no computador.** Recomendação:
  `~/pessoas/<hash curto do principal>/sondas/<n>/`, uma pasta por sonda
  dentro da pasta da pessoa. Nada de nome nem id de canal no caminho. A
  sonda disco enxerga a pasta da pessoa inteira (os resultados das sondas
  anteriores); web e código trabalham na pasta da sonda. O `/esquecer` apaga
  `~/pessoas/<hash>/` inteira, coerente com a S10 e com o esquecimento.
- **S20. A ferramenta que a agente vê.** Recomendação: uma ferramenta
  própria, `sonda(tipo, instrucoes)`, que cria uma tarefa da fase B; listar
  e cancelar são as da `tarefa`, que mostra as sondas junto. Instruções de
  até 2.000 caracteres. Alternativa: só a `tarefa`, com
  `ferramenta: "sonda_web"`, mais difícil para o modelo acertar.
- **S21. O fim da sonda.** Recomendação: o condutor termina respondendo
  sem chamar ferramenta; a resposta é o resultado, cortado em 4.000
  caracteres. Limite de 40 rodadas de modelo por sonda, além da duração e do
  custo. A mensagem de entrega diz o desfecho (`concluída`,
  `prazo esgotado`, `custo esgotado`, `falhou`) e, quando houver, a pasta no
  computador.
- **S22. Ferramentas de cada tipo.** Recomendação:
  - **web:** `buscar` (S17) e as tools do Playwright MCP sem `--caps`
    extras (sem `vision`, `pdf`, `devtools`);
  - **disco:** as tools do `server-filesystem`, presas à pasta da pessoa;
  - **código:** as ações `shell`, `read_file`, `write_file`, `list` do
    computador, com o diretório da sonda como diretório de trabalho; sem
    servidor MCP de git (o shell tem `git`).
- **S23. Quantos navegadores ao mesmo tempo.** Cada sonda web abre um
  Chromium; o computador tem 2 GB. Recomendação: no máximo **3 sondas web
  rodando na instância**; a quarta espera vaga (vagas da fase A da F, com
  espera longa, não os 10 s das ferramentas), e a espera conta na duração
  dela. Medido na S-00 antes de fixar.
- **S24. Atualização do Playwright.** Recomendação: a imagem do computador
  passa para a base `mcr.microsoft.com/playwright` da versão estável mais
  nova com pelo menos duas semanas (hoje 1.65.x), e o `@playwright/mcp` é
  fixado numa versão com pelo menos duas semanas, instalando o Chromium que
  ele exige no build. O `computador` atual continua funcionando e é testado
  na nova base.

## 4. Desenho

### 4.1 Do lado da agente

```
sonda(tipo: "web" | "disco" | "codigo", instrucoes)
  → "Sonda web #12 disparada. Avise sua pessoa; o resultado chega como mensagem."
tarefa(acao: "listar")          → tarefas e sondas em andamento
tarefa(acao: "cancelar", id)    → também cancela uma sonda
```

A ferramenta `sonda` só oferece os tipos que a pessoa pode usar (S15). A
descrição diz à agente que a sonda não vê a conversa: tudo o que ela precisa
saber vai nas instruções.

### 4.2 A sonda

```
agente ──sonda()──► tarefa (fase B da F) ──► condutor (executor.run_with_context)
                                               │ purpose "sonda", sem histórico
                                               ├─► buscar ─────────► SearXNG | Tavily
                                               ├─► tools MCP ──POST /v1/mcp──► computador
                                               │                    (stdio: playwright, filesystem)
                                               └─► ações do computador (código)
fim: resultado ──► entrega da tarefa: "[Sonda web #12] concluída: …" no chat de origem
```

- **Condutor:** prompt da função, as instruções e só as ferramentas do
  tipo. Sem núcleo da agente, sem histórico, sem memória (S2). Modelo do
  tipo ou o da agente (S8).
- **Contexto de execução:** o `run_context` da pessoa (admissão, uso e
  gateway com as capacidades dela), com `purpose: "sonda"` e um teto de
  custo da sonda (S12): antes de cada chamada de modelo, o gasto da sonda
  mais a estimativa não pode passar do teto.
- **Ferramentas:** cada chamada passa pelo gateway (auditoria, capacidades)
  e pelo `tool_runner` (prazo, cancelamento). Cancelar a sonda mata o
  condutor e, com ele, as chamadas (I2 da F) e a sessão MCP no computador.
- **Sessão MCP:** `POST /v1/mcp` com `{"acao": "abrir", "servidor":
  "playwright" | "filesystem", "sessao": <id>, "raiz": <pasta>}`, depois
  `{"acao": "chamar", "sessao", "mensagem": <JSON-RPC>}` e
  `{"acao": "fechar", "sessao"}`. O serviço só abre servidores de uma lista
  fixa na imagem, com argumentos montados por ele (nunca vindos da
  Supernova), e fecha sessões sem uso há 5 minutos.

### 4.3 Privacidade e esquecimento

- A sonda só vê as instruções que a agente escreveu e os resultados das
  próprias ferramentas. A agente decide o que passar.
- O `/esquecer` cancela as sondas do par (fase B da F) e apaga a pasta da
  pessoa no computador (S19).
- Auditoria e métricas: tipo, duração, custo e desfecho; nunca o conteúdo
  nem as instruções.
- O que volta do computador e da busca é dado, nunca instrução, como no
  `computador` de hoje.

### 4.4 Cliente MCP

O cliente passa a:
- decodificar o `inputSchema` de `tools/list` e entregá-lo **inteiro** ao
  provedor (um campo de esquema JSON bruto na `ToolDefinition`, usado quando
  presente; os parâmetros planos continuam para as ferramentas de hoje);
- negociar `2025-11-25`, aceitando `2025-06-18`, `2025-03-26` e
  `2024-11-05`;
- herdar o ambiente ao abrir processo por stdio;
- logar a falha de `tools/list` em vez de devolver lista vazia;
- ter dois transportes: o stdio de hoje e o do computador (S16).

Os servidores MCP ficam disponíveis **às sondas**, não à agente
diretamente.

## 5. Fora de escopo

- Computador por pessoa (item 4 do roadmap). A sonda código se abre para
  membros quando ele existir.
- Sondas que falam com terceiros em nome da pessoa (e-mail, compras,
  mensagens), que preenchem login ou que passam captcha.
- Sondas que disparam sondas.
- Agendamento de sondas recorrentes.
- Entregar arquivos do computador no chat (a pessoa vê depois, S10).

## 6. Quality gates

Os da [PRD-F](PRD-F-ferramentas-atores.md#4-quality-gates): formatação,
build sem warnings, testes, cobertura que não cai, `git status` limpo, só o
dono recebe num subject, nada de `sleep` fixo, TDD com a falha inicial
registrada. Mais:

- **Sem rede, tokens nem LLM reais nos testes.** O computador, o SearXNG e a
  Tavily são falsos nos testes da Supernova (servidor HTTP local, como o
  `discord_fake`). O lado do computador tem testes `node --test` próprios,
  que rodam na imagem.
- **Nenhum segredo sai da Supernova:** um teste confere que nenhuma
  requisição ao computador ou ao SearXNG leva chave de API, token de canal
  ou o token da Tavily.
- Cenário de harness com o mock do LLM, marcado como crítico.

## 7. Invariantes

Os I1 a I8 da PRD-F continuam valendo para a sonda como tarefa. Mais:

- **S-I1 – Só o que a agente passou.** O condutor nunca recebe o histórico,
  o núcleo ou a memória da agente. Teste: as mensagens enviadas ao modelo do
  condutor contêm só o prompt do tipo, as instruções e os resultados de
  ferramentas.
- **S-I2 – Teto de custo.** O gasto de uma sonda nunca passa do teto mais
  uma chamada já admitida. A chamada que passaria é recusada e a sonda
  termina com `custo esgotado`.
- **S-I3 – Capacidades da pessoa.** Uma sonda nunca chama ferramenta que a
  pessoa não poderia chamar, e um membro nunca dispara a sonda código.
- **S-I4 – Pasta da pessoa.** A sonda disco de uma pessoa não lê nem
  escreve fora da pasta dela. Teste no lado do computador, com caminhos
  `..`, absolutos e links simbólicos.
- **S-I5 – Nada sobra.** Sonda concluída, cancelada ou com prazo esgotado
  não deixa sessão MCP nem navegador vivo no computador.

## 8. Histórias

#### S-00: Linha de base e medida do computador

Confira no código o que a seção 2 afirma. Meça, na imagem atual e na nova
(S24), a memória de um Chromium do Playwright MCP sob gVisor, para fixar a
S23. Registre em `docs/relatorios/PRD-S-base.md`.

**Aceite:**
- [ ] Relatório com a memória por navegador e o número de sondas web
      simultâneas que cabe em 2 GB, com folga para o `computador`.
- [ ] Commit: `docs: PRD-S, linha de base`.

#### S-01: Esquema JSON inteiro até o provedor

`ToolDefinition` ganha o esquema bruto opcional; os três codificadores
(OpenAI, Anthropic, stream) usam-no quando presente.

**Aceite:**
- [ ] Testes de tabela: um esquema com array de objetos chega igual ao JSON
      enviado a cada provedor; ferramenta sem esquema bruto sai como hoje.
- [ ] Commit: `feat(llm): ferramentas com esquema JSON completo`.

#### S-02: Cliente MCP corrigido

`inputSchema` decodificado (S-01), versões da seção 4.4, ambiente herdado,
falha de `tools/list` logada. O transporte vira uma interface, com o stdio
de hoje como a primeira implementação.

**Aceite:**
- [ ] Testes com um servidor MCP falso por stdio (script de teste): esquema,
      negociação de cada versão, recusa de versão desconhecida, falha de
      `tools/list` aparece no log.
- [ ] Commit: `fix(mcp): esquemas, versões e ambiente do cliente MCP`.

#### S-03: O computador nova base e com `/v1/mcp`

Imagem na nova base do Playwright (S24), com o `@playwright/mcp` e o
`server-filesystem` fixados. `agent.mjs` ganha `POST /v1/mcp` (S16): lista
fixa de servidores, argumentos montados por ele, raiz presa a
`~/pessoas/<hash>/`, uma sessão por sonda, fechamento por inatividade.

**Aceite:**
- [ ] Testes `node --test`: abrir, chamar e fechar uma sessão; servidor fora
      da lista recusado; raiz fora de `~/pessoas` recusada; requisição com
      `Origin` recusada; sessão parada fecha em 5 min (relógio falso).
- [ ] S-I4 testado com `..`, caminho absoluto e link simbólico.
- [ ] Os testes atuais do computador passam na nova base.
- [ ] Commit: `feat(computador): servidores MCP por sessão atrás da porta autenticada`.

#### S-04: Transporte MCP do computador

Na Supernova, o transporte da S-02 que fala com `/v1/mcp`.

**Aceite:**
- [ ] Testes contra um computador falso (HTTP local): abrir, listar tools,
      chamar, fechar; erro do computador vira erro da ferramenta.
- [ ] Teste: nenhuma requisição leva segredo (seção 6).
- [ ] Commit: `feat(mcp): transporte até o computador`.

#### S-05: `buscar` com SearXNG e Tavily

A ferramenta `buscar(consulta)` devolve até 8 resultados (título, URL,
trecho). Provedor em `search.provider` (`searxng` por padrão, `tavily`), URL
do SearXNG em `search.searxng_url`. Container `searxng` no compose (S18),
com `settings.yml` versionado.

**Aceite:**
- [ ] Testes contra SearXNG e Tavily falsos: resultado normal, vazio, erro
      HTTP, resposta malformada. A chave da Tavily só sai no cabeçalho para a
      Tavily.
- [ ] `docs/operations/COMPUTADOR.md` explica o `searxng` e a troca para a
      Tavily.
- [ ] Commit: `feat(tools): buscar na web com SearXNG ou Tavily`.

#### S-06: O condutor

`sondas/condutor.gleam`: monta o prompt do tipo, as ferramentas do tipo e o
`RunContext` da pessoa com `purpose: "sonda"` e o teto de custo; roda o
laço até a resposta final, o limite de rodadas (S21), o custo ou a duração.

**Aceite:**
- [ ] S-I1, S-I2 e S-I3 testados com o mock do LLM.
- [ ] Teste: limite de rodadas encerra com o desfecho certo.
- [ ] Commit: `feat(sondas): o condutor`.

#### S-07: A ferramenta `sonda`

A `sonda(tipo, instrucoes)` cria uma tarefa da fase B cujo trabalho é o
condutor, com a duração do tipo e a vaga da S23 para a web. `tarefa listar`
e `cancelar` mostram e param sondas. A entrega usa o texto da S21.

**Aceite:**
- [ ] Teste e2e com o mock e o computador falso: disparar, resposta
      imediata, depois `[Sonda web #N] concluída: …` e a resposta da agente.
- [ ] Teste: membro não vê o tipo `codigo`.
- [ ] S-I5: cancelar e esgotar o prazo fecham a sessão MCP no computador
      falso.
- [ ] Commit: `feat(sondas): a agente dispara sondas`.

#### S-08: Esquecimento, telemetria e harness

O `/esquecer` apaga a pasta da pessoa no computador. Métricas
`sondas_running{tipo}`, `sondas_total{tipo,desfecho}` e
`sonda_custo_usd{tipo}`; linha "Sondas" no painel do Grafana. Cenário de
harness: a pessoa pede uma pesquisa; a agente dispara a sonda web, responde
na hora sem inventar o resultado e usa o resultado quando ele chega.

**Aceite:**
- [ ] Teste: depois do `/esquecer`, o computador falso recebeu o pedido de
      apagar a pasta, e nenhuma entrega da sonda acontece.
- [ ] Cenário de harness crítico, com calibração.
- [ ] Atualize `docs/operations/INTERACTION.md`, `COMPUTADOR.md`,
      `PENDENCIAS.md` e o relatório `docs/relatorios/PRD-S.md`.
- [ ] Commit: `feat(sondas): esquecimento, telemetria e harness`.

#### S-09: Piloto manual

Só com o mantenedor: subir o `searxng` e o computador novo no piloto e
pedir uma pesquisa, uma organização de arquivos e (como admin) um script.

**Aceite:**
- [ ] Relatório com as três sondas reais, custo e duração de cada uma.

## 9. Riscos

- **Custo.** Teto por sonda, admissão antes de cada chamada, limite do dia
  da instância e o orçamento da pessoa.
- **Injeção.** A sonda web lê conteúdo hostil. Ela não tem segredos, não
  fala com a pessoa e devolve texto que a agente lê como resultado de
  ferramenta. A sonda web não tem shell.
- **Computador compartilhado.** Até haver um por pessoa, as sondas de
  pessoas diferentes dividem a máquina. Web e disco não têm shell e ficam
  presas ao navegador isolado e à pasta da pessoa; a sonda código, que
  alcança tudo, fica com quem já alcança tudo (admins).
- **SearXNG bloqueado.** Ele consulta outros buscadores a partir de um IP só
  e pode ser bloqueado. A Tavily é a saída, trocada por configuração.
- **Playwright MCP em alfa.** Ele sempre depende de um `playwright` alfa.
  Fixar a versão e atualizar à mão, lendo o changelog.
- **Memória do computador.** Vários Chromiums em 2 GB: a S23 limita, a S-00
  mede.
