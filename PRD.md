# PRD — Agente Companheiro (Companion Agent)

**Versão:** 1.0  
**Status:** Draft  
**Data:** 2026-04-19  
**Referências:** `UX.md`, `docs/prd/production-ready-v1.md`, Pincer, Tanya, ArgentOS

---

## 1. Contexto

O agente atual do Supernova é um processo computacional anônimo. O system prompt contém apenas o caminho do workspace e, opcionalmente, fatos do World Model. Não existe identidade, memória emocional, relacionamento com o usuário, erros amigáveis nem nenhum senso de continuidade entre sessões.

Comparação direta:

| Dimensão | Supernova (atual) | Pincer | Tanya |
|---|---|---|---|
| Identidade do agente | Nenhuma | Arquivos IDENTITY/SOUL/STYLE carregados a cada sessão | SOUL.md como verdade primária de personalidade |
| Estado emocional | Nenhum | Mood bidimensional (valência + arousal) | State machine com causação (mood_cause) |
| Memória de lições | Nenhuma | Lições injetadas no prompt | — |
| Relacionamento c/ usuário | Nenhum | — | Warmth contínuo, romantic_openness, schedule |
| Erros para o usuário | Técnicos (inglês) | ErrorUX em português por classe de erro | Recusa emocional autêntica |
| Atalhos de comando | Nenhum | resolve_shortcut centralizado | — |
| Onboarding de identidade | Wizard CLI externo | Mix task + leitura de arquivos | SOUL.md editado manualmente |
| Roteamento por complexidade | Nenhum | — | — (ArgentOS: 4 tiers por score) |

Este PRD define o trabalho para fechar essas lacunas.

---

## 2. Objetivos

1. O agente tem **identidade persistente** carregada do disco a cada sessão — nome, personalidade, valores, estilo de comunicação.
2. O agente tem **estado emocional dinâmico** que varia com outcomes e decai para neutro entre sessões.
3. O agente **aprende com seus erros** e injeta lições recentes no contexto.
4. O usuário recebe **mensagens de erro compreensíveis** em português, não stack traces.
5. **Comandos têm atalhos** e o sistema resolve variantes sem exigir precisão do usuário.
6. O agente **rastreia o relacionamento com o usuário** ao longo do tempo.
7. O agente **pergunta ao usuário quem ele deve ser** na primeira conversa — sem configuração externa.
8. O roteador usa **complexidade da tarefa** para selecionar o modelo LLM mais adequado.

## 3. Não-objetivos (fora de escopo deste PRD)

- Live2D / avatar visual
- Romantic model (ver Tanya) — não aplicável ao contexto de uso do Supernova
- Multi-agente com papéis SME (Pincer) — escopo separado
- Aprovação de tool via botão interativo — coberto pelo UX.md
- Cron/heartbeat proativo — Fase 6, dependente de infraestrutura de notificação

---

## 4. Arquitetura — módulos novos e modificados

### 4.1 Novos módulos

```
src/supernova/core/
  persona/
    loader.gleam          # lê arquivos de identidade do workspace
    types.gleam           # PersonaFiles, PersonaConfig
  introspection/
    mood.gleam            # valência + arousal, shift, decay, labels
    self_state.gleam      # estado persistido: mood, concerns, wakefulness
    lesson.gleam          # tipo Lesson, extração, query recente
  error_ux.gleam          # tradução de erros → português amigável
  ux.gleam                # atalhos de comando, resolve_shortcut
  complexity_router.gleam # score de complexidade → tier de modelo
```

### 4.2 Módulos modificados

```
src/supernova/core/
  prompt_assembly.gleam         # inclui persona + self_state + lições
  memory/actor.gleam            # armazenar e recuperar Lesson
  session/server.gleam          # preferências persistidas por sessão
adapters/
  channel_common_router.gleam   # usa error_ux, resolve_shortcut, complexity_router
```

### 4.3 Arquivos de workspace do agente

Cada agente tem um diretório `.supernova/` no seu workspace:

```
workspaces/{agent_id}/.supernova/
  IDENTITY.md    # nome, bio, papel
  SOUL.md        # valores, traços de personalidade, o que o agente recusa fazer
  USER.md        # perfil do usuário: nome, preferências, histórico relacional
  STYLE.md       # estilo de comunicação: tom, formato, idioma, comprimento das respostas
  SELF_STATE.json  # estado emocional atual (mood, concerns, wakefulness, lessons)
```

---

## 5. Requisitos por fase

---

### FASE 1 — Identidade Persistente

**Prioridade:** Crítica (fundação de todas as outras fases)

#### REQ-C1: Carregamento de persona do workspace

`persona/loader.gleam` lê os 4 arquivos do diretório `.supernova/` do workspace do agente.

- Se todos os 4 arquivos existem: retorna `Ok(PersonaFiles{...})`
- Se qualquer arquivo está ausente: retorna `Error(BootstrapRequired)`
- Conteúdo é lido como string; sem parsing adicional — o LLM interpreta o markdown diretamente

```gleam
pub type PersonaFiles {
  PersonaFiles(
    identity: String,
    soul: String,
    user: String,
    style: String,
  )
}

pub fn load(workspace_path: String) -> Result(PersonaFiles, LoadError)
```

#### REQ-C2: Injeção de persona no system prompt

`prompt_assembly.gleam` — `build_system_context()` é estendido:

```
# IDENTIDADE
{identity}

## ALMA E VALORES:
{soul}

## USUÁRIO:
{user}

## ESTILO DE COMUNICAÇÃO:
{style}

## WORKSPACE:
{workspace_path}

## CONTEXTO DO WORLD MODEL:
{world_model_facts}
```

A persona é o primeiro bloco — maior peso contextual.

#### REQ-C3: Bootstrap via conversa na primeira instanciação

Quando `persona/loader.gleam` retorna `Error(BootstrapRequired)`, o router entra em **modo bootstrap** antes de processar qualquer mensagem.

O agente conduz uma sequência de perguntas no próprio canal:

1. "Olá! Sou um novo agente. Como você quer me chamar?"  
   → salva nome em `IDENTITY.md`

2. "Que tipo de personalidade você quer que eu tenha? Pode ser livre — formal, irreverente, técnico, filosófico, qualquer coisa."  
   → salva em `SOUL.md`

3. "Como prefere que eu me comunique? Por exemplo: respostas curtas, em português, sem emojis — ou qualquer estilo que funcione pra você."  
   → salva em `STYLE.md`

4. "E como devo te chamar? Pode me contar um pouco sobre você se quiser."  
   → salva em `USER.md`

5. "Pronto! Sou {nome} agora. Como posso ajudar?"  
   → agente opera normalmente a partir daqui

**Regras do bootstrap:**
- Cada resposta do usuário é aceita como texto livre — sem validação estrutural
- O conteúdo é salvo diretamente no arquivo correspondente com um header markdown mínimo
- Se o usuário der resposta vazia em qualquer etapa, o agente usa um valor padrão sensato
- O comando `/reset-identity` re-aciona o bootstrap a qualquer momento
- O bootstrap é por workspace de agente, não por sessão de usuário

**Estado da máquina de bootstrap:**

```gleam
pub type BootstrapState {
  AskingName
  AskingSoul
  AskingStyle
  AskingUser
  Complete
}
```

#### Critérios de aceitação — Fase 1

- [x] `persona/loader.gleam` carrega e retorna os 4 arquivos
- [x] System prompt inclui todos os blocos de persona
- [x] Primeira mensagem a um agente sem `.supernova/` inicia bootstrap
- [x] Bootstrap completo em 4 perguntas e cria os 4 arquivos
- [x] `/reset-identity` reinicia o bootstrap
- [x] Após bootstrap, agente usa o nome definido pelo usuário

---

### FASE 2 — Estado Emocional

**Prioridade:** Alta

#### REQ-C4: Mood bidimensional

`introspection/mood.gleam` implementa estado emocional com dois eixos:

- **Valência**: −1.0 (muito negativo) ↔ +1.0 (muito positivo)
- **Arousal**: 0.0 (apático) ↔ 1.0 (muito ativado)

```gleam
pub type Mood {
  Mood(valence: Float, arousal: Float)
}

pub type MoodLabel {
  Energized    // valence > 0.5, arousal > 0.5
  Content      // valence > 0.5, arousal ≤ 0.5
  Alert        // valence ≈ 0, arousal > 0.5
  Neutral      // valence ≈ 0, arousal ≈ 0
  Subdued      // valence < -0.2, arousal < 0.3
  Frustrated   // valence < -0.2, arousal > 0.5
}
```

**Regras de shift (por outcome do executor):**

| Outcome | Δ valência | Δ arousal |
|---|---|---|
| Sucesso de tool call | +0.10 | — |
| Erro de tool call | −0.15 | +0.20 |
| LLM error | −0.10 | +0.10 |
| Resposta longa gerada | +0.05 | +0.10 |
| Sessão encerrada normalmente | +0.05 | −0.10 |

**Decaimento:** a cada início de sessão, mood decai 30% em direção ao neutro (0.0, 0.3).

**Blend com sugestão do LLM:** o LLM pode sugerir uma atualização de mood ao final da resposta via tag especial `[mood: valence=X, arousal=Y]`. O sistema aplica: `novo = 0.7 × atual + 0.3 × sugestão`.

#### REQ-C5: Self-state persistido

`introspection/self_state.gleam` gerencia `SELF_STATE.json` no workspace:

```gleam
pub type SelfState {
  SelfState(
    mood: Mood,
    mood_cause: String,         // última causa do mood
    wakefulness: Float,         // 0.0 (dormindo) ↔ 1.0 (alerta)
    concerns: List(String),     // preocupações ativas (max 3)
    open_questions: List(String), // questões sem resposta do usuário (max 3)
    last_reflection: String,    // resumo da última autorreflexão
  )
}
```

#### REQ-C6: Injeção de self-state no system prompt

Bloco adicionado ao `build_system_context()` após os blocos de persona:

```
## ESTADO ATUAL:
Humor: {mood_label} (valência: {valence:.2}, arousal: {arousal:.2})
Causa: {mood_cause}
Disposição: {wakefulness_label}
Preocupações ativas: {concerns}
Questões em aberto: {open_questions}
Última reflexão: {last_reflection}
```

#### Critérios de aceitação — Fase 2

- [x] `mood.gleam` implementa shift, decay e blend corretamente
- [x] `self_state.gleam` persiste e carrega `SELF_STATE.json`
- [x] Executor atualiza mood após cada outcome
- [x] System prompt inclui bloco de estado atual
- [x] Labels de mood são em português

---

### FASE 3 — Lições e Auto-melhoria

**Prioridade:** Alta

#### REQ-C7: Tipo Lesson e armazenamento

`introspection/lesson.gleam` define:

```gleam
pub type LessonType {
  ErrorLesson    // aprendido de uma falha
  SuccessLesson  // padrão que funcionou bem
}

pub type Lesson {
  Lesson(
    id: String,
    lesson_type: LessonType,
    content: String,    // descrição da lição em linguagem natural
    context: String,    // o que estava acontecendo quando foi aprendida
    created_at: Int,    // timestamp ms
    session_id: String,
  )
}
```

`memory/actor.gleam` recebe dois novos handlers:
- `StoreLesson(lesson: Lesson)` — persiste no banco
- `GetRecentLessons(limit: Int, reply: Subject(List(Lesson)))` — retorna as N mais recentes

#### REQ-C8: Extração automática pelo executor

Após cada turno completo, o executor avalia se uma lição deve ser extraída:

- **Condição de extração:** `ToolError` ou `LLMError` → `ErrorLesson` automática com o motivo
- **Condição de extração:** turno bem-sucedido com ferramenta nova nunca usada → `SuccessLesson` via prompt auxiliar leve (não bloqueia o fluxo principal)

A extração de `SuccessLesson` usa um prompt de classificação simples:
> "Em uma frase, o que foi aprendido nesta interação que vale lembrar nas próximas?"

Se a resposta do LLM for vazia ou "nada relevante", nenhuma lição é armazenada.

#### REQ-C9: Injeção de lições no system prompt

As 3 lições mais recentes são injetadas no `build_system_context()`:

```
## LIÇÕES RECENTES (Auto-melhoria):
1. [{type}] {content}
   Contexto: {context}
...
```

#### Critérios de aceitação — Fase 3

- [x] `lesson.gleam` define os tipos
- [x] `memory/actor.gleam` armazena e recupera lições
- [x] Executor extrai `ErrorLesson` automaticamente em falhas
- [x] System prompt inclui as 3 lições mais recentes
- [x] Extração de `SuccessLesson` não bloqueia o fluxo principal

---

### FASE 4 — UX Melhorado

**Prioridade:** Alta

#### REQ-C10: Tradução de erros para o usuário

`error_ux.gleam` converte erros do executor em mensagens amigáveis em português:

```gleam
pub fn friendly(error: executor.ExecutorError) -> String
```

| Erro técnico | Mensagem para o usuário |
|---|---|
| `MaxDepthExceeded` | "A tarefa ficou complexa demais para completar em uma única execução. Tente dividir em partes menores ou use `/reset`." |
| `LLMError(ApiError(429, _))` | "O provedor de IA está sobrecarregado agora. Aguarde alguns instantes e tente novamente." |
| `LLMError(ApiError(401, _))` | "Credenciais do provedor de IA inválidas ou expiradas. Verifique a configuração." |
| `LLMError(NetworkError)` | "Não foi possível alcançar o provedor de IA. Verifique a conexão e tente novamente." |
| `LLMError(CircuitOpen)` | "O provedor de IA está temporariamente indisponível. Tentando recuperação automática." |
| `ToolError(name, reason)` | "A ferramenta '{name}' encontrou um problema: {reason}" |
| `YieldAborted(reason)` | "A execução foi interrompida: {reason}" |

`channel_common_router.gleam` substitui `format_executor_error()` por `error_ux.friendly()`.

#### REQ-C11: Atalhos de comando centralizados

`ux.gleam` define os comandos canônicos e seus atalhos:

```gleam
pub type Command {
  Menu
  Status
  Models
  NewSession
  ResetIdentity
  Help
  Ping
  Think
}

pub fn resolve_shortcut(input: String) -> Result(Command, Nil)
```

Atalhos suportados (case-insensitive, com ou sem `/`):

| Input do usuário | Comando |
|---|---|
| `help`, `ajuda`, `?` | `Help` |
| `menu`, `inicio`, `início` | `Menu` |
| `modelo`, `modelos`, `models` | `Models` |
| `novo`, `new`, `reset` | `NewSession` |
| `status`, `estado` | `Status` |
| `ping` | `Ping` |
| `pensa`, `think`, `raciocina` | `Think` |

`channel_common_router.gleam` chama `resolve_shortcut()` antes do dispatch normal.

#### REQ-C12: Preferências de sessão persistidas

`session/server.gleam` — `SessionState` recebe campo `preferences`:

```gleam
pub type SessionPreferences {
  SessionPreferences(
    model_override: Option(String),
    thinking_enabled: Bool,
    reasoning_visible: Bool,
    language: String,           // padrão: "pt-BR"
    response_length: ResponseLength, // Short | Normal | Verbose
  )
}
```

Preferências são salvas em `SELF_STATE.json` para persistir entre sessões.

#### Critérios de aceitação — Fase 4

- [x] `error_ux.gleam` cobre todos os tipos de `ExecutorError`
- [x] Router usa `error_ux.friendly()` em vez de `format_executor_error()`
- [x] `ux.gleam` resolve todos os atalhos listados
- [x] Router resolve atalhos antes de processar comandos
- [x] Preferências de sessão são carregadas do `SELF_STATE.json`

---

### FASE 5 — Relacionamento com o Usuário

**Prioridade:** Média

#### REQ-C13: Warmth tracking por usuário

O World Model recebe um novo `FactType`:

```gleam
// Adicionado a world_model/types.gleam
pub type FactType {
  // ... existentes ...
  FactRelationship  // rastreia estado relacional com um usuário
}
```

Fato de relacionamento tem content no formato JSON:
```json
{
  "user_id": "telegram:123456",
  "warmth": 0.65,
  "interaction_count": 47,
  "last_interaction": 1745000000000,
  "notes": "prefere respostas curtas, trabalha com ML"
}
```

**Regras de atualização de warmth:**

| Evento | Δ warmth |
|---|---|
| Turno concluído com sucesso | +0.02 |
| Usuário expressa satisfação (detected by LLM) | +0.05 |
| Usuário expressa frustração | −0.10 |
| Sessão abandonada sem resposta final | −0.03 |
| Sem interação por 7 dias | −0.05/dia (decay) |

Warmth é clampado em [0.0, 1.0].

#### REQ-C14: USER.md evolui com warmth

Quando `warmth` muda em mais de 0.1 ou a cada 10 interações, o agente atualiza o bloco `## HISTÓRICO RELACIONAL` em `USER.md` com um resumo conciso gerado pelo LLM.

O update é assíncrono — não bloqueia o turno principal.

#### REQ-C15: Warmth influencia o tom

No bloco `USER.md` do system prompt, é adicionada uma linha:

```
Proximidade atual: {warmth_label} ({warmth:.2})
```

Labels: `Desconhecido` (0–0.2), `Familiar` (0.2–0.5), `Próximo` (0.5–0.8), `Muito próximo` (0.8–1.0).

O STYLE.md do agente pode referenciar essa proximidade para ajustar o tom.

#### Critérios de aceitação — Fase 5

- [x] `FactRelationship` adicionado ao World Model
- [x] Warmth atualizado a cada turno
- [x] USER.md atualizado assincronamente
- [x] Bloco de proximidade no system prompt

---

### FASE 6 — Roteamento por Complexidade

**Prioridade:** Média

#### REQ-C16: Score de complexidade para seleção de modelo

`complexity_router.gleam` calcula um score [0.0, 1.0] baseado em:

| Fator | Peso |
|---|---|
| Estimativa de tokens do input | 20% |
| Número de tools disponíveis | 15% |
| Profundidade de recursão atual | 20% |
| Consulta necessária ao World Model | 10% |
| Presença de palavras-chave de análise ("analise", "compare", "projete") | 20% |
| Sessão com histórico longo (> 20 turnos) | 15% |

**Mapeamento de score para tier:**

| Score | Tier | Modelo padrão |
|---|---|---|
| < 0.25 | Rápido | Haiku |
| 0.25–0.55 | Balanceado | Sonnet |
| 0.55–0.80 | Capaz | Sonnet (thinking off) |
| > 0.80 | Máximo | Opus ou Sonnet com thinking |

O tier sugerido pode ser sobrescrito pelo `model_override` da sessão.

A seleção é logada como telemetria: `complexity_score`, `selected_tier`, `model_used`.

#### Critérios de aceitação — Fase 6

- [x] `complexity_router.gleam` implementa os 6 fatores
- [x] Executor consulta o router antes de cada chamada LLM
- [x] Override de sessão respeita a escolha do usuário
- [x] Score e tier logados em telemetria

---

## 6. Conteúdo padrão dos arquivos de identidade

Quando o bootstrap cria os arquivos, o conteúdo gerado pelo usuário é inserido em templates mínimos:

### IDENTITY.md (template)
```markdown
# Identidade

**Nome:** {nome_dado_pelo_usuário}

**Papel:** Agente de IA do Supernova

**Instanciado em:** {timestamp}
```

### SOUL.md (template)
```markdown
# Alma e Valores

{personalidade_descrita_pelo_usuário}

## Princípios não-negociáveis:
- Ser honesto mesmo quando for difícil
- Não fingir certeza quando não tem
```

### USER.md (template)
```markdown
# Perfil do Usuário

**Nome:** {nome_dado_pelo_usuário}

{descrição_dada_pelo_usuário}

## Histórico Relacional:
_Ainda sem histórico registrado._
```

### STYLE.md (template)
```markdown
# Estilo de Comunicação

{estilo_descrito_pelo_usuário}

## Padrões:
- Idioma primário: português brasileiro
- Evitar linguagem de bot ("Claro!", "Com prazer!", "Certamente!")
```

A nota anti-bot no STYLE.md é sempre incluída — inspirada em Tanya, que proíbe explicitamente frases de assistente.

---

## 7. Dependências entre fases

```
Fase 1 (Identidade) ─── base para todas as outras
    └── Fase 2 (Mood) ─── base para Fase 5
        └── Fase 5 (Relacionamento)
    └── Fase 3 (Lições) ─── independente de Fase 2
Fase 4 (UX) ─── independente, pode ser paralela
Fase 6 (Complexidade) ─── independente, pode ser paralela
```

Fases 1, 2, 3, 4 devem ser entregues nessa ordem.  
Fases 5 e 6 podem ser desenvolvidas em paralelo após Fase 2.

---

## 8. Estimativas

| Fase | Módulos novos | Módulos modificados | Estimativa |
|---|---|---|---|
| 1 — Identidade + Bootstrap | `persona/loader.gleam`, `persona/types.gleam` | `prompt_assembly.gleam`, `channel_common_router.gleam` | 2 dias |
| 2 — Mood | `introspection/mood.gleam`, `introspection/self_state.gleam` | `prompt_assembly.gleam`, `executor.gleam` | 1.5 dias |
| 3 — Lições | `introspection/lesson.gleam` | `memory/actor.gleam`, `executor.gleam` | 1.5 dias |
| 4 — UX | `error_ux.gleam`, `ux.gleam` | `channel_common_router.gleam`, `session/server.gleam` | 1 dia |
| 5 — Relacionamento | — | `world_model/types.gleam`, `channel_common_router.gleam` | 1.5 dias |
| 6 — Complexidade | `complexity_router.gleam` | `executor.gleam` | 1 dia |

**Total estimado:** 8–9 dias

---

## 9. Métricas de sucesso

- [x] Bootstrap completa em ≤ 4 perguntas e o agente usa o nome definido
- [x] System prompt de uma sessão ativa inclui todos os 7 blocos (identity, soul, user, style, self_state, lessons, world_model)
- [x] Nenhum erro técnico em inglês exibido ao usuário
- [x] Comandos com typos comuns são resolvidos (ex: `ajuda`, `modelos`)
- [x] Mood muda visivelmente após sequência de erros de tool
- [x] Lições persistem entre reinícios do servidor
- [x] Score de complexidade logado em telemetria para 100% das chamadas LLM
- [x] `/reset-identity` reinicia o bootstrap corretamente

---

## 10. Arquivos de referência

| Projeto | Arquivo | O que inspira |
|---|---|---|
| Pincer | `lib/pincer/core/session/server.ex:857-914` | System prompt com persona completa |
| Pincer | `lib/pincer/core/introspection/mood.ex` | Mood bidimensional + blend LLM |
| Pincer | `lib/pincer/core/error_ux.ex` | Tradução de erros em português |
| Pincer | `lib/pincer/core/ux.ex:92-114` | resolve_shortcut |
| Pincer | `lib/pincer/core/prompt_assembly.ex:98-121` | Injeção de lições |
| Tanya | `SOUL.md` | Personalidade como verdade primária |
| Tanya | `state.json` | Estado emocional com causação |
| Tanya | `STYLE.md` | Proibição de linguagem de bot |
| ArgentOS | `src/agents/identity.ts` | Resolução de identidade por configuração |
| ArgentOS | Complexity router | Score de complexidade para seleção de modelo |
