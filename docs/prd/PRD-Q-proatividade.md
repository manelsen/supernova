[PRD]
# PRD Q: a agente que puxa assunto

> **Situação em 27/11/2026:** rascunho com as decisões do mantenedor de
> 27/11 (seção 3). Os pontos marcados **[proposta]** são padrões sugeridos
> que ele ainda confirma; o resto é execução.
>
> **Depende de:** agenda e tarefas (PRD-F), sondas e `buscar` (PRD-S),
> canais com entrega no privado (PRD-C).

> **Executor:** agente autônomo, depois da confirmação das propostas.
> Execute as histórias **na ordem**, com os quality gates verdes e um commit
> por história. **Não improvise decisões.**

## 1. Visão

As pessoas do piloto são cegas ou tetraplégicas, e muitas vivem sozinhas a
maior parte do dia. Uma companheira que só fala quando é chamada espera
demais delas: lembrar de chamar, saber o que perguntar.

A agente passa a **puxar assunto**: algumas vezes por dia, ela pensa no que
a pessoa gosta e no que conversaram, pesquisa algo que valha a pena (uma
descoberta sobre o tema que a pessoa estava estudando, a notícia boa sobre o
time dela, uma curiosidade ligada ao bebê que está chegando) e manda uma
mensagem curta, que dá vontade de responder. E avisa do que importa: o
prazo que vence amanhã, a consulta, a tarefa que terminou.

Ser proativa não pode virar spam, invasão nem risco ao número. As regras do
código são o teto; o modelo decide dentro dele.

## 2. Contexto (conferido em 27/11/2026)

- **O proativo combinado já existe:** a agenda (`agenda`, PRD-F) manda uma
  mensagem na hora marcada, quando a pessoa pediu. A PRD-companheira cita
  "cron/heartbeat proativo" como fase futura; nada mais está escrito.
- **A pesquisa existe:** `buscar` (SearXNG ou Tavily) e as sondas web
  (PRD-S) leem a web isoladas no computador da pessoa.
- **O que a agente sabe da pessoa:** núcleo, biografia, diário, relação
  (`self/`), o histórico inteiro da conversa e, se ligado, o `lembrar`.
- **Homologação de 27/11:** perguntada se pode "mandar mensagem aleatória",
  a agente respondeu corretamente que não. Isto é o que muda.

## 3. Decisões (mantenedor, 27/11/2026)

- **D1. O que dispara: as duas coisas.**
  - **Eventos fixos:** um prazo vencendo, uma consulta amanhã, uma tarefa
    que terminou, um pedido de aprovação esquecido.
  - **Eventos fluidos:** nascem da conversa. A pessoa estava estudando
    motores de jogos; falou de uma infecção que está tratando; contou que
    ia ao médico na quinta. A agente pode voltar a isso depois.
  - **Heartbeat de puxar assunto:** algumas vezes por dia, a agente escolhe
    um tema da pessoa, pesquisa algo realmente interessante e puxa assunto.
- **D2. Ligada por padrão, desligável.** A pessoa desliga com uma frase
  ("para de me mandar mensagem sozinha") ou com `/proativa não`, e religa
  com `/proativa sim`.
- **D3. Quanto: [proposta] adaptativo, com teto.**
  - Até **3 mensagens proativas por dia** no começo, contando os eventos
    fluidos e o heartbeat. Os eventos fixos de prazo não contam no teto,
    mas também respeitam o silêncio.
  - **Nunca duas seguidas sem resposta.** Se a pessoa não respondeu à
    última proativa, a próxima espera até ela falar, salvo um evento
    fixo.
  - **Aprende com a resposta:** proativas respondidas com gosto sobem o
    teto (até 6); ignoradas ou recusadas baixam (até 1). A pessoa também
    regula: `/proativa mais`, `/proativa menos`.
  - **Silêncio:** das 22h às 8h no fuso da pessoa, configurável.
- **D4. Quem decide: o código e o modelo.** O código abre a janela: o teto,
  o silêncio, a última sem resposta, os eventos fixos. Dentro dela, um
  modelo barato responde "vale a pena falar agora? sobre o quê?" e pode
  dizer que não. O texto sai do modelo da agente, na voz dela.
- **D5. Assuntos sensíveis: configurável por pessoa.** Saúde, luto,
  dinheiro, relações. **[proposta]** Por padrão, a agente pode perguntar
  de leve como a pessoa está ("como você está se sentindo hoje?"), mas não
  volta ao detalhe sensível por conta própria. A pessoa libera
  (`/proativa assuntos livres`) ou fecha de vez
  (`/proativa assuntos só os meus`).

## 4. O que a pessoa vive

- 10h20: "Lembra que você estava estudando motores de jogos? Saiu hoje um
  vídeo curto mostrando como a Godot desenha a luz num jogo 2D, explicado
  para iniciantes. Quer que eu te conte o principal?"
- Quarta, 18h: "Amanhã às 14h é a sua consulta. Quer que eu te lembre às
  12h, com o endereço?"
- Ela não respondeu a primeira: a agente espera; não manda outra.
- "Para de puxar assunto de manhã": a agente ajusta o silêncio e confirma
  numa frase.

Toda mensagem proativa é curta, começa pelo essencial e termina numa
pergunta fácil de responder por voz.

## 5. Histórias (rascunho)

- **Q-01. O relógio.** Um heartbeat por pessoa, persistente (sobrevive ao
  reinício), que abre janelas segundo D3 e o silêncio, por fuso. Métricas:
  janelas abertas, mensagens mandadas, respondidas, ignoradas.
- **Q-02. As regras e os comandos.** Ligar e desligar (D2), mais e menos,
  silêncio, assuntos (D5), por frase e por `/proativa`. Guardado nas
  preferências da pessoa; `/esquecer` zera.
- **Q-03. Eventos fixos.** Prazos da agenda e de tarefas, aprovações
  pendentes há horas: entram como gatilhos, fora do teto, dentro do
  silêncio.
- **Q-04. Puxar assunto.** Na janela, o modelo barato escolhe se fala e
  sobre o quê, a partir do núcleo, da relação e das conversas recentes,
  respeitando D5. Se fala, a agente pesquisa (`buscar` ou uma sonda, com
  limite de custo) e escreve a mensagem.
- **Q-05. Aprender.** Resposta, demora e tom de cada proativa ajustam o
  teto (D3) e os temas que funcionam para aquela pessoa.

## 6. Invariantes (cada uma com teste)

- **Q-I1.** Nenhuma proativa no silêncio da pessoa, nem com a proativa
  desligada, nem acima do teto do dia.
- **Q-I2.** Nunca duas proativas seguidas sem resposta, salvo evento fixo.
- **Q-I3.** Uma proativa nunca abre pedido de aprovação nem age no
  computador; só conversa e pesquisa.
- **Q-I4.** Com assuntos fechados (D5), nenhuma proativa menciona o tema
  sensível; o teste usa conversas marcadas.
- **Q-I5.** Custo: as proativas de uma pessoa cabem num teto diário em
  US$ próprio, contado no ledger como os turnos.

## 7. Riscos

- **O número do WhatsApp.** O GOWA não é API oficial. Mensagens que a pessoa
  não responde, em volume, são o padrão que o WhatsApp pune. Por isso o
  teto baixo, o "nunca duas sem resposta" e o aprendizado para baixo.
- **Custo.** Cada heartbeat que decide falar pesquisa e escreve. O teto
  em US$ (Q-I5) e o modelo barato na decisão limitam isso.
- **Invasão.** A mesma frase pode ser carinho para uma pessoa e intromissão
  para outra (D5). Configurável por pessoa, com o padrão conservador.

## 8. Fora do escopo

Mensagens em grupos; proativas por voz (`/voz`) na primeira versão; agir
por conta própria (pagar, mandar e-mail) sem pedido.
