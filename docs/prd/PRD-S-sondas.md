[PRD]
# PRD S: sondas, os subagentes do par

> **Situação em 24/11/2026:** rascunho de **desenho**, não de execução. As
> decisões da seção 3 vêm do mantenedor (24/11); as perguntas da seção 7
> fecham o desenho. As histórias detalhadas virão numa segunda versão,
> depois das PRDs E e C.

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

## 7. Perguntas para fechar o desenho

1. **Limites iniciais:** quantas sondas simultâneas por par, duração máxima
   e custo máximo por sonda?
2. **Modelo do condutor:** o mesmo da agente (DeepSeek) ou um próprio,
   configurável por função?
3. **Quem pode disparar:** só admins no começo, ou membros com o orçamento
   de membro?
4. **Primeiro servidor MCP:** qual ligar primeiro (sistema de arquivos,
   navegador, busca)?
5. **Resultado no computador:** a sonda de código deixa os arquivos no
   computador da agente para a pessoa ver depois, ou limpa ao terminar?
