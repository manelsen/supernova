import gleeunit
import gleeunit/should
import supernova/core/agent_identity

pub fn principal_paths_are_channel_scoped_test() {
  let telegram = agent_identity.agent_dir("/data", "telegram:123")
  let discord = agent_identity.agent_dir("/data", "discord:123")
  telegram |> should.not_equal(discord)
  telegram |> should.equal("/data/agents/telegram_123")
  discord |> should.equal("/data/agents/discord_123")
}

pub fn principal_encoding_stays_inside_agents_dir_test() {
  let encoded = agent_identity.encode_principal("sim:../../x")
  encoded |> should.equal("sim_%2E%2E%2F%2E%2E%2Fx")
  agent_identity.agent_dir("/data", "sim:../../x")
  |> should.equal("/data/agents/sim_%2E%2E%2F%2E%2E%2Fx")
  agent_identity.decode_principal(encoded) |> should.equal("sim:../../x")
}

pub fn principal_encoding_roundtrip_test() {
  let principal = "discord:guild:123/../á"
  agent_identity.encode_principal(principal)
  |> agent_identity.decode_principal
  |> should.equal(principal)
}

pub fn session_principal_uses_last_segment_test() {
  agent_identity.principal_from_session_id("telegram:-100:42")
  |> should.equal("telegram:42")
  agent_identity.principal_from_session_id("sim:group:alice")
  |> should.equal("sim:alice")
}

pub fn main() -> Nil {
  gleeunit.main()
}
