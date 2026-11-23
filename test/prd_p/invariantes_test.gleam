//// PRD-P, invariantes do caminho da mensagem (P-01).
////
//// The whole Supernova runs here, with the mock model and the sim channel
//// (which, since the P-00b, takes the path of every real channel: the
//// durable inbox and the chat's lane). Each invariant is checked through
//// that path, with messages sent at the same time.
////
//// An invariant the current code does not keep yet is a function without
//// the `_test` suffix, named for the story that makes it pass, so it is
//// written now and not run: that story renames it.

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova
import supernova/config
import supernova/core/agent_identity
import supernova/core/closed_group/global as closed_group_global
import supernova/core/introspection/relationship
import supernova/core/prompt_log
import supernova/core/session/history_store
import supernova/harness/sim_client
import supernova/self/core as self_core
import supernova/self/sampler
import test_workspace

const token = "invariantes"

type Ctx {
  Ctx(port: Int, data_dir: String)
}

fn principal(user: String) -> String {
  "sim:" <> user
}

/// Boot the whole Supernova for `members` (born and named) and `unborn`
/// (members without a core yet), with private chats `dm-<user>` and one
/// group `grp` holding everyone.
fn with_supernova(
  members: List(String),
  unborn: List(String),
  body: fn(Ctx) -> a,
) -> a {
  test_workspace.with_isolated_workspace("prd-p-invariantes", fn(root) {
    let data_dir = root <> "/data"
    // Recording prompts (I2 counts the birth calls) needs a harness data dir.
    let assert Ok(_) = ensure_dir(data_dir)
    let assert Ok(_) = write_file(data_dir <> "/.harness", "")
    let now = now_ms()
    list.each(members, fn(user) { born(data_dir, user, now) })
    let everyone = list.append(members, unborn)
    let port = free_port()
    let base = config.default_config()
    let cfg =
      config.Config(
        ..base,
        environment: "harness",
        data_dir: data_dir,
        providers: dict.from_list([
          #(
            "mock",
            config.ProviderConfig(
              provider: config.Mock,
              api_key: None,
              base_url: None,
              model: Some("mock-model"),
              models: [],
              timeout_ms: 30_000,
            ),
          ),
        ]),
        sim: config.SimConfig(
          enabled: True,
          bind: "127.0.0.1",
          port: port,
          token: Some(token),
          record_prompts: True,
        ),
        access: config.AccessConfig(
          mode: config.Allowlist,
          admins: [],
          members: list.map(everyone, principal),
          denied_reply: "Esta instância é privada.",
          allowed_chats: [
            "sim:grp",
            ..list.map(everyone, fn(user) { "sim:dm-" <> user })
          ],
        ),
        rate_limit: config.RateLimitConfig(
          member: config.RoleRateLimitConfig(messages_per_minute: 100_000),
          admin: config.RoleRateLimitConfig(messages_per_minute: 100_000),
        ),
        role_budgets: config.RoleBudgetsConfig(
          member: config.RoleBudgetConfig(
            tokens_per_hour: -1,
            tool_calls_per_hour: -1,
          ),
          admin: config.RoleBudgetConfig(
            tokens_per_hour: -1,
            tool_calls_per_hour: -1,
          ),
        ),
      )
    // The default httpc profile keeps two connections per host and queues
    // the rest behind a slow one: the test would measure the client.
    open_client(64)
    let assert Ok(runtime) = supernova.boot(cfg, now_ms)
    let result = body(Ctx(port: port, data_dir: data_dir))
    supernova.shutdown(runtime)
    result
  })
}

fn born(data_dir: String, user: String, now: Int) -> Nil {
  let who = principal(user)
  let assert Ok(_) =
    self_core.save_birth(
      data_dir,
      who,
      sampler.Sampled(traits: ["calma"], seed: 1, attempts: 1),
      1,
      "Prosa dos testes de invariantes.",
      now,
    )
  let assert Some(core) = self_core.load(data_dir, who)
  let assert Ok(_) = self_core.set_name(data_dir, who, core, "Lua", now)
  Nil
}

/// Send from `user` in `chat` and wait for the turn; the turn's outcome.
fn say(ctx: Ctx, user: String, chat: String, content: String) -> String {
  case
    sim_client.send_for_outcome(
      ctx.port,
      token,
      chat,
      user,
      user,
      content,
      chat == "grp",
    )
  {
    Ok(outcome) -> outcome
    Error(reason) -> reason
  }
}

/// Send all at once, each from its own process; the outcomes, in the order
/// of `messages`.
fn say_all(
  ctx: Ctx,
  messages: List(#(String, String, String)),
) -> List(String) {
  let replies =
    list.index_map(messages, fn(message, index) {
      let reply = process.new_subject()
      process.spawn(fn() {
        let #(user, chat, content) = message
        process.send(reply, #(index, say(ctx, user, chat, content)))
      })
      reply
    })
  list.map(replies, fn(reply) {
    let assert Ok(#(_, outcome)) = process.receive(reply, within: 60_000)
    outcome
  })
}

fn said(ctx: Ctx, user: String, chat: String) -> List(#(String, String)) {
  history_store.HistoryStore(data_dir: ctx.data_dir, limit: 1_000_000)
  |> history_store.load("sim:" <> chat <> ":" <> user)
  |> list.filter(fn(m) { m.role == "user" || m.role == "assistant" })
  |> list.map(fn(m) { #(m.role, m.content) })
}

/// Polls `ready` up to `ms` (a condition with a deadline, not a fixed wait).
fn wait_until(ready: fn() -> Bool, ms: Int) -> Bool {
  case ready(), ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(20)
      wait_until(ready, ms - 20)
    }
  }
}

// ============================================================================
// I1: order within a chat
// ============================================================================

/// Messages sent to the same chat at the same time never overlap: the
/// conversation alternates each message and its own reply.
pub fn i1_turns_of_a_chat_never_overlap_test() {
  use ctx <- with_supernova(["ana"], [])
  let contents =
    list.repeat(Nil, 12)
    |> list.index_map(fn(_, i) { "[mock-eco] mensagem " <> int.to_string(i) })
  let outcomes =
    say_all(ctx, list.map(contents, fn(c) { #("ana", "dm-ana", c) }))
  outcomes |> list.all(fn(o) { o == "ok" }) |> should.be_true()

  let history = said(ctx, "ana", "dm-ana")
  list.length(history) |> should.equal(24)
  history
  |> list.sized_chunk(2)
  |> list.each(fn(pair) {
    let assert [#("user", question), #("assistant", answer)] = pair
    answer |> should.equal("eco: " <> question)
  })
  history
  |> list.filter(fn(m) { m.0 == "user" })
  |> list.map(fn(m) { m.1 })
  |> list.sort(string.compare)
  |> should.equal(list.sort(contents, string.compare))
}

// ============================================================================
// I2: one birth
// ============================================================================

/// Two first messages of the same person, in two chats at once, before the
/// agent exists: one birth, one call to the model to be born.
pub fn i2_two_first_messages_one_birth_test() {
  use ctx <- with_supernova([], ["carla"])
  let _ =
    say_all(ctx, [
      #("carla", "dm-carla", "oi"),
      #("carla", "grp", "oi, gente"),
    ])
  self_core.exists(ctx.data_dir, principal("carla")) |> should.be_true()
  // One birth is one "birth" line in her biography (the model is called
  // twice for one birth: the core's prose, then the introduction).
  let assert Ok(biography) =
    read_file(self_core.biography_path(ctx.data_dir, principal("carla")))
  biography
  |> string.split("\n")
  |> list.count(string.contains(_, "\"kind\":\"birth\""))
  |> should.equal(1)
}

// ============================================================================
// I3: forgetting is forgetting
// ============================================================================

fn forget_with_a_turn_in_flight(ctx: Ctx) -> String {
  let assert "ok" = say(ctx, "ana", "grp", "[mock-eco] segredo abacaxi")
  // A slow turn of hers in the group, then /esquecer in the private chat
  // while it is running.
  let slow = process.new_subject()
  process.spawn(fn() {
    process.send(
      slow,
      say(ctx, "ana", "grp", "[mock-delay-ms=1500] [mock-eco] lento pre"),
    )
  })
  wait_until(
    fn() {
      prompt_log.read_all(ctx.data_dir)
      |> list.any(string.contains(_, "lento pre"))
    },
    5000,
  )
  |> should.be_true()
  let _ = say(ctx, "ana", "dm-ana", "/esquecer")
  let _ = say(ctx, "ana", "dm-ana", "/esquecer confirmo")
  let assert Ok(slow_outcome) = process.receive(slow, within: 30_000)
  slow_outcome
}

/// Nothing said before a confirmed /esquecer survives in her conversations,
/// even with a turn of hers in flight in another chat.
pub fn i3_nothing_said_before_forgetting_survives_test() {
  use ctx <- with_supernova(["ana"], [])
  let _ = forget_with_a_turn_in_flight(ctx)
  let dir = history_store.dir(ctx.data_dir, principal("ana"))
  case list_dir(dir) {
    Ok(files) ->
      list.each(files, fn(file) {
        let assert Ok(text) = read_file(dir <> "/" <> file)
        string.contains(text, "abacaxi") |> should.be_false()
        string.contains(text, "lento pre") |> should.be_false()
      })
    Error(_) -> Nil
  }
}

/// PENDENTE até a P-03 (D2): the turn in flight is answered; /esquecer
/// waits for it and erases it too. Today the turn fails when its session is
/// stopped, and she gets no reply.
pub fn i3_the_turn_in_flight_is_answered_p03() {
  use ctx <- with_supernova(["ana"], [])
  forget_with_a_turn_in_flight(ctx) |> should.equal("ok")
}

// ============================================================================
// I4: no write lost
// ============================================================================

/// Turns of the same person at the same time, in her private chat and in
/// the group, each count once in the relationship. The end of every turn
/// reads, changes and writes it with no owner, so two at once can lose one;
/// the window is too short for this test to catch it reliably today (it
/// passes), and the P-02 adds a deterministic test through the agent's
/// process. Kept here as a guard.
pub fn i4_every_turn_counts_once_test() {
  use ctx <- with_supernova(["ana"], [])
  let messages =
    list.repeat(Nil, 30)
    |> list.index_map(fn(_, i) {
      let chat = case i % 2 {
        0 -> "dm-ana"
        _ -> "grp"
      }
      #("ana", chat, "[mock-eco] " <> int.to_string(i))
    })
  let ok = say_all(ctx, messages) |> list.count(fn(o) { o == "ok" })
  ok |> should.equal(30)
  relationship.load_in(
    agent_identity.self_dir(ctx.data_dir, principal("ana")),
    "ana",
  ).interaction_count
  |> should.equal(30)
}

// ============================================================================
// I5: no answered turn without its record
// ============================================================================

/// Every turn answered at the same time, across chats and people, is in its
/// conversation.
pub fn i5_every_answered_turn_is_kept_test() {
  use ctx <- with_supernova(["ana", "bia"], [])
  let messages =
    list.flat_map(["ana", "bia"], fn(user) {
      list.repeat(Nil, 6)
      |> list.index_map(fn(_, i) {
        let chat = case i % 2 {
          0 -> "dm-" <> user
          _ -> "grp"
        }
        #(user, chat, "[mock-eco] " <> user <> " " <> int.to_string(i))
      })
    })
  let outcomes = say_all(ctx, messages)
  list.zip(messages, outcomes)
  |> list.each(fn(pair) {
    let #(#(user, chat, content), outcome) = pair
    outcome |> should.equal("ok")
    said(ctx, user, chat)
    |> list.contains(#("user", content))
    |> should.be_true()
  })
}

// ============================================================================
// I6: the gate fails closed
// ============================================================================

/// With the closed group's runtime gone, a message is refused, never let
/// through.
pub fn i6_the_gate_fails_closed_test() {
  use ctx <- with_supernova(["ana"], [])
  say(ctx, "ana", "dm-ana", "[mock-eco] antes") |> should.equal("ok")
  // The closed group still in force, its runtime gone.
  closed_group_global.clear_runtime()
  closed_group_global.set_enforced(True)
  say(ctx, "ana", "dm-ana", "[mock-eco] sem gate") |> should.equal("denied")
  said(ctx, "ana", "dm-ana")
  |> list.contains(#("user", "[mock-eco] sem gate"))
  |> should.be_false()
}

// ============================================================================
// I7: isolation
// ============================================================================

/// One person's search never reaches another's conversation, even with
/// both talking at the same time.
pub fn i7_a_search_never_reaches_another_person_test() {
  use ctx <- with_supernova(["ana", "bia"], [])
  let _ =
    say_all(ctx, [
      #("ana", "dm-ana", "[mock-eco] meu segredo é abacaxi"),
      #("bia", "dm-bia", "[mock-eco] eu gosto de melancia"),
    ])
  let _ =
    say_all(ctx, [
      #("bia", "dm-bia", "[mock-busca abacaxi] procura"),
      #("ana", "dm-ana", "[mock-busca melancia] procura"),
    ])
  let kept = fn(user) {
    history_store.HistoryStore(data_dir: ctx.data_dir, limit: 1_000_000)
    |> history_store.load("sim:dm-" <> user <> ":" <> user)
    |> list.filter(fn(m) { m.role == "tool" })
    |> list.map(fn(m) { m.content })
    |> string.join("\n")
  }
  let bia_found = kept("bia")
  string.contains(bia_found, "Nada encontrado") |> should.be_true()
  string.contains(bia_found, "segredo") |> should.be_false()
  let ana_found = kept("ana")
  string.contains(ana_found, "Nada encontrado") |> should.be_true()
  string.contains(ana_found, "gosto") |> should.be_false()
}

@external(erlang, "supernova_stress_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "supernova_harness_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "supernova_file_system_ffi", "list_dir")
fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_stress_ffi", "open_client")
fn open_client(workers: Int) -> Nil
