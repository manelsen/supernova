[PRD]
# PRD W: instalar a Supernova com Docker e gVisor

> **Situação em 26/11/2026:** aprovada pelo mantenedor, com as
> consequências da seção 3.1.
> Decisões tomadas com ele em 26/11 (seção 3). Substitui a
> [`PRD-wizard.md`](PRD-wizard.md) (quickstart com `systemd`), marcada como
> superada.
>
> **Depende de:** [PRD-K](PRD-K-computador-e-aprovacao.md) (o despachante,
> o proxy de saída e o túnel que o wizard instala). Executa depois dela.

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio. **Não improvise decisões:** o que não
> estiver decidido aqui volta ao mantenedor como pergunta.

## 1. Visão

Quem instala é um voluntário: um parente, alguém de uma ONG, que sabe abrir
um terminal e seguir um guia, mas não conhece a Supernova por dentro. Pode
ser cego e usar leitor de tela pelo SSH. O wizard leva essa pessoa de uma
máquina Linux vazia a uma instância rodando, com o computador das agentes
isolado, e ensina o que está fazendo no caminho.

## 2. Contexto (conferido em 26/11 no master `7642425`)

- `src/supernova/wizard.gleam` (963 linhas): wizard antigo de canais, em
  Gleam, que gera `supernova.yaml`; roda com `gleam run`, ou seja, exige o
  Gleam no host.
- `bin/supernova`: CLI local (configure, start, logs…) sobre `make` e o
  código-fonte.
- `.github/workflows/docker.yml` publica **só a imagem da Supernova** no
  GHCR, amd64 e arm64, em tags `v*`. O computador não é publicado; o
  despachante, o proxy e o túnel (PRD-K) ainda não existem.
- O `computador` pede passos manuais com `sudo` (gVisor, regras de
  firewall) descritos em `docs/operations/COMPUTADOR.md`; as regras nunca
  foram aplicadas num host pelo roteiro.
- O que a seção 2.1 do `PENDENCIAS.md` manda aproveitar da PRD antiga:
  wizard obrigatório antes da primeira subida, modo não interativo,
  `supernova.yaml` × `.env` (modo 600), resumo com confirmação, detecção do
  ambiente (Docker, Compose ≥ 2.33.1, `runsc`, KVM), smoke test.

## 3. Decisões (26/11, com o mantenedor)

| # | Decisão |
|---|---|
| W1 | Quem instala: **voluntário técnico**, com terminal e `sudo`. |
| W2 | **Acessível a leitor de tela**: texto simples, uma pergunta por linha, sem caixas desenhadas nem menus de setas, cor só como enfeite, cada pergunta diz o padrão e como responder. |
| W3 | Passos com `sudo`: **mostra os comandos exatos, explica, pede confirmação, roda e confere**. |
| W4 | Imagens **publicadas** (não constrói local). |
| W5 | **CI publica na tag**: o mantenedor cria `vX.Y.Z`; o GitHub Actions constrói e publica todas as imagens. Agentes nunca publicam. |
| W6 | **amd64 e arm64.** |
| W7 | Canais no wizard: **Telegram, Discord e WhatsApp**. Os outros só no `supernova.yaml`, à mão. |
| W8 | **Atualiza também**, com backup antes e volta à versão anterior se o boot falhar. |
| W9 | A instância nasce em **grupo fechado**; o modo aberto fica fora. |
| W10 | Primeiro admin por **código de pareamento** de uso único. |
| W11 | Confere as chaves com **uma chamada real mínima** por chave. |
| W12 | **Liga tudo por padrão** (computador, sondas); pergunta só o que exige chave (memória, túnel com domínio próprio) e desliga o que o host não aguenta. |
| W13 | Fala **português**. |
| W14 | Memória: com **8 GB** liga o computador com 4 vagas; com menos, menos vagas, e diz isso. |

### 3.1 Consequências das decisões (para o mantenedor vetar, se quiser)

- **Duas partes.** Os passos no host (detectar, `sudo`, baixar) são um
  script `instalar.sh` em bash; as perguntas são o wizard em Gleam, que
  roda **dentro da imagem publicada** (`docker compose run --rm supernova
  wizard`). Assim o host não precisa de Gleam, e as perguntas continuam
  testadas como hoje.
- **Como baixar:** a página da versão no GitHub traz `instalar.sh` e o
  `sha256` dele; o guia manda baixar, conferir o `sha256`, ler e rodar.
  Nada de `curl | sh` direto.
- **Onde instala:** `/opt/supernova` (dados em volumes Docker nomeados).
- **Vagas do computador:** `min(4, ⌊(memória em GB − 1,5) / 1,5⌋)`; zero
  vagas (menos de 3 GB) deixa o computador desligado e diz por quê. Sem
  `runsc` funcionando, também desligado.
- **Túnel:** com um token do Cloudflare (domínio próprio), túnel fixo; sem
  token, o túnel temporário gratuito, avisando que o endereço muda a cada
  reinício.
- **Pareamento:** o código vale 30 min e um uso; quem mandar o código ao
  bot (em qualquer canal configurado) vira admin. Depois do primeiro admin,
  novos códigos só por `/acesso` de um admin.
- **Backup do `atualizar`:** volumes de dados e de computadores num
  `.tar.zst` em `/opt/supernova/backups/`, mantendo os 3 últimos.

## 4. Fora de escopo

- Instalação sem terminal (página web).
- Modo aberto.
- Outras línguas.
- Construir as imagens no host.
- Matrix, Slack e os demais canais no wizard.

## 5. Quality gates

Os do projeto. Mais:

- `instalar.sh` passa no `shellcheck`.
- **Acessibilidade:** um teste varre todas as saídas do wizard e recusa
  caracteres de desenho de caixa, sequências de cursor e linhas acima de
  100 colunas; cada pergunta termina dizendo o padrão.
- **Sem rede nos testes:** as chamadas de conferência (W11) usam servidores
  falsos (os de Telegram, Discord e do modelo que já existem).
- Smoke test no CI: instalação não interativa num runner, com chaves
  falsas e conferência desligada, até `/health/ready`.

## 6. Histórias

#### W-00: Linha de base

Conferir a seção 2 no master do dia; listar o que o wizard antigo pergunta
e o que se aproveita.

**Aceite:**
- [ ] `docs/relatorios/PRD-W-base.md`.
- [ ] Commit: `docs: PRD-W, linha de base`.

#### W-01: Release de todas as imagens

O workflow de tag publica `supernova`, `computador`, `despachante`, `saida`
(e o que mais a PRD-K criar), amd64 e arm64; o `docker-compose.yml` de
release aponta para elas por versão e digest; a página da versão leva
`instalar.sh`, o compose e os `sha256`.

**Aceite:**
- [ ] Workflow testado com `workflow_dispatch` sem publicar.
- [ ] Commit: `ci: publica todas as imagens na tag`.

#### W-02: `instalar.sh`, detecção

Sistema, arquitetura, Docker, Compose ≥ 2.33.1, `runsc`, KVM, memória,
disco, portas; texto simples (W2), em português (W13). Cada falta diz o que
fazer.

**Aceite:**
- [ ] Testes com ambientes simulados (comandos falsos no `PATH`).
- [ ] Commit: `feat(instalar): detecção do ambiente`.

#### W-03: Passos com `sudo`

Instalar e registrar o gVisor; regras de firewall da rede dos computadores
(as de `COMPUTADOR.md`, persistentes); cada passo mostra os comandos,
explica, pede confirmação, roda e confere (W3): `dmesg` do gVisor; um
computador de teste não alcança o host nem a LAN.

**Aceite:**
- [ ] Teste dos textos e da ordem; conferências testadas com comandos
      falsos.
- [ ] Commit: `feat(instalar): gVisor e firewall`.

#### W-04: As perguntas

O wizard em Gleam, na imagem: provedor e modelo da agente, canais (W7),
chave da memória (opcional), túnel (seção 3.1), resumo dos recursos que vão
ligar (W12, W14). Confere cada chave com uma chamada mínima (W11).
Acessível (W2).

**Aceite:**
- [ ] Teste de acessibilidade (seção 5).
- [ ] Chave errada aparece na pergunta, com o motivo, e pede de novo.
- [ ] Commit: `feat(wizard): perguntas acessíveis`.

#### W-05: Arquivos, resumo e primeira subida

Gera `supernova.yaml` (grupo fechado, W9) e `.env` (600); mostra o resumo;
pede confirmação explícita; sobe; espera `/health/ready`.

**Aceite:**
- [ ] Sem confirmação, nada sobe.
- [ ] Commit: `feat(wizard): resumo e primeira subida`.

#### W-06: Código de pareamento

O wizard mostra o código; quem mandar ao bot vira admin (seção 3.1).

**Aceite:**
- [ ] Uso único, 30 min, testado em Telegram e Discord falsos.
- [ ] Commit: `feat(acesso): primeiro admin por código`.

#### W-07: Modo não interativo

As mesmas respostas por arquivo ou variáveis de ambiente; mesma validação;
usado pelo smoke test.

**Aceite:**
- [ ] Smoke test no CI (seção 5).
- [ ] Commit: `feat(instalar): modo não interativo`.

#### W-08: Atualizar

`supernova atualizar`: baixa a versão nova, faz o backup (seção 3.1),
sobe, espera `/health/ready`; se falhar, volta à anterior e restaura.

**Aceite:**
- [ ] Teste de volta com uma imagem que não sobe.
- [ ] Commit: `feat(instalar): atualizar com backup`.

#### W-09: Guia e limpeza

`docs/operations/INSTALAR.md` em português, escrito para leitor de tela;
`bin/supernova` e o wizard antigo absorvidos ou apagados; a
`PRD-wizard.md` marcada como superada; `PENDENCIAS` 2.1 fechada.

**Aceite:**
- [ ] Um teste confere que todo comando citado no guia existe.
- [ ] Commit: `docs: guia de instalação`.

#### W-10: Piloto manual

O mantenedor (ou um voluntário) instala numa máquina limpa, seguindo só o
guia; se possível, com leitor de tela.

**Aceite:**
- [ ] Relatório com tempo, dúvidas e travas.

## 7. Riscos

- **`sudo` em script baixado.** Mitigação: `sha256` publicado, comandos
  mostrados antes de rodar, nada sem confirmação.
- **Distribuições diferentes.** O gVisor e o firewall variam; o guia cobre
  Debian e Ubuntu, e o wizard para com uma explicação nas outras.
- **Túnel temporário** muda de endereço a cada reinício: links da tela
  antigos deixam de abrir (eles já expiram em 15 min).
- **arm64** depende do gVisor e do Chromium sem tela em arm64; conferido
  na W-01.
