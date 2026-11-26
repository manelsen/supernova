# PRD-S: sondas (S-00 a S-08)

Executada em 26/11/2026, na branch `prd-s/execucao`, empilhada sobre a fase
B da PRD-F (`prd-f/fase-b`). A medida dos navegadores (S-00, S23) está em
[`PRD-S-base.md`](PRD-S-base.md).

## O que entrou, por história

| História | O quê |
|---|---|
| S-01 | `ToolDefinition` carrega o esquema JSON inteiro (`schema`), usado por OpenAI, Anthropic e streaming (`provider.parameters_schema`). **Achado:** o streaming da Anthropic mandava as ferramentas no formato da OpenAI; corrigido. |
| S-02 | `adapters/mcp/protocol`: o protocolo fora do transporte. O cliente pede `2025-11-25` e aceita `2025-06-18`, `2025-03-26`, `2024-11-05`; as tools levam o `inputSchema`; `tools/list` ilegível vira erro no log. |
| S-03 | `computador/mcp.mjs` e `POST /v1/mcp`. Base `playwright:v1.65.0-noble`, `@playwright/mcp` 0.0.85, `server-filesystem` 2.3.0, computador com 3 GB. |
| S-04 | `adapters/mcp/computer`: abrir, chamar, fechar, guardar o resultado e apagar a pasta da pessoa pelo `/v1/mcp`. |
| S-05 | `sondas/buscar`: SearXNG por padrão (container `searxng` fixado por digest, sem porta publicada) e Tavily por configuração. |
| S-06 | `sondas/condutor`: prompt do tipo, só as ferramentas do tipo, teto de custo na admissão, até 40 rodadas (`RunContext.max_rounds`). |
| S-07 | `sondas/sonda` (a ferramenta), `sondas/maos` (as ferramentas de cada tipo), `tasks.begin_work` (trabalho com o id da tarefa e prazo próprio), vagas `sonda_web` (5 na instância). |
| S-08 | `/esquecer` apaga a pasta da pessoa no computador; métricas `sondas_total`, `sondas_custo_microusd_total`; linha "Tarefas e sondas" no Grafana; docs. |

## Achados de segurança no caminho

O Playwright MCP oferece mais do que uma sonda de membro pode ter, num
computador que hoje é um só para a instância:

- **`browser_run_code_unsafe`** roda código no processo do serviço do
  computador: equivale a um shell. **Fora.**
- **`browser_file_upload`** e **`browser_drop`** mandam arquivos do
  computador para um site: arquivos de outra pessoa poderiam sair. **Fora.**
- **`file://`** deixaria a sonda ler arquivos do computador pelo navegador.
  O serviço só aceita URLs `http(s)`, em qualquer argumento.
- **`localhost`**: o navegador das sondas não abre páginas da própria
  máquina (o serviço do computador escuta ali). Testado.
- **WebMCP** (ferramentas que uma página registra) desligado: seria um
  canal de injeção.

A lista de ferramentas permitidas está em `computador/mcp.mjs`
(`BROWSER_TOOLS`); uma versão nova do Playwright MCP com ferramentas novas
não as expõe até alguém as acrescentar.

## Correção de uma afirmação da PRD

A seção 2 dizia que o cliente MCP "abre o processo com `env` sem herdar o
ambiente". **É o contrário:** o `open_port` do Erlang estende o ambiente
do processo pai com o `env` dado. O teste
`the_server_inherits_the_environment_test` confirma. Para as sondas isso
não importa (os servidores rodam no computador, com só `PATH` e `HOME`).
Mas um servidor MCP configurado por stdio **no container da Supernova**
recebe todas as chaves dela. Hoje nenhum está configurado; se um dia
estiver, vale decidir se ele deve receber um ambiente limpo.

## Diferenças do desenho

- **Busca por variáveis de ambiente**, não por `search.provider` no
  `supernova.yaml`: `SUPERNOVA_SEARCH_PROVIDER`, `SUPERNOVA_SEARXNG_URL`,
  `SUPERNOVA_TAVILY_API_KEY`, como o computador (`SUPERNOVA_COMPUTER_URL`).
- **Playwright alfa no computador inteiro.** O Playwright MCP exige o
  Playwright alfa com que foi feito (0.0.85 → `1.66.0-alpha-2026-11-09`).
  Duas cópias do Playwright no mesmo processo não compartilham o navegador,
  então o serviço usa a alfa também para o `computador` dos admins. Os 14
  testes antigos do computador passam nela. A base continua a `v1.65.0-noble`
  (S24), e o build instala o Chromium sem tela da alfa.
- **Fechar a sessão MCP não fecha o contexto** do navegador no Playwright
  MCP; o serviço fecha os dois.
- **A espera por vaga** de uma sonda web vai até o prazo do tipo, mas o
  prazo da chamada só começa quando a vaga sai (comportamento do
  `tool_runner` da fase A). Na prática, uma sonda web pode esperar até 30
  min e rodar mais 30.
- **O modelo do condutor** é o da agente (S8, padrão). Escolher outro por
  tipo ficou para quando houver pedido.

## Testes

- Suíte inteira: 2995 testes, cobertura 82,86% (fase B da F: 82,53%).
- Supernova: `test/llm/tool_schema_test.gleam`,
  `test/adapters/mcp_protocol_test.gleam`,
  `test/adapters/mcp_computer_test.gleam`, `test/sondas/buscar_test.gleam`,
  `test/sondas/condutor_test.gleam`, `test/sondas/sonda_test.gleam`,
  `test/e2e/sonda_e2e_test.gleam`. Sem rede: computador, SearXNG e Tavily
  falsos.
- Computador, na imagem e sob gVisor: 24 testes
  (`docker run --rm --runtime=runsc --cap-drop ALL --shm-size 1g
  supernova-computador npm test --prefix /opt/computador`), entre eles
  S-I4 (`..`, caminho absoluto, link simbólico) e o bloqueio de
  `localhost` e `file://`.
- SearXNG com o `settings.yml` do repositório, de verdade, uma vez: 45
  resultados em JSON; DuckDuckGo pediu captcha e o Wikidata recusou, e ele
  seguiu com os outros. Alguns resultados vêm com URL sem domínio
  (`http:///go/v1/…`), que a `buscar` descarta.

## Pendente

- **S-09, o piloto manual** com o mantenedor.
- **O cenário de harness**, pelo mesmo motivo da fase B da PRD-F: o
  harness não espera tarefas nem capta mensagens injetadas.
- **Rotacionar** as chaves do Gemini e da Perplexity que passaram pelo chat
  (lembrete antigo).
