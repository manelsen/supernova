[PRD]
# PRD: Quickstart Linux via `curl` + `systemd` com wizard obrigatório

## Overview
Substituir o onboarding principal baseado em Docker por um quickstart host-native iniciado via `curl`, com instalação em Linux com `systemd`, PostgreSQL local e configuração obrigatória via wizard. Docker deixa de ser caminho recomendado e passa a ser opção de desenvolvimento e documentação avançada. O wizard passa a ser obrigatório no fluxo padrão, com modo não interativo equivalente para automação e CI.

## Goals
- Tornar `curl + systemd + wizard` o único quickstart recomendado.
- Suportar instalação em distros Linux com `systemd`.
- Preferir release pré-compilado, com fallback para build local quando necessário.
- Instalar e configurar PostgreSQL local automaticamente no host.
- Separar configuração estrutural de segredos.
- Exigir confirmação explícita antes do primeiro `start` do serviço.
- Manter um caminho não interativo suportado para automação e CI.

## Quality Gates
These commands must pass for every user story. The stories that introduce missing scripts must add them and wire them into CI.
- `gleam format --check src test`
- `gleam test`
- `bash ./scripts/quickstart/smoke_test.sh`
- `bash ./scripts/docs/verify_onboarding.sh`

## User Stories

### US-001: Redefinir o onboarding oficial
**Description:** Como operador Linux, quero que a documentação oficial aponte primeiro para o quickstart host-native para seguir o caminho recomendado desde o início.

**Acceptance Criteria:**
- [ ] `README.md` passa a mostrar `curl + systemd + wizard` como fluxo principal de instalação.
- [ ] `docs/operations/ONBOARDING.md`, `docs/operations/ONBOARD_CLI.md` e `docs/operations/ONBOARDING_OVERVIEW.md` usam o novo fluxo como referência principal.
- [ ] `docker compose up` deixa de aparecer como quickstart primário e é reclassificado como fluxo `dev/advanced`.

### US-002: Criar instalador bootstrap via `curl`
**Description:** Como operador Linux, quero iniciar a instalação com um comando baseado em `curl` para provisionar o sistema com o menor atrito possível.

**Acceptance Criteria:**
- [ ] Existe um instalador suportado por `curl` que baixa e executa um fluxo de instalação idempotente.
- [ ] O instalador detecta arquitetura, distro e gerenciador de pacotes antes de prosseguir.
- [ ] O instalador tenta usar um release pré-compilado compatível e cai para build local com mensagem explícita quando não houver artefato suportado.

### US-003: Provisionar host e PostgreSQL local
**Description:** Como operador Linux, quero que o quickstart prepare o host e o PostgreSQL local automaticamente para não depender de Docker nem de setup manual do banco.

**Acceptance Criteria:**
- [ ] O instalador instala e inicia PostgreSQL local no host quando ele não estiver disponível.
- [ ] O instalador cria banco, usuário e credenciais padrão do quickstart sem destruir dados existentes em reruns.
- [ ] As migrations necessárias são aplicadas automaticamente antes do primeiro start do serviço.

### US-004: Instalar o serviço via `systemd`
**Description:** Como operador Linux, quero que o Supernova seja instalado como serviço `systemd` para ter boot automático, restart policy e operação padrão de servidor Linux.

**Acceptance Criteria:**
- [ ] O instalador cria usuário e grupo dedicados para o serviço e diretórios persistentes com permissões restritas.
- [ ] Um unit file `systemd` é instalado com `restart`, `stop` gracioso e leitura de config/segredos externos.
- [ ] O fluxo documenta e valida `systemctl status supernova` e `journalctl -u supernova`.

### US-005: Tornar o wizard obrigatório no fluxo padrão
**Description:** Como operador Linux, quero ser forçado a passar pelo wizard antes do primeiro start para evitar config parcial ou inconsistente.

**Acceptance Criteria:**
- [ ] O instalador sempre chama `supernova/wizard_main` no fluxo interativo padrão antes de habilitar o serviço.
- [ ] O serviço não inicia se `supernova.yaml` e o arquivo de segredos não tiverem sido gerados por um fluxo válido do wizard.
- [ ] Se o wizard for abortado ou falhar, o serviço permanece não iniciado e o instalador retorna erro acionável.

### US-006: Suportar wizard não interativo para automação
**Description:** Como operador de CI ou automação, quero um modo não interativo equivalente ao wizard para provisionar ambientes sem interação humana.

**Acceptance Criteria:**
- [ ] O wizard oferece modo não interativo com parâmetros e/ou variáveis de ambiente documentados.
- [ ] O modo não interativo usa a mesma validação e o mesmo gerador de arquivos do modo interativo.
- [ ] O comando falha com código diferente de zero quando faltar qualquer entrada obrigatória.

### US-007: Separar config estrutural de segredos e pedir confirmação antes do start
**Description:** Como operador Linux, quero manter configuração e segredos separados e confirmar explicitamente o primeiro start para revisar o que será ativado.

**Acceptance Criteria:**
- [ ] O wizard grava configuração estrutural em `supernova.yaml` e segredos em um `EnvironmentFile` separado.
- [ ] O arquivo de segredos é criado com permissões restritas e seus valores não aparecem em logs ou no resumo final.
- [ ] Após gerar os arquivos, o instalador mostra um resumo e pede confirmação explícita antes de habilitar/iniciar o serviço.

### US-008: Validar quickstart, docs e reposicionar Docker
**Description:** Como mantenedor do projeto, quero smoke tests e validação de documentação para garantir que o novo onboarding continue correto ao longo do tempo.

**Acceptance Criteria:**
- [ ] Existe `./scripts/quickstart/smoke_test.sh` cobrindo instalação, geração de config, start do serviço e health checks.
- [ ] Existe `./scripts/docs/verify_onboarding.sh` verificando que os comandos documentados do onboarding existem e refletem o fluxo oficial.
- [ ] `docs/operations/DOCKER.md` e documentos correlatos permanecem no repositório, mas marcados como `dev/advanced` e não como quickstart oficial.

## Functional Requirements
- `FR-1:` O quickstart oficial deve começar por um instalador baixado via `curl`.
- `FR-2:` O instalador deve detectar distro Linux, arquitetura e disponibilidade de `systemd`.
- `FR-3:` O instalador deve preferir release pré-compilado e usar build local apenas como fallback explícito.
- `FR-4:` O instalador deve instalar e configurar PostgreSQL local por padrão no fluxo quickstart.
- `FR-5:` O instalador deve criar usuário, grupo e diretórios dedicados para o serviço.
- `FR-6:` O serviço deve ser instalado como unidade `systemd` com restart policy e desligamento gracioso.
- `FR-7:` O wizard deve ser obrigatório no fluxo padrão antes do primeiro start.
- `FR-8:` Deve existir modo não interativo suportado e equivalente ao wizard interativo.
- `FR-9:` `supernova.yaml` deve conter apenas configuração estrutural; segredos devem ficar em `EnvironmentFile`.
- `FR-10:` O instalador deve pedir confirmação explícita antes de habilitar e iniciar o serviço.
- `FR-11:` O quickstart deve validar saúde do serviço e conectividade mínima após o primeiro start.
- `FR-12:` Docker deve permanecer suportado apenas como fluxo de desenvolvimento e uso avançado, fora do onboarding principal.

## Non-Goals
- Remover Docker, `Dockerfile` ou `docker-compose.yml` do repositório.
- Suportar macOS, Windows ou sistemas Linux sem `systemd`.
- Entregar Kubernetes, Helm ou empacotamento para orquestradores nesta iniciativa.
- Tratar configuração manual escrita do zero como caminho principal do usuário.
- Otimizar o quickstart inicial para PostgreSQL remoto como fluxo padrão.

## Technical Considerations
- Reaproveitar `src/supernova/wizard_main.gleam` como base do fluxo interativo e estendê-lo para modo não interativo.
- Introduzir um instalador versionado, idempotente e auditável, preferencialmente em `scripts/` ou diretório equivalente de packaging.
- Definir layout consistente de instalação, por exemplo config em `/etc/supernova`, dados em `/var/lib/supernova` e segredos em `EnvironmentFile` dedicado.
- Reaproveitar o suporte de shutdown gracioso já existente no runtime para integração correta com `systemd`.
- Formalizar como o quickstart aplica `migrations/init.sql` sem depender de containers.
- Garantir que o caminho de fallback para build local informe claramente pré-requisitos ausentes e próximos passos.

## Success Metrics
- Um host Linux com `systemd` chega a serviço saudável em até 10 minutos no caminho feliz.
- O quickstart oficial deixa de depender de `docker compose up` em `README.md` e docs de onboarding.
- O smoke test do quickstart passa em CI nos ambientes Linux suportados.
- O fluxo interativo e o não interativo geram artefatos compatíveis e inicializam o mesmo serviço.
- O primeiro start só ocorre após confirmação explícita do operador.

## Open Questions
- Quais distros e arquiteturas serão Tier 1 para release pré-compilado e cobertura de CI, já que o objetivo declarado é “Linux com systemd” de forma ampla?
- O artefato pré-compilado será um release BEAM autocontido ou exigirá Erlang pré-instalado no host?
- O quickstart deve suportar upgrade in-place e uninstall já nesta mesma iniciativa ou isso fica para uma PRD posterior?
[/PRD]
