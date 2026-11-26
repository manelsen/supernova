[PRD]
# PRD K: um computador para cada pessoa, e nada sai dele sem ela aprovar

> **Situação em 26/11/2026:** aprovada pelo mantenedor, com as
> consequências da seção 3.3. Todas as decisões de desenho foram tomadas
> com ele em 26/11 (seção 3); o que resta é execução.
>
> **Depende de:** PRD-F (tarefas, #80 e #82), PRD-S (sondas, #83), ambiente
> limpo do MCP (#84) e `wait_tasks` no harness (#85), todos no master.
> **Vem antes de:** [PRD-W](PRD-W-wizard.md) (o wizard instala o que esta
> PRD cria).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio. Se a sessão for interrompida, retome pela
> primeira história sem commit, conferindo `git log --oneline` contra os
> títulos de commit. **Não improvise decisões:** o que não estiver decidido
> aqui volta ao mantenedor como pergunta.

## 1. Visão

O piloto vai ter pessoas que não conseguiriam usar um computador com
maestria de outro jeito: cegas, tetraplégicas. Para elas, a agente com um
computador não é conveniência, é autonomia: pagar uma conta, marcar uma
consulta, achar um documento no gov.br, organizar os próprios arquivos.

Isso só vale se for seguro. A agente lê páginas hostis, pode ser enganada,
pode errar. Por isso, duas promessas, garantidas pelo **código**, não pelo
modelo:

1. **Cada pessoa tem o seu computador.** Ninguém vê, usa ou apaga o que é
   de outra pessoa. O `/esquecer` apaga tudo.
2. **Nada sai do computador sem a pessoa aprovar.** Enviar, pagar,
   publicar, entrar numa conta, apagar um arquivo dela, gastar muito: a
   agente pede, a pessoa responde do jeito que conseguir (botão, texto ou
   voz), e só então acontece.

E um princípio de acessibilidade que atravessa tudo: **a pessoa pode não
enxergar a tela nem usar as mãos.** Todo pedido se responde por voz; toda
mensagem começa pelo essencial, curta, para o leitor de tela; nada depende
de ver uma imagem.

## 2. Contexto (conferido em 26/11 no master `7642425`)

- **Um computador por instância** (`computador/`, container com gVisor,
  3 GB), só para admins (`computador` negado a membros por padrão). A
  descrição da ferramenta promete "a Linux machine that is yours alone":
  só é verdade com um admin.
- **Ações do computador** (`tools/computador.gleam`): `exec`;
  `read_file`, `write_file`, `list`; navegador `goto`, `back`, `click`,
  `type`, `press`, `scroll`, `text`, `screenshot`, `evaluate`, `close`.
- **Sondas** (PRD-S) usam o mesmo computador por `/v1/mcp`: Playwright MCP
  (um Chromium sem tela compartilhado, um contexto por sonda) e o servidor
  de arquivos preso a `/home/pwuser/pessoas/<hash>`. `computer.person_hash`
  já identifica a pessoa; `computer.forget_person` apaga a pasta dela.
- **Rede do computador:** rede própria (`br-computador`) e regras de firewall
  no host: alcança a internet, não o host nem a LAN. **O computador não
  consegue chamar a Supernova.**
- **Botões existem** no Port (`ChannelInteractiveReply`,
  `InboundInteraction`), renderizados em Telegram, Discord e Slack. WhatsApp
  não tem botões.
- **Áudio vira texto** antes do modelo (PRD-A): uma nota de voz chega como
  transcrição.
- **Entrega no privado** existe (`traits.private_delivery`, usada pela
  agenda e pelas tarefas) em Telegram, Discord, WhatsApp e sim.
- **Mensagens injetadas** (`registry.inject`) entregam resultados à agente
  como turnos, e o sim marca o fim delas (#85).
- **O container da Supernova não tem o socket do Docker.**

## 3. Decisões (26/11, com o mantenedor)

### 3.1 Aprovação

| # | Decisão |
|---|---|
| K1 | A pessoa responde por **botão, texto ou voz**. O **código** reconhece a resposta (não o modelo). |
| K2 | Exigem aprovação: **efeitos fora da máquina**, **entrar em contas**, **apagar ou sobrescrever arquivos da pessoa**, **tarefa com teto acima de US$ 0,50**. |
| K3 | **Só a própria pessoa** aprova. |
| K4 | **Permissões permanentes por tipo e destino**, estreitas, listáveis e revogáveis. |
| K5 | A garantia é **um portão na rede**: no navegador, o serviço intercepta pedidos que mudam estado; no shell, a saída passa por um proxy que só deixa ler e baixar de repositórios conhecidos. |
| K6 | Sem resposta: **fica pendente até 24 h, com um lembrete**, e expira como recusado; a agente avisa. |
| K7 | O texto do pedido: **a primeira frase é do código**, fixa e curta, com o essencial; depois vem a explicação da agente. |
| K8 | Teto de gasto: **US$ 0,50 por tarefa**. |
| K9 | Pedido nascido num grupo vai para o **privado da pessoa**; no grupo, a agente só diz que pediu confirmação no privado. |
| K10 | No navegador, **dois níveis**: (1) o primeiro pedido que muda estado num site pede "usar o site X nesta tarefa" (ou sempre), liberando o tráfego de fundo; (2) **enviar formulário ou clicar em botão de envio sempre pede**, com o resumo do que vai. |
| K11 | A ação `evaluate` (JavaScript arbitrário na página) **sai**. |

### 3.2 Computador

| # | Decisão |
|---|---|
| K12 | **Cofre de senhas fora do modelo**: a pessoa passa a senha por um comando; o código guarda cifrada e preenche o campo direto no navegador. A senha nunca vai ao modelo nem ao histórico. |
| K13 | O cofre fica **nos dados da Supernova, cifrado** com uma chave do `.env`; o computador só recebe a senha na hora de preencher e nunca a guarda. |
| K14 | **Sessões (cookies) ficam salvas** no navegador da pessoa entre tarefas; somem no `/esquecer`; a pessoa pode pedir para sair de um site. |
| K15 | **Captcha: pede ajuda humana.** A agente para, avisa e oferece o link da tela. Não tenta burlar. |
| K16 | O link da tela vai **para a própria pessoa**, vale **15 min e uma sessão**; ela abre ou encaminha a quem a ajuda. |
| K17 | O link sai por um **túnel do Cloudflare** (`cloudflared` no compose), que publica só o caminho da tela, com HTTPS, sem abrir porta. |
| K18 | O computador **liga quando usa** e desliga após **15 min parado**; arquivos e sessões ficam num volume. |
| K19 | **1,5 GB por computador, até 4 ligados.** Um quinto espera vaga, ou o mais parado é desligado. |
| K20 | Um **despachante** separado, com o socket do Docker, liga, desliga e apaga computadores; imagem, limites e gVisor são fixos nele. **A Supernova nunca tem o socket.** |
| K21 | A lista de sites do shell (fábrica: pip, npm, apt, GitHub) **cresce pela pessoa, com aprovação**, só para ela. |
| K22 | No shell, **a pasta da pessoa é só leitura**; o shell trabalha numa pasta de rascunho. Gravar na pasta dela só pela ferramenta de arquivos: criar passa direto; sobrescrever e apagar pedem aprovação. |
| K23 | Com o computador por pessoa, **`computador` e a sonda código abrem para todos os membros** (condição da S15). |

### 3.3 Consequências das decisões (para o mantenedor vetar, se quiser)

Regras que saem das respostas acima. **Se alguma estiver errada, mude aqui
antes da execução.**

- **A aprovação é uma autorização, não uma espera.** O computador não
  alcança a Supernova (firewall), então não dá para segurar um pedido 24 h.
  O portão recusa o pedido, a Supernova cria o pedido de aprovação, e o
  "sim" vira uma **autorização** (uso único, da tarefa ou permanente) que o
  portão consulta. A agente recebe "[Aprovação #N] aprovada" (mensagem
  injetada) e refaz o passo.
- **Permissão permanente vale para:** usar um site (nível 1 do K10), entrar
  numa conta de um site (K12), um site na lista do shell (K21). **Envio
  explícito (nível 2 do K10) sempre pergunta**: não existe "pode mandar
  e-mail para a minha mãe sem perguntar" pelo navegador, porque o código
  não sabe, de forma geral, para quem um formulário vai.
- **Resposta por texto ou voz:** com **um** pedido pendente, uma mensagem
  que seja só um sim (`sim`, `s`, `pode`, `aprovo`, `ok`, `isso`) ou só um
  não (`não`, `nao`, `n`, `recuso`, `cancela`), sem mais nada, decide o
  pedido, e não vai ao modelo. Com **vários**, eles são numerados e a
  resposta precisa do número (`sim 2`); um "sim" sozinho faz o código
  listar os pendentes. Qualquer outra mensagem segue para a agente
  normalmente, e o pedido continua pendente.
- **"Sempre":** o botão (ou a resposta `sim sempre`) só aparece quando o
  pedido admite permissão permanente.
- **Lembrete:** um só, **3 h** depois do pedido, se ainda pendente.
- **Senha só por texto.** Uma nota de voz é transcrita por um provedor
  externo (PRD-A); por isso `/senha` recusa áudio e explica. Quem dita pode
  usar o ditado do próprio celular, que vira texto.
- **Sondas não pedem aprovação.** São de leitura por desenho (PRD-S): um
  pedido barrado numa sonda volta como "a sonda não envia nada", e a sonda
  segue.
- **Gasto:** o teto de US$ 0,50 vale para o teto declarado da tarefa ou
  sonda (hoje US$ 0,20 por padrão): pedir um teto maior pede aprovação
  antes de começar.
- **A Supernova sai da rede dos computadores** (revisão de segurança de
  26/11, aprovada pelo mantenedor). Hoje ela está na rede do computador
  para chamá-lo, e por isso o computador consegue abrir conexões com ela.
  Na PRD-K, a rede dos computadores tem só o proxy de saída e o
  despachante; a Supernova fala com cada computador **através do
  despachante**, que está nas duas redes e só aceita chamadas do lado da
  Supernova. Nenhum computador abre conexão com nada interno (K-I4).
- **Vagas:** sem vaga e sem computador parado há mais de 15 min, a tarefa
  espera na fila de vagas que já existe (`tool_slots`); o mais parado é
  desligado só se estiver parado.

## 4. Desenho

### 4.1 Peças

```
pessoa ── canal ── Supernova ──HTTP+token──▶ despachante ──socket──▶ Docker
                      │                                         │
                      │ HTTP+token (rede interna)               ▼
                      └──────────────────────────────▶ computador da pessoa (runsc, 1,5 GB)
                                                          │  serviço (usuário svc)
                                                          │  shell   (usuário sh)
                                                          ▼
                                                   proxy de saída ──▶ internet
                                                          ▲
                                     cloudflared ── /tela/<token> (noVNC)
```

- **Despachante** (`despachante/`, imagem própria): API mínima com token:
  `ligar(pessoa)`, `desligar(pessoa)`, `apagar(pessoa)`, `estado()`. Os
  parâmetros (imagem por digest, `runtime: runsc`, 1,5 GB, rede, volume
  `computador-<hash>`, usuário, sem capacidades) são **fixos no código**
  dele; a API não aceita outros. Recusa qualquer nome que não seja um hash
  de pessoa.
- **Computador da pessoa**: a imagem atual do `computador/`, com:
  - dois usuários: `svc` (o serviço, o navegador, o Playwright MCP) e `sh`
    (o que o `exec` roda). `sh` não lê os arquivos de `svc`;
  - a pasta da pessoa montada **só leitura para `sh`**, e `rascunho/`
    gravável;
  - Xvfb e noVNC para a tela, ligados só durante uma tomada de tela.
- **Proxy de saída** (`saida/`): única rota dos computadores para fora. O
  navegador usa uma credencial do proxy que só `svc` lê: passa tudo que o
  serviço deixou passar. Sem credencial (o shell): só `CONNECT`/`GET` para a
  lista de fábrica e a lista da pessoa.
- **Portão do navegador**, no serviço do computador: intercepta todo pedido
  do navegador (Playwright `route`), consulta as autorizações que a
  Supernova mandou junto com a chamada, e deixa passar, ou recusa com o
  motivo estruturado (tipo, site, método, URL, resumo dos campos).
- **Aprovações**, no núcleo da Supernova (`self/aprovacoes`): pedidos,
  autorizações e permissões permanentes por pessoa, estado do kernel em
  `agents/<pessoa>/self/`.
- **Cofre** (`self/cofre`): senhas cifradas (AES-256-GCM, chave
  `SUPERNOVA_COFRE_KEY` no `.env`) em `agents/<pessoa>/self/cofre.json`.
- **cloudflared**: publica só `/tela/*`, encaminhado ao despachante, que
  confere o token de uso único e liga a pessoa à tela do computador dela.

### 4.2 Ciclo de um pedido

1. A agente chama uma ação; o portão (navegador, proxy, arquivos, gasto)
   não acha autorização e recusa com o motivo estruturado.
2. A Supernova cria o pedido `#N` (pendente, 24 h) e manda no privado da
   pessoa: **primeira frase do código** ("Enviar o formulário de
   agendamento em consultas.saude.gov.br."), depois a explicação da
   agente, depois botões **Aprovar**, **Recusar** e, se couber, **Sempre
   neste site**. O texto termina dizendo como responder por texto ou voz.
3. A ferramenta devolve à agente: "Pedi aprovação (#N). Espere a resposta;
   ela chega como mensagem."
4. A pessoa responde (botão, texto, voz). O código decide, registra e
   injeta à agente "[Aprovação #N] aprovada" (ou recusada, expirada).
5. Aprovada: autorização de uso único (ou da tarefa, ou permanente). A
   agente refaz a ação; o portão encontra a autorização e consome a de uso
   único.

### 4.3 Esquecimento

O `/esquecer` cancela os pedidos pendentes, apaga autorizações e
permissões, o cofre, desliga e apaga o computador e o volume da pessoa
(sessões incluídas). Nada da pessoa sobra em lugar nenhum.

## 5. Fora de escopo

- Ferramentas de alto nível por serviço (e-mail, banco): tudo passa pelo
  navegador e pelo portão.
- Resolver captcha (K15).
- Ajudante cadastrado com poderes próprios (K3, K16).
- Mais de um host; computadores em outra máquina.
- O wizard (PRD-W).

## 6. Quality gates

Os da [PRD-F](PRD-F-ferramentas-atores.md#4-quality-gates) e da
[PRD-S](PRD-S-sondas.md#6-quality-gates). Mais:

- **Docker falso** nos testes do despachante (sem socket real); o
  despachante tem testes próprios na imagem.
- **Testes de rede do computador** rodam na imagem, sob gVisor, como os da
  PRD-S: o shell não sai para fora da lista; o navegador não envia sem
  autorização; `sh` não lê os arquivos de `svc`.
- **Leitor de tela:** cada pedido de aprovação tem um teste de texto: a
  primeira frase tem no máximo 140 caracteres e não começa com emoji nem
  símbolo.

## 7. Invariantes

- **K-I1 – Nada sai sem autorização.** Nenhum pedido que muda estado sai do
  navegador, e nada sai do shell para fora da lista, sem autorização
  válida. Testes no computador, com servidor local fazendo papel de site.
- **K-I2 – Só a pessoa decide.** Uma resposta de outra pessoa (outro
  usuário, outro chat, um grupo) nunca decide um pedido. Uma resposta do
  modelo também não: só mensagens e interações de entrada da pessoa.
- **K-I3 – A senha não chega ao modelo.** Nenhum prompt, histórico,
  transcript ou log contém uma senha do cofre. Teste: semear uma senha
  marcada e varrer prompts e arquivos depois do login.
- **K-I4 – Computadores não se veem.** Nenhum computador alcança outro,
  nem o volume de outro. Teste no despachante e na rede.
- **K-I5 – O primeiro texto é do código.** A primeira frase de todo pedido
  é gerada do pedido real (método, site, destino, arquivo, valor), nunca
  do texto do modelo.
- **K-I6 – A Supernova não tem o socket.** O compose não monta
  `docker.sock` no container da Supernova; um teste lê o compose.
- **K-I8 – Encerrar é um resultado.** Quando a agente encerra, recusa ou
  diz que não faz sentido continuar uma tarefa ou sonda, isso volta como
  resultado. Nenhum laço da Supernova insiste ("continue") nem reabre o
  trabalho por conta própria; o próximo passo é da pessoa. (Origem: o
  experimento da rádio da Andon Labs, em que um "continue" automático
  respondia a cada tentativa de encerrar.)
- **K-I9 – Efeito externo se conta pelo registro.** O que a pessoa ouve
  sobre um efeito fora da máquina (enviado, pago, agendado) vem do registro
  do portão, não do relato do modelo. Se a agente diz que enviou e o portão
  não registrou envio, a pessoa ouve que não houve envio. (Origem: no mesmo
  experimento, um modelo anunciou patrocínios que não existiam.)
- **K-I7 – Nada sobra.** Depois do `/esquecer`, não há volume, container,
  autorização, pedido, cofre nem sessão da pessoa.

## 8. Histórias

#### K-00: Linha de base

Conferir a seção 2 no master do dia; medir sob gVisor quanto um computador
leva para ligar (frio e com volume existente) e quanto ocupa parado.

**Aceite:**
- [ ] `docs/relatorios/PRD-K-base.md` com a conferência e as medidas.
- [ ] Commit: `docs: PRD-K, linha de base`.

#### K-01: Aprovações no núcleo

`self/aprovacoes`: pedidos (pendente, aprovado, recusado, expirado,
cancelado), autorizações (uso único, da tarefa, permanente) e permissões
permanentes por pessoa; 24 h; um lembrete às 3 h; persistência em
`agents/<pessoa>/self/aprovacoes.json`; métricas.

**Aceite:**
- [ ] Testes do ciclo inteiro com relógio de teste (expira, lembra, consome
      uso único, tarefa acaba e leva as autorizações dela).
- [ ] Sobrevive a reinício.
- [ ] Commit: `feat(aprovacao): pedidos e autorizações no núcleo`.

#### K-02: O pedido no canal

Texto (código + agente), botões onde há, entrega no privado, reconhecimento
de botão, texto e voz pelo código (seção 3.3), numeração com vários
pendentes, injeção do resultado à agente. Comando `/permissoes` (listar e
revogar); a agente pode **revogar** a pedido da pessoa, nunca conceder.

**Aceite:**
- [ ] Testes por canal com botões (Telegram, Discord, Slack) e sem
      (WhatsApp, sim): botão, "sim", "sim 2", nota de voz transcrita "sim".
- [ ] K-I2 e K-I5 testados.
- [ ] Pedido nascido em grupo vai ao privado; o grupo só lê o aviso.
- [ ] Commit: `feat(aprovacao): pedido acessível no canal`.

#### K-03: O despachante

Serviço e imagem `despachante/`, API com token, parâmetros fixos, Docker
falso nos testes; compose com o despachante e sem socket na Supernova.

**Aceite:**
- [ ] API recusa nome que não é hash de pessoa e qualquer parâmetro extra.
- [ ] K-I6 testado.
- [ ] A Supernova não está na rede dos computadores; as chamadas a um
      computador passam pelo despachante (seção 3.3). Teste de rede: um
      computador não alcança a Supernova.
- [ ] Commit: `feat(despachante): liga, desliga e apaga computadores`.

#### K-04: Um computador por pessoa

`computador.gleam` e as sondas passam a usar o computador da pessoa, pedido
ao despachante: liga na primeira ação, desliga após 15 min parado, até 4
ligados (K18, K19, seção 3.3). Migração: as pastas atuais em
`/home/pwuser/pessoas/<hash>` vão para o volume de cada pessoa.

**Aceite:**
- [ ] Duas pessoas, dois computadores, K-I4 testado.
- [ ] Quinto pedido espera vaga; computador parado é desligado e religa
      com os arquivos.
- [ ] Commit: `feat(computador): um computador por pessoa`.

#### K-05: Proxy de saída e o shell

Proxy `saida/`, rede interna sem rota direta, credencial só de `svc`, lista
de fábrica e lista da pessoa (pedido de site novo vira aprovação, K21).

**Aceite:**
- [ ] No computador: `curl` do shell a um site fora da lista falha; pip e
      npm funcionam; site aprovado passa a funcionar só para aquela pessoa.
- [ ] `sh` não lê a credencial do proxy.
- [ ] Commit: `feat(computador): saída do shell pela lista`.

#### K-06: Portão do navegador

Interceptação no serviço (K10): leitura livre; pedido que muda estado num
site sem autorização pede "usar o site nesta tarefa"; envio de formulário
(navegação POST) e clique em botão de envio (`type=submit`, ou nome
acessível de envio) sempre pedem, com o resumo dos campos (senhas
mascaradas). Sai o `evaluate` (K11). As sessões MCP das sondas passam pelo
mesmo portão e nunca pedem (seção 3.3).

**Aceite:**
- [ ] Testes no computador com um site local: busca por POST de fundo com
      site autorizado passa; formulário sempre pede; autorização de uso
      único é consumida; sonda barrada não cria pedido.
- [ ] K-I1 (navegador).
- [ ] Commit: `feat(computador): portão do navegador`.

#### K-07: Arquivos da pessoa

Pasta da pessoa só leitura para `sh`, `rascunho/` gravável; ferramenta de
arquivos: criar passa, sobrescrever e apagar pedem (K22).

**Aceite:**
- [ ] No computador: `rm` pelo shell na pasta da pessoa falha; pela
      ferramenta pede aprovação; arquivo novo passa direto.
- [ ] Commit: `feat(computador): arquivos da pessoa sob aprovação`.

#### K-08: Cofre de senhas e sessões

Comando `/senha <site>` interceptado pelo código antes do modelo (só texto;
áudio recusado com explicação), cifrado no cofre; a mensagem com a senha é
apagada do chat quando o canal permite (Telegram, no privado); senão, a
agente pede que a pessoa apague. Ação `entrar` (site): pede aprovação
("entrar em contas") salvo permissão permanente; o computador recebe a
senha só nessa chamada e preenche os campos sem devolver nada ao modelo.
Sessões no perfil do navegador no volume; "sair do site X" limpa os
cookies daquele site. `/senha` sem argumentos lista os sites (nunca as
senhas) e permite apagar.

**Aceite:**
- [ ] K-I3 testado com senha marcada.
- [ ] Login num site local, sessão sobrevive a desligar e religar.
- [ ] Commit: `feat(cofre): senhas fora do modelo`.

#### K-09: A tela (noVNC) e o túnel

Tomada de tela: o serviço fecha o navegador sem tela e abre o mesmo perfil
com tela, no Xvfb, com noVNC; link de uso único de 15 min para a própria
pessoa (K16), pelo `cloudflared` (K17); ao fim, volta ao sem tela. Captcha
detectado ou relatado pela agente leva a esse caminho (K15).

**Aceite:**
- [ ] Link expira, não abre duas vezes, só abre a tela daquela pessoa.
- [ ] O túnel publica só `/tela/*` (teste do roteamento).
- [ ] Commit: `feat(computador): tela assumível por link`.

#### K-10: Gasto

Teto declarado acima de US$ 0,50 numa `tarefa` ou `sonda` pede aprovação
antes de começar (K8, seção 3.3).

**Aceite:**
- [ ] Testes com o mock do LLM.
- [ ] Commit: `feat(aprovacao): teto de gasto por tarefa`.

#### K-11: Para todos os membros

`computador` e sonda código liberados para membros (K23); descrições das
ferramentas reescritas (a máquina agora é de fato da pessoa; o que pede
aprovação; o que fazer num captcha).

**Aceite:**
- [ ] Config padrão e `config_check` atualizados.
- [ ] Commit: `feat(computador): para todos os membros`.

#### K-12: Esquecimento, telemetria, harness e docs

K-I7, K-I8 e K-I9; métricas (pedidos por tipo e desfecho, tempo até a resposta,
computadores ligados, vagas); painel; cenário de harness com aprovação
(sim e não, com `wait_tasks`); `docs/operations/COMPUTADOR.md`,
`INTERACTION.md` e um guia curto em português para a pessoa ("como
aprovar"), escrito para leitor de tela.

**Aceite:**
- [ ] K-I7, K-I8 e K-I9 testados.
- [ ] Commit: `feat(computador): esquecimento, telemetria e docs`.

#### K-13: Piloto manual

Com o mantenedor e uma pessoa do piloto: marcar algo num site real com
aprovação por voz; entrar no gov.br pelo cofre; organizar arquivos; um
captcha pelo link da tela.

**Aceite:**
- [ ] Relatório com o que funcionou, o que confundiu e o tempo de cada
      aprovação.

## 9. Riscos

- **Fadiga de aprovação.** Pedidos demais levam a aprovar sem ouvir. A
  métrica de tempo até a resposta e o piloto dizem se o nível 1 do K10 está
  pedindo demais.
- **Detecção de "botão de envio".** É heurística (tipo do elemento e nome
  acessível); um site estranho pode escapar do nível 2, mas não do nível 1,
  que pega qualquer pedido que muda estado.
- **Sessões salvas** são poder: quem controla a agente controla as contas
  abertas. Mitigação: portão de envio sempre ativo, `/esquecer`, "sair do
  site".
- **Túnel do Cloudflare** é um terceiro no caminho da tela. Só `/tela/*`
  passa, com token de uso único.
- **Memória do host:** 4 × 1,5 GB mais a Supernova. Medido na K-00.
- **Escapar do gVisor** derruba K5. É o mesmo risco de hoje, agora com mais
  pessoas na máquina.
