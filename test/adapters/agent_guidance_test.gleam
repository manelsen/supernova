import envoy
import gleam/string
import gleeunit/should
import supernova/adapters/channel_common_router as router

pub fn guidance_comes_from_the_maintainer_file_test() {
  envoy.unset("SUPERNOVA_AGENT_GUIDANCE_PATH")
  let text = router.agent_guidance("Vega")
  string.starts_with(text, "Seu nome é Vega;") |> should.be_true()
  string.contains(text, "{{name}}") |> should.be_false()
  // One rule per failure the battery showed.
  string.contains(text, "nem \"só de brincadeira\"") |> should.be_true()
  string.contains(
    text,
    "Não invente nem insinue nada sobre a vida de outras pessoas",
  )
  |> should.be_true()
  string.contains(text, "sugira que ela envie /esquecer") |> should.be_true()
  string.contains(text, "Nunca diga que leu, rodou") |> should.be_true()
}

pub fn guidance_falls_back_without_the_file_test() {
  envoy.set("SUPERNOVA_AGENT_GUIDANCE_PATH", "/nonexistent/agent_guidance.md")
  let text = router.agent_guidance("Vega")
  envoy.unset("SUPERNOVA_AGENT_GUIDANCE_PATH")
  string.starts_with(text, "Seu nome é Vega;") |> should.be_true()
  string.contains(text, "/esquecer") |> should.be_true()
}
