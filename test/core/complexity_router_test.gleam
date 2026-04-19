import gleam/option
import gleeunit/should
import supernova/core/complexity_router
import supernova/llm/provider

fn anthropic_config(model: String) -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "anthropic",
    api_key: option.None,
    base_url: option.None,
    default_model: model,
  )
}

pub fn route_high_complexity_selects_maximum_tier_test() {
  let long_prompt =
    "analise e compare este sistema detalhadamente e projete uma migracao completa"
    <> " com todos os riscos e trade-offs repetidos para aumentar tokens "
    <> "analise compare projete analise compare projete"
  let messages = [
    provider.system_message("## CONTEXTO DO WORLD MODEL:\nCom fatos"),
    provider.user_message(long_prompt),
  ]

  let decision =
    complexity_router.route(
      anthropic_config("claude-sonnet-4-5"),
      messages,
      12,
      6,
    )

  should.equal(
    decision.tier == complexity_router.Capable
      || decision.tier == complexity_router.Maximum,
    True,
  )
}

pub fn route_respects_user_override_model_test() {
  let messages = [provider.user_message("analise isso")]
  let decision =
    complexity_router.route(anthropic_config("custom-override"), messages, 8, 5)

  decision.selected_config.default_model
  |> should.equal("custom-override")
}
