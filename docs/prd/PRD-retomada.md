[PRD]
# PRD: Retomada da Supernova — verde, segura e implantável

> **Situação em 22/11/2026:** Entregue na v0.3.0 (PR #10). Relatório: [RETOMADA_REPORT.md](../relatorios/RETOMADA_REPORT.md). Os itens sobre Postgres e pgvector perderam o objeto com a remoção do banco (PR #33).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar. Execute as histórias **na ordem**. Cada história termina com os quality gates verdes (ou com a exceção documentada na própria história) e um commit próprio.

## 1. Contexto

A Supernova é um runtime de agentes multiusuário em Gleam/BEAM, com kernel de políticas (workspace, orçamento, capabilities, ledger, auditoria) e 9 canais. O desenvolvimento ativo parou em 19/04/2026. Estado levantado em 17/11/2026:

- `master` compila com **15 warnings**; `gleam test` passa **1.665 de 1.667** testes. As 2 falhas estão em `test/tools/browser_test.gleam:70`: o JSON de resposta do browser chega sem o campo `title`.
- O workflow de testes foi **removido** em 27/03 (`chore: remove CI workflow`). O único workflow restante (`docker.yml`) dispara em `main`, mas o branch padrão é `master`, então **nunca roda**.
- O alvo `test:` do `Makefile` em `master` está vazio.
- O branch remoto `origin/us/coverage-85-min` tem **1 commit de 08/11/2026** que não foi mesclado: +7,7 mil linhas, quase todas de testes, mais um gate de cobertura de 85% (`scripts/coverage/line_coverage.escript`, `make coverage`). O mesmo commit **versionou por engano** artefatos de teste em `workspaces/agent:*`.
- Os testes gravam arquivos em `workspaces/` na raiz do repositório (hoje há um `workspaces/` não versionado com cerca de 324 KB).
- Dependências desatualizadas, incluindo duas mudanças de versão maior: `gleam_stdlib` 0.70.0 → 1.1.0 e `hackney` 1.25.0 → 4.12.1 (transitiva, via `gleam_hackney`). Toolchain local: Gleam 1.15.0, Erlang 28.4. Não existe `.tool-versions` nem `mise.toml`.
- `audit/RELATORIO_AUDITORIA.md` (31/03) cruzou a auditoria com o código e listou os requisitos REQ-SEC-01..04 e REQ-PROD-01..05. **Parte já foi corrigida depois disso**: por exemplo, `file_system.gleam` já usa `workspace_guard` e `web.gleam`/`browser.gleam` já usam `url_guard`. Pelo menos um item segue aberto: `scripts/browser_runner.mjs:105` executa `globalThis.eval(script)` sem restrição.
- Versões inconsistentes: `gleam.toml` diz `1.0.0`, existem as tags `0.1.0` e `30.03.2026` e há `RELEASE_NOTES_v0.2.0.md`. O `STATUS.md` (26/03) diz "15%" e está defasado.

**Objetivo desta PRD:** trazer a Supernova ao presente **sem acrescentar funcionalidades**. Ao final, o projeto deve compilar sem warnings, passar todos os testes, ter CI verificando cobertura, não ter achados de auditoria abertos sem decisão e gerar uma imagem Docker que sobe.

## 2. Fora de escopo

- O `PRD.md` existente (Agente Companheiro), identidade, self, humor e relacionamento. **Não altere** esse arquivo.
- Canais, providers ou ferramentas novos.
- Refatorações que não sejam exigidas por uma história.
- Criar tags de release ou publicar imagens. Tags `v*` disparam o push para o GHCR; isso fica com o mantenedor.
- Merge do PR final: o executor abre o PR, mas não faz o merge.

## 3. Quality gates

Obrigatórios ao fim de **toda** história, a partir da US-001:

```bash
gleam format --check src test
gleam build
gleam test
git status --short    # não pode mostrar arquivos novos gerados pelos testes (a partir da US-002)
```

A partir da US-009 (zero warnings), também:

```bash
gleam build --warnings-as-errors
```

A partir da US-001, também:

```bash
make coverage         # threshold definido na US-001
```

Regras adicionais:

- Nenhum teste novo pode usar rede real, tokens reais, Postgres real ou Chromium real. A exceção são os testes de browser com opt-in da US-008.
- Toda correção de comportamento segue TDD: teste que falha → correção → teste passa. Registre a falha inicial na mensagem de commit.
- Funções de lógica nova devem ser puras (módulos `pure.gleam` ou equivalentes), seguindo o padrão `types/pure/actor` já usado em `src/supernova/core/`.

## 4. Preparação

1. `cd ~/git/supernova && git status --short`. A única saída aceitável é `?? workspaces/`. Qualquer outra alteração: **pare** e registre no relatório.
2. `git fetch origin && git switch master && git pull --ff-only`
3. `git switch -c chore/retomada`
4. Registre no relatório a linha de base: `gleam --version`, `erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]), halt().'`, a contagem de warnings de `gleam build` e o resultado de `gleam test`.

## 5. Histórias de usuário

### US-001: Integrar o trabalho de cobertura de 08/11

**Critérios de aceite:**
- [ ] `git merge --no-ff origin/us/coverage-85-min -m "merge: coverage work from 2026-11-08"`. Em caso de conflito, prevalece o lado do branch para arquivos de `test/` e `scripts/coverage/`, e o lado do `master` para `src/`. Registre cada conflito no relatório.
- [ ] Remova do índice os artefatos versionados por engano: `git rm -r --cached workspaces/`.
- [ ] Adicione `workspaces/` ao `.gitignore`.
- [ ] O `Makefile` resultante tem `test:` executando `gleam test` e `coverage:` executando o escript.
- [ ] Rode `gleam test` e `make coverage` e registre os testes que passaram e falharam e a porcentagem de cobertura.
- [ ] **Threshold:** se a cobertura medida for ≥ 85%, mantenha 85. Se for menor, ajuste `--threshold` no `Makefile` para o valor medido arredondado para baixo e registre o motivo. O threshold **nunca** pode ser reduzido depois desta história.
- [ ] Testes que falharem após o merge **não** são corrigidos aqui: liste-os no relatório. Exceção: se a falha impedir a compilação, corrija o mínimo necessário para compilar.
- [ ] Commit: `chore: integrate coverage work and untrack test artifacts`.

### US-002: Testes não sujam o repositório

**Critérios de aceite:**
- [ ] Encontre a origem dos diretórios `workspaces/agent:*`: `rg -n '"workspaces' src test` e o default de workspace em `src/supernova/config.gleam`.
- [ ] Os testes passam a usar um diretório temporário exclusivo por execução (por exemplo, `/tmp/supernova-test-<unique>`, via FFI já existente ou um helper novo em `test/`). O default de produção **não muda**.
- [ ] Depois de `rm -rf workspaces/`, rodar `gleam test` não recria `workspaces/` nem cria nenhum outro arquivo: `git status --short` vazio.
- [ ] Antes de remover o `workspaces/` local, verifique que todos os subdiretórios seguem o padrão `agent:*` e contêm apenas `.supernova/*.json` e `.supernova/USER.md`. Se houver qualquer outra coisa, **não remova**: registre e siga.
- [ ] Commit: `test: isolate test workspaces in temp dirs`.

### US-003: Reconciliar a auditoria com o código atual

**Critérios de aceite:**
- [ ] Crie `audit/STATUS_2026-11.md` com uma tabela de **todos** os achados das seções 2 e 3 de `audit/RELATORIO_AUDITORIA.md` e de todos os requisitos REQ-SEC-01..04 e REQ-PROD-01..05 da seção 7:
  `| ID | Achado | Severidade (relatório) | Status | Evidência |`
- [ ] `Status`: `RESOLVIDO`, `ABERTO`, `PARCIAL` ou `ACEITO` (risco aceito, com justificativa).
- [ ] `Evidência` é obrigatória: `arquivo:linha` do código atual que comprova o status. Para RESOLVIDO, cite também o teste que cobre o caso, se existir; se não existir, o status é `PARCIAL`.
- [ ] Ponto de partida verificado em 17/11 (confirme cada um):
  - REQ-SEC-01: `src/supernova/tools/file_system.gleam:114` delega a `workspace_guard.validate_path`.
  - REQ-SEC-02: `src/supernova/tools/web.gleam:15` e `browser.gleam:58` usam `url_guard`.
  - Browser eval (2.4): `scripts/browser_runner.mjs:105` ainda chama `globalThis.eval`, então está **ABERTO**.
- [ ] Commit: `docs(audit): reconcile findings with current code`.

### US-004: Fechar o eval irrestrito do browser

**Critérios de aceite:**
- [ ] A ação `evaluate` do browser fica **desabilitada por padrão**. Habilitação só por configuração explícita (`tools.browser.allow_evaluate: true` no YAML, com env `SUPERNOVA_BROWSER_ALLOW_EVALUATE`), seguindo o padrão de `src/supernova/config.gleam`.
- [ ] Com o recurso desabilitado, a ferramenta retorna um erro claro ao LLM (`"browser evaluate is disabled by configuration"`) **antes** de chegar ao runner. A checagem fica em Gleam, não no `.mjs`.
- [ ] Com o recurso habilitado, o comportamento atual é preservado.
- [ ] Testes cobrem: desabilitado por padrão; erro sem chamada à FFI; habilitado via config; habilitado via env.
- [ ] `supernova.yaml.example` documenta a opção, comentada e com aviso de risco.
- [ ] Atualize a linha do achado em `audit/STATUS_2026-11.md` para `RESOLVIDO`, com evidência.
- [ ] Commit: `fix(browser): disable arbitrary evaluate by default`.

### US-005: Fechar os demais achados abertos

Para **cada** linha `ABERTO` ou `PARCIAL` de `audit/STATUS_2026-11.md` (exceto a já tratada na US-004), uma correção com um commit próprio:

**Critérios de aceite (por achado):**
- [ ] Teste que reproduz o problema e falha antes da correção.
- [ ] Correção seguindo a solução descrita em `audit/RELATORIO_AUDITORIA.md` §7 ou `audit/production.md`, quando houver.
- [ ] Linha atualizada para `RESOLVIDO`, com evidência e teste.
- [ ] Commit: `fix(<área>): <ID> <descrição curta>`.

Exceções:
- Achados que exijam Postgres real, rede ou mudança de arquitetura (por exemplo, uma árvore de supervisão completa, se a REQ-PROD-03 ainda estiver aberta e o escopo passar de cerca de 300 linhas) **não** são implementados: marque `ACEITO` com o texto "adiado para PRD B" e uma justificativa de uma linha.
- REQ-SEC-03 (`delete_by_metadata`): se a função continuar sem uso em `src/`, a correção preferida é **removê-la**, junto com seus testes.

### US-006: Fixar a toolchain

**Critérios de aceite:**
- [ ] Rode `mise ls-remote gleam` e `mise ls-remote erlang` (rede permitida para essa consulta) e escolha a **última versão estável** do Gleam 1.x e a última do Erlang/OTP 28.x.
- [ ] Crie `.tool-versions` com as duas versões.
- [ ] Alinhe o `Dockerfile`: `GLEAM_VERSION` e a imagem base `erlang:28-alpine` com a versão fixada (`erlang:<versão>-alpine`, se a tag existir).
- [ ] Rode `mise install` e todos os quality gates com a toolchain nova. Se ela quebrar a build e a correção passar de cerca de 50 linhas, volte para 1.15.0, registre o motivo e siga.
- [ ] Commit: `build: pin gleam and erlang toolchain`.

### US-007: Atualizar dependências

Faça em **três etapas**, com um commit por etapa e todos os quality gates verdes entre elas. Rede permitida para o Hex.

**Etapa A — atualizações menores.** Atualize todos os pacotes **exceto** `gleam_stdlib`, `gleam_hackney` e `hackney`. Use `gleam deps update <pacote>`, um por vez ou em grupo. Se a CLI não aceitar pacotes individuais, registre e passe direto para a etapa B com `gleam deps update` completo.
- [ ] Commit: `deps: minor updates`.

**Etapa B — `gleam_stdlib` 1.x.**
- [ ] Atualize `gleam_stdlib` para a 1.x (a restrição em `gleam.toml` já permite).
- [ ] Corrija todos os erros de compilação e substitua funções removidas ou obsoletas, consultando o changelog da stdlib.
- [ ] Nenhum teste é removido nem tem a asserção enfraquecida para passar. Se precisar alterar uma asserção, justifique na mensagem de commit.
- [ ] Commit: `deps: migrate to gleam_stdlib 1.x`.

**Etapa C — HTTP (`gleam_hackney` e `hackney`).**
- [ ] Atualize `gleam_hackney` para a última versão aceita por `gleam.toml`. Se o `hackney` transitivo for para 2.x ou mais, revise **todas** as chamadas diretas em `src/supernova_hackney_ffi.erl`, `src/supernova_http.erl` e `src/supernova_llm_stream_ffi.erl` contra a API da versão resolvida.
- [ ] Os testes de streaming de LLM e de HTTP (com mock) continuam passando.
- [ ] Se a migração para `hackney` ≥ 2 exigir reescrever a FFI de streaming (mais de cerca de 150 linhas), fixe `hackney` na última 1.x compatível, registre e siga.
- [ ] Commit: `deps: update http stack`.

### US-008: Testes de browser estáveis

**Critérios de aceite:**
- [ ] Determine a causa da falha `DecodeError("Field", "Nothing", ["title"])` em `test/tools/browser_test.gleam:70`: se é ambiente (Chromium ausente ou caminho fixo) ou código (o runner não devolve `title`). Registre a causa no commit.
- [ ] Se for **código**: corrija o runner ou o decoder com TDD.
- [ ] Testes que precisam de Chromium real rodam só com `SUPERNOVA_BROWSER_TESTS=1`. Sem a variável, retornam cedo e passam, emitindo uma linha de log `skipped: set SUPERNOVA_BROWSER_TESTS=1`.
- [ ] Testes de browser que **não** precisam de Chromium (validação de URL, a checagem de `evaluate` da US-004, decoders) rodam sempre.
- [ ] `gleam test` sem a variável: 0 falhas.
- [ ] Commit: `test(browser): gate real-browser tests behind env flag`.

### US-009: Zero warnings

**Critérios de aceite:**
- [ ] `gleam build --warnings-as-errors` passa.
- [ ] Imports e variáveis não usados são removidos. APIs obsoletas são substituídas. Código morto só é removido se não for público. Se for público e sem uso, registre no relatório e mantenha.
- [ ] Commit: `chore: eliminate compiler warnings`.

### US-010: CI de verdade

**Critérios de aceite:**
- [ ] Crie `.github/workflows/test.yml`, disparado em `push` e `pull_request` para `master`, com:
  - `erlef/setup-beam` usando as versões do `.tool-versions` (`version-file: .tool-versions`, `version-type: strict`);
  - `gleam deps download`;
  - `gleam format --check src test`;
  - `gleam build --warnings-as-errors`;
  - `gleam test`;
  - `make coverage`;
  - um passo final que falha se `git status --porcelain` não estiver vazio.
- [ ] Corrija `.github/workflows/docker.yml`: troque `main` por `master` em `push.branches` e `pull_request.branches`. Mantenha o disparo por tags `v*`.
- [ ] Faça o push do branch e confirme que o workflow `test` roda e passa (`gh run list -R manelsen/supernova -L 3`). Se falhar só no CI, corrija e repita.
- [ ] Commit: `ci: restore test workflow and fix docker branch triggers`.

### US-011: Imagem Docker sobe

**Critérios de aceite:**
- [ ] `docker build -t supernova:retomada .` conclui sem erro.
- [ ] Com uma configuração mínima de teste (criada em `test/fixtures/docker/supernova.yaml`, sem canais habilitados e com o provider em modo mock, se o código permitir), o contêiner sobe e `curl -fsS http://127.0.0.1:<porta>/health/live` responde 200 em até 30 s.
- [ ] Documente o comando no `DEPLOY.md`, numa seção "Smoke test".
- [ ] Remova o contêiner e a imagem de teste ao final (`docker rm -f`, `docker rmi supernova:retomada`).
- [ ] Se o boot exigir tokens reais mesmo sem canais, registre como achado `ABERTO` em `audit/STATUS_2026-11.md`, com evidência, e **não** contorne com tokens falsos que façam chamadas de rede.
- [ ] Commit: `docs(deploy): add container smoke test`.

### US-012: Versão e documentação coerentes

**Critérios de aceite:**
- [ ] `gleam.toml`: `version = "0.3.0"`.
- [ ] Crie `RELEASE_NOTES_v0.3.0.md` resumindo as histórias desta PRD, no formato de `RELEASE_NOTES_v0.2.0.md`.
- [ ] Reescreva `STATUS.md` para refletir o estado **real**: data, versão, canais e providers que funcionam (com base nos testes), contagem de testes, cobertura, achados de auditoria por status e o que ficou para a PRD B. Remova as barras de progresso desatualizadas.
- [ ] No `README.md`, revise só as seções de instalação, testes e status para que batam com a realidade. **Não** reescreva a parte conceitual.
- [ ] Commit: `docs: bring status, version and release notes to v0.3.0`.

## 6. Regras de autonomia

- Não peça aprovação humana: a execução foi pré-aprovada.
- Rede permitida apenas para: `git fetch/pull/push` deste repositório, Hex (`gleam deps`), `mise`, Docker Hub (imagem base) e GitHub Actions/`gh`.
- **Não** crie tags, **não** publique imagens e **não** faça merge do PR.
- **Não** altere `PRD.md` (Agente Companheiro) nem os arquivos originais de `audit/` (só crie `audit/STATUS_2026-11.md`).
- Se um teste existente quebrar, o problema está na sua mudança: corrija a mudança. Única exceção: a migração da stdlib, com justificativa no commit.
- Se uma decisão não estiver especificada, escolha a opção mais conservadora e registre-a.
- Commits pequenos e claros, em inglês, sem `Co-Authored-By` nem crédito de IA.
- Ao terminar: `git push -u origin chore/retomada` e `gh pr create --base master` com o resumo do relatório no corpo.

## 7. Relatório final

Crie `docs/RETOMADA_REPORT.md` com:

- a linha de base (seção 4) e o estado final: toolchain, warnings, testes que passaram e falharam e cobertura;
- os conflitos do merge da US-001 e como foram resolvidos;
- a tabela final de `audit/STATUS_2026-11.md` resumida por status;
- as versões finais de `gleam_stdlib`, `gleam_hackney` e `hackney`, e qualquer fixação com motivo;
- a causa da falha do `browser_test`;
- o resultado do smoke test Docker;
- as decisões tomadas sem especificação explícita;
- a branch, a lista de commits, o link do PR e o link do run de CI verde.

## 8. Métricas de sucesso

- `gleam build --warnings-as-errors` e `gleam test` verdes, com 0 falhas sem `SUPERNOVA_BROWSER_TESTS`.
- Cobertura ≥ threshold definido na US-001, aplicado no CI.
- `git status` limpo depois da suíte de testes.
- Nenhum achado de auditoria `ABERTO`: cada um está `RESOLVIDO` ou `ACEITO` com justificativa.
- `browser evaluate` desabilitado por padrão.
- Workflow `test` verde no PR; `docker.yml` dispara em `master`.
- Imagem Docker sobe e responde em `/health/live`.
- `STATUS.md`, `gleam.toml` e as release notes coerentes em v0.3.0.
[/PRD]
