# Teste de estresse

O harness ensaia comportamento: poucas personas, um modelo de verdade e um juiz. O
teste de estresse mede a plataforma. Muitas agentes com históricos longos recebem
mensagens em paralelo, com caos no meio. O LLM é o mock, então o que se mede são
os canais, as filas por chat, as sessões, o gate, o disco e a busca, não o
provedor. Não custa tokens.

## Como rodar

```sh
gleam run -m supernova/stress/run -- \
  --agents 200 --history 10000 --groups 10 \
  --workers 150 --seconds 120 --search-every 5
```

| Opção | Padrão | Efeito |
|---|---|---|
| `--agents` | `200` | agentes, todas já nascidas e nomeadas |
| `--history` | `5000` | mensagens semeadas no privado de cada agente (o grupo recebe um quinto) |
| `--groups` | `10` | grupos; cada agente participa de um |
| `--workers` | `100` | processos mandando mensagens em paralelo |
| `--seconds` | `120` | duração da carga |
| `--search-every` | `5` | uma em cada N mensagens pede `buscar_conversa` |
| `--no-chaos` | desligado | sem matar sessões nem reiniciar o runtime |
| `--out` | `stress-out` | diretório da execução |

O relatório fica em `<out>/<instante>/report.md`. O `data_dir` da execução fica ao
lado dele, com o marcador `.stress`, e pode passar de centenas de MB: apague depois
de ler o relatório.

## O que acontece

1. **Semeadura.** Cada agente nasce e ganha nome. Recebe também um histórico no
   privado e outro no grupo, espalhado pelo último ano. As agentes são semeadas
   em paralelo, um processo para cada uma.
2. **Boot.** A Supernova sobe inteira, com o canal sim, num processo
   hospedeiro, como em produção ela vive no seu processo do sistema operacional.
3. **Carga.** Os workers mandam mensagens até o prazo. Um quinto delas vai para
   os grupos, onde a fila do chat serializa os membros. Uma em cada N é uma
   busca. O POST do sim só responde quando o turno termina e traz o desfecho,
   então a latência medida é a do turno.
4. **Caos.** Quando passa um terço do prazo, 20 sessões são mortas no meio da
   carga. Na metade, o runtime é desligado de forma ordenada, o hospedeiro
   termina e um novo sobe numa porta nova.
5. **Amostragem.** A cada segundo, registra número de processos, memória,
   maior fila de mensagens de um processo e run queue. Também registra qual
   processo tem a maior fila e onde ele está parado: foi assim que os gargalos
   abaixo apareceram.
6. **Verificação.**
   - **Integridade.** Cada turno respondido deve estar no disco: semente +
     2 × turnos respondidos. Linhas a mais são turnos refeitos pela fila
     durável depois do restart.
   - **Busca.** "palavra7 semente" deve achar exatamente o que a semente pôs lá,
     nas 20 primeiras agentes.

A execução reprova se faltar um turno respondido ou se a busca errar. Sem caos,
reprova também se algum turno ficar sem resposta.

## Lendo os números

A máquina de desenvolvimento é compartilhada, e a carga de outros processos
mexe nos números. Para comparar duas versões, rode as duas intercaladas sobre
cópias congeladas do código (`git worktree add --detach`), duas rodadas de
cada, e compare médias, não uma rodada contra outra.

## O que ele já achou (23/11)

| Achado | Efeito | Correção |
|---|---|---|
| O supervisor de sessões não interceptava saídas | a morte de uma sessão derrubava o runtime inteiro | `trap_exit`; a sessão morta sai do registro e volta na próxima mensagem |
| O supervisor lia o histórico inteiro ao criar cada sessão | todo o canal esperava | a sessão lê sozinha, na primeira mensagem, só o fim do arquivo |
| O store do sim anexava com cópia e varria tudo a cada leitura | o próprio teste virava o gargalo | eventos por chat, mais novos primeiro, até 10.000 |
| O POST do sim sempre respondia 200 | turno que quebrou contava como respondido | o POST traz o desfecho |
