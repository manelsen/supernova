[PRD]
# PRD I: a mesma agente em todos os canais

> **Situação em 24/11/2026:** rascunho para o mantenedor. Direção aprovada
> (24/11): ligar canais e desenvolver a identidade junto com a PRD-C, para
> que quem chegar pelo WhatsApp já fale com a mesma agente do Telegram. D1 a
> D5 esperam decisão (seção 5).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio.

## 1. Contexto

Hoje a pessoa é um par canal e usuário: `telegram:123`, `whatsapp:5511…`
(`core/agent_identity.principal_id`, `principal_from_session_id`). Cada
principal tem a própria agente (`data_dir/agents/<principal>/`: self,
memória, conversas, workspace, agenda), o próprio acesso e o próprio
orçamento. A mesma pessoa em dois canais ganha **duas agentes**, que não
sabem uma da outra; o `/esquecer` dado num canal não alcança o outro.

No WhatsApp há um caso a mais: o LID, identificador de privacidade que pode
aparecer no lugar do telefone (PRD-C, D2).

Ponto a favor: a pessoa é derivada em poucos lugares, e quase tudo (pasta
da agente, conversas, acesso, ledger, `/esquecer`) vem dela. A
`buscar_conversa` e o `lembrar` já leem todas as conversas da pasta da
pessoa: com as conversas de dois canais na mesma pasta, a memória entre
canais vem de graça.

## 2. Objetivo

Uma pessoa, uma agente, em quantos canais ela quiser. Ela liga um canal novo
com um código gerado pela agente num canal que já usa. Tudo o que é dela
(agente, memória, acesso, orçamento, agenda, `/esquecer`) passa a valer nos
dois.

## 3. Fora de escopo

- Juntar duas agentes que já existem (as memórias de duas agentes nascidas
  separadas; D2).
- Identidade entre instâncias da Supernova.

## 4. Quality gates

Os de sempre (`AGENTS.md`). Os testes de vínculo usam dois canais falsos
(ou o sim com dois prefixos); nada de canal real.

## 5. Decisões do mantenedor

- **D1. Modelo.**
  - (a) **Apelidos:** a primeira identidade da pessoa continua sendo o
    principal canônico; as outras viram apelidos dela, numa tabela durável.
    Toda derivação de principal resolve o apelido. Sem migração de dados.
  - (b) Uma pessoa com id próprio, acima dos canais, e migração de todas as
    pastas.
  - **Recomendação: (a).** Mesmo efeito, sem migração; (b) pode vir depois,
    se um dia a pessoa precisar existir sem canal nenhum.
- **D2. Ligar um canal em que a pessoa já tem agente.**
  - (a) Recusar: "neste canal você já tem uma agente; para ligar, ela
    precisa ser esquecida aqui primeiro".
  - (b) Juntar: a agente do canal novo é arquivada e as conversas dela vão
    para a pasta da canônica.
  - **Recomendação: (a)** nesta PRD. Juntar duas agentes nascidas
    separadas é uma decisão de produto (qual núcleo fica?) que merece a
    própria conversa.
- **D3. O código.** Gerado por `/vincular` num canal já ligado, **só no
  privado**; 6 caracteres sem ambíguos (sem 0/O, 1/I); vale 10 minutos; um
  uso; 5 tentativas erradas por hora por identidade. No canal novo,
  `/vincular CÓDIGO`. **Recomendação: assim.**
- **D4. `/esquecer` e vínculos.** O `/esquecer` mantém quem a agente se
  tornou (núcleo, nome); os vínculos são da mesma natureza.
  - (a) Mantém os vínculos.
  - (b) Desfaz os vínculos.
  - **Recomendação: (a).** `/desvincular`, num canal ligado, desfaz o
    vínculo daquele canal.
- **D5. Onde a agenda entrega.** Hoje, no canal em que a tarefa foi
  marcada. **Recomendação:** continua assim, e a tarefa marcada num canal
  que depois foi desvinculado passa ao canal canônico.

## 6. Desenho

### 6.1 Tabela de apelidos

`data_dir/identity/aliases.json` (escrita atômica, como o `access.json`):
`apelido → canônico`, com data e canal de origem. Lida no boot e mantida
numa tabela ETS (`supernova_known_ffi` ou própria) para a resolução no
caminho quente. Um apelido nunca aponta para outro apelido.

### 6.2 Um ponto de resolução

`agent_identity.principal_id` e `principal_from_session_id` resolvem o
apelido. Toda derivação de principal passa por elas; um teste de
arquitetura falha se alguém montar `canal <> ":" <> usuário` fora delas. O
id da sessão continua por canal e chat (o arquivo de conversa de cada canal
é separado), mas mora na pasta da pessoa canônica.

### 6.3 Comandos

- `/vincular` (privado, canal ligado): a agente responde com o código e as
  instruções ("no outro app, mande /vincular 4F7K2X em até 10 minutos").
- `/vincular CÓDIGO` (canal novo, privado): confere o código e grava o
  apelido. A agente responde já como ela mesma ("agora é a mesma conversa,
  aqui e no Telegram").
- `/desvincular` num canal ligado desfaz o vínculo daquele canal; no canal
  canônico, lista os canais ligados e desfaz o escolhido (é por onde a
  pessoa corta um vínculo que não reconhece).
- Tudo auditado (quem, canais, quando), nunca o código em log.

### 6.4 Acesso e orçamento

O apelido herda o acesso da pessoa canônica: a identidade nova não precisa
estar em `access.members`. O código só é gerado para quem já tem acesso.
Orçamento e ledger são da pessoa canônica.

### 6.5 WhatsApp e LID

Com a PRD-C (D2), o vínculo LID↔telefone aprendido vira um apelido como os
outros: o LID aponta para `whatsapp:<telefone>`, que pode ser ele mesmo
apelido de `telegram:<id>`.

## 7. Histórias

- **I-01:** tabela de apelidos durável, ETS e resolução nas duas funções
  (6.1, 6.2); teste de arquitetura.
- **I-02:** `/vincular`, `/vincular CÓDIGO`, `/desvincular` (6.3, D3), com
  limite de tentativas e auditoria.
- **I-03:** acesso, orçamento e agenda pela pessoa canônica (6.4, D5);
  `/esquecer` por D4.
- **I-04:** LID como apelido (6.5), junto com a C-04.
- **I-05:** harness: uma persona fala por dois canais (sim com dois
  prefixos); a agente lembra no segundo o que ouviu no primeiro; o
  `/esquecer` em um apaga o que foi dito nos dois.
- **I-06:** documentação (README, `ARCHITECTURE.md`, ajuda dos comandos).

## 8. Critérios de aceite

| Critério | Meta |
|---|---|
| Depois de `/vincular` | a mesma pasta de agente, o mesmo núcleo, a mesma memória nos dois canais |
| `buscar_conversa` / `lembrar` | acham, num canal, o que foi dito no outro |
| `/esquecer` num canal | apaga as conversas e memórias de todos os canais da pessoa |
| Código | expira em 10 min, um uso, 5 erros por hora |
| Identidade nova sem código | continua sendo uma pessoa à parte (sem acesso, se não estiver na lista) |

## 9. Riscos

- **Tomada de conta:** quem obtiver o código liga o próprio WhatsApp à
  agente de outra pessoa e lê a memória dela. Mitigação: o código só existe
  no privado de quem já tem acesso, vale 10 minutos e um uso, e a agente
  avisa no canal canônico ("o WhatsApp +55… foi ligado a você agora; se não
  foi você, mande /desvincular aqui").
- **Sessões em memória:** uma sessão aberta antes do vínculo pode ter
  derivado o principal antigo; o vínculo fecha as sessões da identidade
  nova.
