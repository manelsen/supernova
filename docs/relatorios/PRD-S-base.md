# PRD-S: medida dos navegadores das sondas (S-00, S23)

Medido em 25/11/2026 no host do desenvolvimento, sob gVisor (`runsc`), com
as opções do container do computador (`cap_drop ALL`, `no-new-privileges`,
`shm 1g`, 2 CPUs) e limite de memória de 4 GB para ver além dos 2 GB de
hoje. Base `mcr.microsoft.com/playwright:v1.65.0-noble`, `playwright`
1.65.0, sem tela. Para cada passo, uma sonda nova abre um contexto e uma
página real, espera o `load` mais 3 s, tira uma captura e o snapshot de
acessibilidade (o que o Playwright MCP usa), e a página fica aberta. A
memória é a do container (`docker stats`), 5 s depois de cada passo.

Roteiro: [`dev/sondas/`](../../dev/sondas/) (`run.sh <chromium|webkit>
<contexts|browsers> 7`). Uma rodada de cada; páginas reais variam com
anúncios e rede, então os números são ordem de grandeza.

## Memória do container

| Sondas abertas | Chromium headless shell, um navegador, contexto por sonda | WebKit, um navegador, contexto por sonda | Chromium, um navegador por sonda |
|---|---|---|---|
| 0 (só o navegador) | 163 MB | 111 MB | 91 MB |
| 1 Wikipédia (Brasil) | 366 MB | 484 MB | 505 MB |
| 2 + G1 | 940 MB | 1,28 GB | 1,08 GB (G1 não carregou em 45 s) |
| 3 + GitHub | 1,00 GB | 1,87 GB | 1,24 GB |
| 4 + Mercado Livre | 1,04 GB | 2,32 GB | 1,30 GB |
| 5 + UOL | 1,28 GB | 3,01 GB | 1,77 GB |
| 6 + BBC News | 1,41 GB | 3,52 GB | 1,97 GB |
| 7 + Stack Overflow | **1,52 GB** | **3,75 GB** | **2,16 GB** |
| Tempo total | 177 s | 307 s | 241 s |

## O que isso diz

- **Chromium headless shell com contexto por sonda é o mais leve:** cerca de
  200 MB por sonda em média, 30% menos que um navegador por sonda e 60%
  menos que o WebKit, que também carregou mais devagar.
- **A média engana:** o G1 sozinho levou ~575 MB (anúncios). Uma sonda que
  abre páginas assim pesa o triplo de uma que lê a Wikipédia.
- **Bloqueio de robô:** no Chromium sem tela, o Mercado Livre devolveu uma
  página quase vazia (259 caracteres de snapshot, captura de 18 KB) e o
  Stack Overflow um desafio (captura de 5 KB). O WebKit passou no Mercado
  Livre e também caiu no desafio do Stack Overflow. Isso não é questão de
  memória: a sonda web precisa reconhecer a página de bloqueio e dizer isso
  no resultado, em vez de resumir uma página vazia.
- O Edge não foi medido: é o mesmo motor do Chromium, sem a versão enxuta
  sem tela.
