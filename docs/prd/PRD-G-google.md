[PRD]
# PRD G: a conta Google de cada pessoa, conectada sem senha e sem sair do computador dela

> **Situação em 27/11/2026:** rascunho para o mantenedor. Nasceu da
> homologação do sistema completo: a Belle pediu para a agente ler um Google
> Doc dela e entrar na conta dela, e não havia caminho bom para isso.
> As decisões da seção 4 estão em aberto e voltam ao mantenedor antes de
> qualquer história.
>
> **Depende de:** PRD-K (computador por pessoa, cofre, aprovação, túnel da
> tela) e PRD-S (servidores MCP das sondas no computador), todos no master.

> **Executor:** agente autônomo, depois que a seção 4 estiver decidida.
> Execute as histórias **na ordem**, com os quality gates verdes e um commit
> por história. **Não improvise decisões:** o que não estiver decidido aqui
> volta ao mantenedor.

## 1. Visão

A Belle quer que a agente leia um resumo no Google Docs, ache um arquivo no
Drive, veja a agenda da semana. Para uma pessoa cega ou tetraplégica, isso
não é luxo: o Drive e a Agenda são onde a vida dela já está.

Duas promessas, garantidas pelo código:

1. **A pessoa conecta a conta dela, com um toque, sem dar a senha a
   ninguém.** O Google pergunta a ela o que permitir; a agente recebe só
   isso, só para ela, e a pessoa desconecta quando quiser.
2. **O acesso mora no computador dela, não na Supernova.** O token fica no
   cofre da pessoa e só desce ao computador dela, isolado em gVisor. O
   container da Supernova, que guarda os segredos de todos, não fala com o
   Google em nome de ninguém.

E o princípio de acessibilidade da PRD-K continua: tudo se faz por voz, a
mensagem começa pelo essencial, e o link de autorização abre num toque.

## 2. Contexto (conferido em 27/11/2026 no master `b3aab17`)

- **MCP da Supernova é por instância.** `adapters/mcp/config_loader.gleam`
  lê `mcp_servers` do `supernova.yaml`: o mesmo servidor e o mesmo `env`
  para todo mundo. Não há conta por pessoa. E esses servidores rodariam no
  container da Supernova, o mesmo erro do tool `browser` aposentado (Qwen 4,
  A1). **Bug à parte:** `supernova.gleam` lê `"supernova.yaml"` relativo ao
  diretório atual; no Docker (`/app`) não acha nada e loga "No MCP servers
  configured". Corrigir em PR própria, independente desta PRD.
- **O computador já roda servidores MCP por pessoa.** `computador/mcp.mjs`
  serve as sondas (PRD-S): `playwright` e `filesystem`, de uma lista fixa,
  um por sessão, presos à pasta da pessoa. É o lugar natural de um servidor
  do Google.
- **Cofre por pessoa.** `self/cofre.gleam` sela com AES-256-GCM
  (`SUPERNOVA_COFRE_KEY`) as senhas de `/senha`, por site; `credencial`
  entrega uma ao computador na hora do `entrar`, e o modelo nunca a vê.
- **Túnel público.** `cloudflared` publica só `/tela/<token>/` do
  despachante (K-09). Um retorno de OAuth precisaria de outra rota pública,
  ou de um fluxo sem retorno (seção 4, D1).
- **Hoje, o que funciona:** o computador entra no Google pelo navegador com
  `/senha` e `entrar`, com o portão pedindo o sim da pessoa. Funciona, mas
  com a senha inteira, sujeito a captcha e 2FA, e com acesso a tudo da conta.

## 3. O que a pessoa vive

1. A Belle diz: "conecta o meu Google". A agente responde, curto: "Vou te
   mandar um link do Google. Ele vai perguntar se você permite que eu leia o
   seu Drive e veja a sua agenda. Toque no link quando quiser."
2. Ela toca, entra na conta dela no próprio celular (onde já está logada),
   e o Google mostra o que está sendo pedido. Ela permite.
3. A agente confirma: "Conectado: leio o seu Drive e vejo a sua agenda.
   Para desconectar, diga /desconectar google."
4. Depois: "lê o resumo de Motores para Jogos que está no meu Drive" e "o
   que eu tenho na quinta?" funcionam sem pedir nada de novo (leitura).
5. Criar ou mudar um evento, escrever num documento, compartilhar um
   arquivo: passa pelo portão da PRD-K. A agente resume e pede o sim, toda
   vez.

## 4. Decisões em aberto (voltam ao mantenedor)

- **D1. Como o token chega.**
  - (a) **Fluxo de dispositivo** (OAuth 2.0 para dispositivos com entrada
    limitada): a Supernova mostra um código e um link; não precisa de rota
    pública. **Verificar** quais escopos o Google aceita nesse fluxo: a
    lista é restrita e pode não incluir Drive leitura nem Agenda.
  - (b) **Retorno web** por uma rota nova do túnel, `/oauth/google/<estado>`,
    servida pelo despachante como a tela: um toque, sem código para digitar.
  - Recomendação: (b) se (a) não cobrir os escopos; (a) é mais simples
    se cobrir.
- **D2. Escopos.** Mínimo proposto: `drive.readonly` e
  `calendar.events`. Escrever no Drive (`drive.file`) fica para depois?
  Gmail fica fora desta PRD?
- **D3. Verificação do app no Google.** `drive.readonly` é escopo
  **restrito**. Em modo "Testing", o app aceita até 100 usuários de teste
  listados à mão, e o refresh token **expira em 7 dias**, o que obriga a
  pessoa a reconectar toda semana. Publicar exige a verificação do Google
  (e, para escopo restrito, uma avaliação de segurança paga). Qual o plano
  para o piloto: Testing com reconexão semanal, ou verificar o app antes?
- **D4. Qual servidor MCP.** Um servidor próprio, mínimo (listar, ler,
  buscar no Drive; listar e criar eventos), escrito no `computador/` como
  os outros, ou um pacote pronto, fixado por versão e auditado como o
  `server-filesystem` (PRD-S)? Recomendação: próprio, porque o contrato é
  pequeno e o pacote pronto traz superfície que não usamos.
- **D5. Quem guarda o client secret.** O OAuth client (id e secret) é da
  instância; o refresh token é da pessoa. Proposta: client no `.env` da
  Supernova, refresh token no cofre da pessoa, access token só no
  computador dela, em memória.

## 5. Histórias (rascunho; finalizar depois da seção 4)

- **G-01. Conectar.** `/conectar google` e a frase equivalente; o link
  (D1); o retorno guarda o refresh token no cofre da pessoa (D5); a
  mensagem de confirmação diz o que foi permitido. `/desconectar google`
  revoga no Google e apaga do cofre. `/esquecer` também.
- **G-02. O servidor no computador.** O servidor do Google (D4) entra na
  lista fixa de `computador/mcp.mjs`; a Supernova entrega o access token na
  abertura da sessão, como a credencial do `entrar`; o token vive só em
  memória e só para aquela pessoa. A saída (`saida/`) libera
  `www.googleapis.com` e `oauth2.googleapis.com` só para esse servidor.
- **G-03. Ler.** Ferramentas de leitura para a agente: buscar no Drive, ler
  um Doc como texto (exportação `text/plain`), listar eventos de um
  intervalo. Sem aprovação.
- **G-04. Escrever, com o portão.** Criar e mudar eventos (e o que D2
  liberar) passam pelo portão da PRD-K: resumo curto, sim da pessoa, toda
  vez.
- **G-05. Quando o token cai.** Expirou ou foi revogado: a agente diz, em
  uma frase, e oferece reconectar. Nunca cai em silêncio para o `/senha`.

## 6. Invariantes (cada uma com teste)

- **G-I1.** Nenhum token do Google, de ninguém, aparece no container da
  Supernova fora do cofre selado, nem em log, prompt ou histórico.
- **G-I2.** O token de uma pessoa nunca chega ao computador de outra.
- **G-I3.** Toda escrita na conta da pessoa passa pelo portão.
- **G-I4.** `/desconectar google` e `/esquecer` revogam no Google, não só
  apagam localmente.

## 7. Fora do escopo

Gmail; contas Microsoft e Apple; compartilhar arquivos com terceiros; a
correção do caminho do `mcp_servers` (PR própria).
