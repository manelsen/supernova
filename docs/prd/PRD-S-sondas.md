[PRD]
# PRD S: sondas, os subagentes do par

> **Situação em 24/11/2026:** desenho com as decisões do mantenedor (S1 a
> S11). As histórias detalhadas virão numa segunda versão, depois das PRDs E
> e C, com os servidores MCP conferidos (nome, licença, versão).

## 1. Visão

A agente é alguém de alguém: conversa, lembra, esquece quando pedem. As
**sondas** são as mãos dela. Uma sonda é uma máquina que a agente dispara
para fazer uma coisa em benefício do par (a pessoa e a agente): procurar
na web, mexer em arquivos no computador, escrever e rodar código. Ela não é
uma segunda agente: não tem nome, caráter nem memória; tem instruções, faz
o trabalho e devolve o resultado.

É aqui que o "sistema operacional" que sobrou na Supernova (ledger com
admissão, orçamento, capacidades, isolamento, auditoria) passa a ter o
trabalho para o qual foi feito: gente pedindo, máquinas trabalhando, e o
kernel garantindo que ninguém gaste, veja ou toque o que não deve.

## 2. Contexto

- O `computador` existe: uma máquina Linux por agente, isolada (gVisor),
  sem segredos, com shell, arquivos e um Chromium (`tools/computador.gleam`,
  `docs/operations/COMPUTADOR.md`).
- A agenda já injeta mensagens na fila do chat de uma pessoa
  (`agenda/sweeper.gleam`, "[Agenda] Chegou a hora…"): é o caminho natural
  para "a sonda terminou".
- O cliente MCP está vivo (`adapters/mcp_manager.gleam`), mas descarta o
  esquema das tools (`parameters: []`, linha 269): o modelo recebe tools
  sem saber os argumentos. A auditoria aponta ainda o `env` que não herda o
  ambiente e versões de protocolo recusadas.
- `core/sub_agent` (523 linhas) é código morto da visão antiga de "SO de
  agentes"; não é a base desta PRD.

## 3. Decisões do mantenedor (24/11)

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
  próximo. Determinístico onde dá, LLM para conduzir.
- **S6. Especializadas por função.** Primeiras sondas: **disco** (arquivos
  no computador), **web** (pesquisa e coleta), **código** (escrever, rodar,
  testar no computador).
- **S7. Até 7 sondas simultâneas por par.** Duração máxima por tipo, porque
  um minuto é muito para um `ls` e pouco para um crawling. Padrões
  propostos, configuráveis: disco 2 min, código 15 min, web 30 min.
- **S8. Modelo do condutor selecionável**, com o da agente como padrão.
- **S9. Membros e admins** disparam sondas, cada um no próprio orçamento.
- **S10. Os arquivos ficam** no computador da agente ao fim da sonda, para a
  pessoa ver depois.
- **S11. Servidores MCP das sondas rodam dentro do computador.** O
  gerenciador atual abre servidores por stdio dentro do contêiner da
  Supernova: um MCP de arquivos ali mexeria no disco da Supernova, não no do
  computador. Dentro do computador (isolado, sem segredos), a Supernova fala
  com eles pela rede. Primeiros, a conferir: um navegador (Playwright MCP)
  para a sonda web; a busca da Perplexity (servidor MCP da API Sonar, a
  chave já existe); arquivos e git (servidores de referência do MCP) para
  disco e código. O navegador vem primeiro.

## 4. Desenho proposto

### 4.1 Do lado da agente

Uma tool `disparar_sonda(tipo, instrucoes)` devolve na hora um ticket
("sonda web #12 disparada; aviso quando terminar") e a agente segue a
conversa. `consultar_sondas` lista as em andamento do par; `cancelar_sonda`
para uma.

### 4.2 A sonda

Um processo supervisionado por par (como a fila do chat), com:

- **condutor:** uma LLM com um prompt da função (disco, web, código), as
  instruções da agente e **só** as tools da função; sem histórico da
  conversa, sem o núcleo da agente;
- **atores:** passos determinísticos que o condutor dispara (rodar um
  comando no computador, baixar uma página, chamar uma tool MCP), cada um
  com tempo-limite e teto de saída (PRD-E);
- **limites:** duração máxima, custo máximo por sonda (admitido no ledger
  antes de começar e liquidado no fim), número de sondas simultâneas por
  par;
- **fim:** um resultado curto e verificável (o que foi feito, o que foi
  achado, onde está no computador), entregue como mensagem
  "[Sonda web #12] …" na fila do chat da pessoa; a agente lê e responde.

### 4.3 Privacidade e esquecimento

- A sonda só vê as instruções que a agente escreveu e os resultados das
  próprias tools. A agente decide o que passar.
- `/esquecer` cancela as sondas do par e apaga os resultados guardados.
- Auditoria: tipo, duração, custo e desfecho; nunca o conteúdo.

### 4.4 MCP

O cliente MCP passa a: decodificar o `inputSchema` de `tools/list` em
parâmetros de verdade; herdar o ambiente ao abrir o processo; aceitar as
versões de protocolo correntes; logar a falha de `tools/list` em vez de
devolver lista vazia. Servidores MCP ficam disponíveis **às sondas**, não à
agente diretamente (a agente pede; a sonda usa).

## 5. Fora de escopo (desta PRD)

- Sondas que falam com terceiros em nome da pessoa (e-mail, compras,
  mensagens).
- Sondas que disparam sondas.
- Agendamento de sondas recorrentes (pode vir depois, com a agenda).

## 6. Riscos

- **Custo.** Uma sonda com LLM em laço pode gastar muito: teto por sonda,
  admissão antes, liquidação depois, e o limite do dia da instância.
- **Injeção.** A sonda web lê conteúdo hostil. Ela não tem segredos, não
  fala com a pessoa diretamente e devolve texto que a agente lê como
  resultado de tool, não como instrução.
- **Computador compartilhado entre sondas do mesmo par.** Duas sondas no
  mesmo computador ao mesmo tempo podem pisar uma na outra: diretório de
  trabalho por sonda.

## 7. O que falta decidir

- **Custo máximo por sonda** (proposta: US$ 0,20 por padrão, configurável
  por tipo).
- **Transporte MCP até o computador:** HTTP streamable ou SSE, conforme o
  que os servidores escolhidos suportarem.
