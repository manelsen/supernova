import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/core/context_injector
import supernova/core/persona/types as persona_types
import supernova/core/prompt_assembly
import supernova/core/world_model/pure as wm_pure
import supernova/core/world_model/types.{FactDecision, FactEntity, FactGoal}
import supernova/llm/provider

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn empty_state() {
  types.initial_state()
}

fn assert_live(state, content, fact_type, author) {
  let #(new_state, _, _) =
    wm_pure.assert_fact(state, content, fact_type, author, 1.0, 0)
  new_state
}

// ---------------------------------------------------------------------------
// inject — facts are injected
// ---------------------------------------------------------------------------

pub fn inject_adds_world_model_header_test() {
  let state =
    empty_state()
    |> assert_live("The sky is blue", FactEntity, "agent_1")
  let result = context_injector.inject(state, "My prompt", "sky", 200)
  should.be_true(string.contains(result, "## World Model Context"))
  should.be_true(string.contains(result, "My prompt"))
}

pub fn inject_includes_relevant_fact_test() {
  let state =
    empty_state()
    |> assert_live("Deploy to production approved", FactDecision, "agent_1")
    |> assert_live("The sky is blue", FactEntity, "agent_2")
  // Only fact matching "production" should appear
  let result =
    context_injector.inject(state, "System prompt", "production", 200)
  should.be_true(string.contains(result, "Deploy to production approved"))
}

pub fn inject_excludes_irrelevant_facts_test() {
  let state =
    empty_state()
    |> assert_live("Deploy to production approved", FactDecision, "agent_1")
    |> assert_live("The sky is blue", FactEntity, "agent_2")
  // Only "production" facts should appear — "sky" should not
  let result =
    context_injector.inject(state, "System prompt", "production", 200)
  should.be_false(string.contains(result, "The sky is blue"))
}

pub fn inject_returns_original_prompt_when_empty_world_model_test() {
  let state = empty_state()
  let result = context_injector.inject(state, "My prompt", "anything", 200)
  should.equal(result, "My prompt")
}

// ---------------------------------------------------------------------------
// inject — token budget is respected
// ---------------------------------------------------------------------------

pub fn inject_respects_token_budget_test() {
  // Each fact has a long content to consume many tokens
  let long_content =
    "This is a very long fact with lots of content that will consume many tokens when injected into the prompt context"
  let state =
    empty_state()
    |> assert_live(long_content <> " fact1", FactEntity, "a")
    |> assert_live(long_content <> " fact2", FactEntity, "a")
    |> assert_live(long_content <> " fact3", FactEntity, "a")
  // Budget of 5 tokens allows zero of these long facts to fit
  let result = context_injector.inject(state, "Prompt", "long", 5)
  should.equal(result, "Prompt")
}

pub fn inject_fits_facts_within_budget_test() {
  let state =
    empty_state()
    |> assert_live("Short", FactEntity, "a")
    |> assert_live(
      "This fact is extremely long and should not fit in a small budget at all because it has many characters",
      FactGoal,
      "a",
    )
  // Budget for ~10 tokens = ~40 chars; "Short" (~5 chars) fits, long one does not
  let result = context_injector.inject(state, "P", "Short", 10)
  should.be_true(string.contains(result, "Short"))
}

// ---------------------------------------------------------------------------
// inject — fallback to all facts when no topic match
// ---------------------------------------------------------------------------

pub fn inject_falls_back_to_all_facts_when_no_topic_match_test() {
  let state =
    empty_state()
    |> assert_live("Unrelated fact about widgets", FactEntity, "agent_1")
  // Topic has no match in facts — should fall back to all facts
  let result =
    context_injector.inject(state, "Prompt", "nonexistent_topic", 200)
  should.be_true(string.contains(result, "Unrelated fact about widgets"))
}

// ---------------------------------------------------------------------------
// inject — tombstoned facts excluded
// ---------------------------------------------------------------------------

pub fn inject_excludes_tombstoned_facts_test() {
  let state0 =
    empty_state()
    |> assert_live("Fact to be retracted", FactDecision, "agent_1")
  // Retract the only fact
  let #(state1, _, _) = wm_pure.retract(state0, "fact_0", "outdated")
  let result = context_injector.inject(state1, "Prompt", "retracted", 200)
  should.equal(result, "Prompt")
}

// ---------------------------------------------------------------------------
// prompt_assembly integration
// ---------------------------------------------------------------------------

pub fn prepare_with_world_model_injects_facts_test() {
  let state =
    empty_state()
    |> assert_live("System constraint: max 3 retries", FactDecision, "sys")
  let msg = provider.user_message("hello")
  let messages =
    prompt_assembly.prepare_with_world_model(
      [msg],
      "Base context",
      state,
      "constraint",
      200,
    )
  let assert [system_msg, _user_msg] = messages
  should.be_true(string.contains(system_msg.content, "World Model Context"))
  should.be_true(string.contains(
    system_msg.content,
    "System constraint: max 3 retries",
  ))
}

pub fn build_companion_system_context_includes_persona_blocks_test() {
  let persona =
    persona_types.PersonaFiles(
      identity: "# Identidade\n\n**Nome:** Aurora",
      soul: "# Alma e Valores\n\nHonestidade radical.",
      user: "# Perfil do Usuário\n\n**Nome:** Micelio",
      style: "# Estilo de Comunicação\n\nRespostas curtas.",
    )

  let context =
    prompt_assembly.build_companion_system_context(
      workspace_path: "workspaces/agent:user-1",
      persona: Some(persona),
      self_state_block: None,
      lessons_block: [],
      relationship_block: None,
      world_model_facts: "Sem fatos relevantes.",
    )

  should.be_true(string.contains(context, "# IDENTIDADE"))
  should.be_true(string.contains(context, "## ALMA E VALORES"))
  should.be_true(string.contains(context, "## USUÁRIO"))
  should.be_true(string.contains(context, "## ESTILO DE COMUNICAÇÃO"))
  should.be_true(string.contains(context, "## WORKSPACE"))
  should.be_true(string.contains(context, "## CONTEXTO DO WORLD MODEL"))
}

pub fn build_companion_system_context_includes_lessons_block_test() {
  let context =
    prompt_assembly.build_companion_system_context(
      workspace_path: "workspaces/agent:user-1",
      persona: None,
      self_state_block: None,
      lessons_block: [
        "[Erro] Validar argumentos antes de executar.\nContexto: Build",
        "[Sucesso] Revisar plano antes de responder.\nContexto: Planejamento",
      ],
      relationship_block: None,
      world_model_facts: "Sem fatos relevantes.",
    )

  should.be_true(string.contains(context, "## LIÇÕES RECENTES (Auto-melhoria):"))
  should.be_true(string.contains(context, "1. [Erro]"))
  should.be_true(string.contains(context, "2. [Sucesso]"))
}
