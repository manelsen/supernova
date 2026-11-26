# PRD-K: linha de base (K-00)

Medido em 26/11/2026, no host do piloto (6 núcleos, 11 GB), com a imagem do
computador do master `f779fde` (PRD-S), sob gVisor (`runsc`), com os limites
da PRD-K: 1,5 GB de memória, sem capacidades, `no-new-privileges`, 512 MB de
`/dev/shm`.

## Quanto leva para ligar

Três rodadas de cada. "Serviço responde" é do `docker run` até o primeiro
`GET /health` com sucesso; "primeira página" é o primeiro `goto` a uma
página real (`https://example.com`), que abre o Chromium.

| Situação | Serviço responde | Primeira página |
|---|---|---|
| Computador novo (volume vazio) | 0,8–1,6 s | 3,7–4,0 s |
| Volume existente (perfil e arquivos da pessoa) | 0,9–1,1 s | 2,5–2,7 s |

Com o "liga quando usa" (K18), a primeira ação de uma pessoa depois de 15 min
parada custa de 2,5 a 4 s a mais. A primeira vez de todas (volume novo) é a
mais lenta.

## Quanto ocupa parado

Com o navegador aberto numa página simples e nada rodando: **cerca de
182 MB** por computador. Quatro computadores parados juntos ocupam menos de
1 GB; o teto de 1,5 GB (K19) é para o trabalho, não para o repouso.

## Conferência da seção 2

Conferida contra o master do dia. Um ponto a acrescentar, achado na revisão de
segurança de 26/11: **a Supernova está na rede do computador**
(`computador_net`), para chamá-lo; por isso o computador também alcança as
portas dela. As regras de firewall do host só filtram o que sai da ponte. A
PRD-K tira a Supernova dessa rede (seção 3.3); até lá, o navegador do
computador recusa endereços internos (`computador/rede.mjs`).

## Como medir de novo

O roteiro está no histórico desta história: um `docker run` por rodada com os
limites acima, cronometrando o `/health` e o primeiro `goto`, e `docker stats`
três segundos depois.
