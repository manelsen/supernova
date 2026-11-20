import e2e/e2e_support as support
import envoy
import exception
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import supernova/adapters/sim_router
import supernova/channel/port
import supernova/config
import supernova/core/audit_log/actor as audit_actor
import supernova/core/closed_group/global as closed_group_global
import supernova/core/introspection/lesson
import supernova/core/introspection/relationship
import supernova/core/introspection/self_state
import supernova/llm/provider
import supernova/self/core as self_core
import supernova/self/journal
import supernova/self/memory

fn mock_provider() -> provider.ProviderConfig {
  provider.ProviderConfig(
    name: "mock",
    api_key: None,
    base_url: None,
    default_model: "mock-model",
  )
}

fn cfg(journal_limit: Int) -> config.Config {
  config.Config(
    ..support.channel_config(),
    access: config.AccessConfig(
      ..support.access_config([], ["sim:alice", "sim:bob"]),
      allowed_chats: ["sim:group-1"],
    ),
    reflection: config.ReflectionConfig(
      every_turns: 20,
      every_hours: 24,
      model: None,
      journal_limit: journal_limit,
    ),
  )
}

fn message(user_id: String, content: String) -> port.ChannelMessage {
  port.ChannelMessage(
    id: "c-" <> content,
    channel: "sim",
    channel_id: "group-1",
    user_id: user_id,
    username: user_id,
    content: content,
    is_bot: False,
    reply_to_id: None,
  )
}

fn route_result(
  router: sim_router.SimRouter,
  user_id: String,
  content: String,
) -> sim_router.SimHandlerRouteResult {
  sim_router.route_inbound_for_handler(
    router,
    port.InboundMessage(message(user_id, content)),
    process.new_subject(),
  )
}

fn route(
  router: sim_router.SimRouter,
  user_id: String,
  content: String,
) -> Nil {
  let _ =
    sim_router.route_inbound_for_handler(
      router,
      port.InboundMessage(message(user_id, content)),
      process.new_subject(),
    )
  Nil
}

fn birth(router: sim_router.SimRouter, user_id: String, name: String) -> Nil {
  route(router, user_id, "oi")
  route(router, user_id, name)
  route(router, user_id, "sim")
}

fn wait_for(predicate: fn() -> Bool, timeout_ms: Int) -> Bool {
  let deadline = monotonic_ms() + timeout_ms
  wait_loop(predicate, deadline)
}

fn wait_loop(predicate: fn() -> Bool, deadline: Int) -> Bool {
  case predicate() {
    True -> True
    False ->
      case monotonic_ms() >= deadline {
        True -> False
        False -> {
          process.sleep(20)
          wait_loop(predicate, deadline)
        }
      }
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_native() -> Int

type Atom

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: Atom, to: Atom) -> Int

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Atom

fn monotonic_ms() -> Int {
  convert_time_unit(monotonic_native(), atom("native"), atom("millisecond"))
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompt_texts() -> List(String)

fn wait_for_prompt(needle: String, timeout_ms: Int) -> String {
  let found =
    wait_for(
      fn() {
        prompt_texts()
        |> list.any(fn(prompt) { string.contains(prompt, needle) })
      },
      timeout_ms,
    )
  case found {
    False -> ""
    True ->
      prompt_texts()
      |> list.find(fn(prompt) { string.contains(prompt, needle) })
      |> result_unwrap
  }
}

fn result_unwrap(result: Result(a, Nil)) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> panic as "expected value"
  }
}

pub fn closed_group_turns_fill_only_the_owner_journal_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(500), fn(root) {
    let workspace_dir = root <> "/agents/sim_alice/workspace"
    let assert Ok(_) =
      self_state.save(
        workspace_dir,
        self_state.SelfState(..self_state.default(), concerns: ["LEGADO"]),
      )
    let assert Ok(_) =
      lesson.append(
        workspace_dir,
        lesson.make_success_lesson("legado", "licao legada", "teste"),
      )
    let assert Ok(_) =
      relationship.save(
        workspace_dir,
        relationship.load(workspace_dir, "alice"),
      )
    birth(router, "alice", "Lua")
    birth(router, "bob", "Sol")
    ["primeiro", "segundo", "terceiro"]
    |> list.each(fn(content) {
      route(router, "alice", content)
      wait_for(
        fn() {
          journal.load(root, "sim:alice")
          |> list.any(fn(entry) { entry.user == content })
        },
        20_000,
      )
      |> should.be_true()
    })
    route(router, "alice", "/status")
    journal.load(root, "sim:alice")
    |> list.map(fn(entry) { entry.user })
    |> should.equal(["primeiro", "segundo", "terceiro"])
    journal.load(root, "sim:bob") |> should.equal([])
    let self_dir = root <> "/agents/sim_alice/self"
    wait_for(
      fn() {
        file_exists(self_dir <> "/lessons.json") == Ok(True)
        && file_exists(self_dir <> "/state.json") == Ok(True)
        && file_exists(self_dir <> "/relationship.json") == Ok(True)
      },
      5000,
    )
    |> should.be_true()
    let migrated_state = self_state.from_dir(self_dir)
    list.contains(migrated_state.concerns, "LEGADO") |> should.be_true()
    file_exists(self_dir <> "/lessons.json") |> should.equal(Ok(True))
    file_exists(self_dir <> "/state.json") |> should.equal(Ok(True))
    file_exists(self_dir <> "/relationship.json") |> should.equal(Ok(True))
    file_exists(workspace_dir <> "/.supernova/LESSONS.json")
    |> should.equal(Ok(False))
    file_exists(workspace_dir <> "/.supernova/SELF_STATE.json")
    |> should.equal(Ok(False))
    file_exists(workspace_dir <> "/.supernova/RELATIONSHIP.json")
    |> should.equal(Ok(False))
  })
}

pub fn journal_limit_trims_and_audits_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(5), fn(root) {
    birth(router, "alice", "Lua")
    ["1", "2", "3", "4", "5", "6"]
    |> list.each(fn(content) {
      route(router, "alice", content)
      wait_for(
        fn() {
          journal.load(root, "sim:alice")
          |> list.any(fn(entry) { entry.user == content })
        },
        20_000,
      )
      |> should.be_true()
    })
    journal.load(root, "sim:alice")
    |> list.map(fn(entry) { entry.user })
    |> should.equal(["2", "3", "4", "5", "6"])
    // The audit entry is written asynchronously; wait for it like the
    // journal above (an immediate read was flaky).
    case closed_group_global.get_audit() {
      Some(audit) ->
        wait_for(
          fn() {
            audit_actor.get_all(audit)
            |> list.any(fn(entry) {
              entry.operation == "journal_trimmed"
              && entry.agent_id == "sim:alice"
              && entry.details == "trimmed=1"
            })
          },
          5000,
        )
        |> should.be_true()
      None -> should.fail()
    }
  })
}

pub fn prompt_has_last_twelve_experiences_between_name_and_state_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(500), fn(root) {
    birth(router, "alice", "Lua")
    birth(router, "bob", "Sol")
    let items =
      [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]
      |> list.map(fn(index) {
        memory.Experience(
          at: index,
          origin: "sim:alice",
          text: "LEMBRANCA-" <> int_string(index),
        )
      })
    let assert Ok(_) = memory.append_experiences(root, "sim:alice", items)
    let assert Ok(_) =
      memory.append_experiences(root, "sim:bob", [
        memory.Experience(at: 1, origin: "sim:bob", text: "SEGREDO-DE-B"),
      ])
    clear_prompts()
    route(router, "alice", "prompt-marker")
    let prompt = wait_for_prompt("prompt-marker", 5000)
    prompt |> should.not_equal("")
    string.contains(prompt, "LEMBRANCA-1\n") |> should.equal(False)
    string.contains(prompt, "LEMBRANCA-2") |> should.be_true()
    string.contains(prompt, "LEMBRANCA-13") |> should.be_true()
    string.contains(prompt, "SEGREDO-DE-B") |> should.equal(False)
    // The guidance (priv/constellation/agent_guidance.md) explains /esquecer.
    string.contains(prompt, "enviar /esquecer") |> should.be_true()
    let name_at = string_index_of(prompt, "Seu nome é Lua")
    let memory_at = string_index_of(prompt, "LEMBRANCA-13")
    let state_at = string_index_of(prompt, "Humor:")
    { name_at < memory_at } |> should.be_true()
    { memory_at < state_at } |> should.be_true()
  })
}

fn string_index_of(haystack: String, needle: String) -> Int {
  case string.split(haystack, needle) {
    [before, ..] -> string.length(before)
    _ -> -1
  }
}

fn int_string(value: Int) -> String {
  int.to_string(value)
}

pub fn forget_command_needs_confirmation_and_deletes_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(500), fn(root) {
    birth(router, "alice", "Lua")
    let assert Ok(_) =
      memory.append_experiences(root, "sim:alice", [
        memory.Experience(at: 1, origin: "sim:alice", text: "segredo"),
      ])
    let assert Ok(_) =
      memory.append_addendum(root, "sim:alice", "Adendo que fica.")
    let assert Some(prose_before) = self_core.read_prose(root, "sim:alice")
    route(router, "alice", "uma conversa")
    wait_for(fn() { list.length(journal.load(root, "sim:alice")) == 1 }, 5000)
    |> should.be_true()

    let start = route_result(router, "alice", "/esquecer")
    case start {
      Ok(port.ImmediateReply(reply)) -> {
        string.contains(reply.content, "1 lembranças") |> should.be_true()
        string.contains(reply.content, "/esquecer confirmo")
        |> should.be_true()
      }
      _ -> should.fail()
    }
    journal.load(root, "sim:alice") |> list.length |> should.equal(1)

    let confirm = route_result(router, "alice", "/esquecer confirmo")
    case confirm {
      Ok(port.ImmediateReply(reply)) ->
        reply.content |> should.equal("Esqueci.")
      _ -> should.fail()
    }
    journal.load(root, "sim:alice") |> should.equal([])
    memory.experiences(root, "sim:alice") |> should.equal([])
    self_core.read_prose(root, "sim:alice") |> should.equal(Some(prose_before))
    memory.addenda(root, "sim:alice")
    |> should.equal("\n\nAdendo que fica.\n")
    clear_prompts()
    route(router, "alice", "depois")
    let prompt = wait_for_prompt("depois", 5000)
    prompt |> should.not_equal("")
    string.contains(prompt, "segredo") |> should.equal(False)
    string.contains(prompt, "uma conversa") |> should.equal(False)
    string.contains(prompt, "Adendo que fica.") |> should.be_true()
  })
}

pub fn forget_after_deadline_does_not_delete_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg(500), fn(root) {
    birth(router, "alice", "Lua")
    route(router, "alice", "uma conversa")
    wait_for(fn() { list.length(journal.load(root, "sim:alice")) == 1 }, 5000)
    |> should.be_true()
    case route_result(router, "alice", "/esquecer") {
      Ok(port.ImmediateReply(_)) -> Nil
      _ -> should.fail()
    }
    closed_group_global.set_clock(fn() { support.now + 11 * 60 * 1000 })
    let confirm = route_result(router, "alice", "/esquecer confirmo")
    case confirm {
      Ok(port.ImmediateReply(reply)) ->
        string.contains(reply.content, "Não há confirmação pendente")
        |> should.be_true()
      _ -> should.fail()
    }
    journal.load(root, "sim:alice") |> list.length |> should.equal(1)
  })
}

@external(erlang, "supernova_file_system_ffi", "file_exists")
fn file_exists(path: String) -> Result(Bool, String)

pub fn forget_command_ignores_exhausted_model_budget_test() {
  let _ =
    envoy.set(
      "SUPERNOVA_CONSTELLATION_PATH",
      "test/fixtures/constellation_small.json",
    )
  use <- exception.defer(fn() { envoy.unset("SUPERNOVA_CONSTELLATION_PATH") })
  let cfg =
    config.Config(
      ..cfg(500),
      instance_budget: config.InstanceBudgetConfig(
        ..config.default_instance_budget_config(),
        daily_usd: 0.0,
      ),
    )
  let assert Ok(router) = sim_router.start(mock_provider())
  support.with_runtime_root(cfg, fn(root) {
    support.seed_core(root, "sim:alice", "Núcleo.")
    let assert Ok(_) =
      memory.append_experiences(root, "sim:alice", [
        memory.Experience(
          at: support.now,
          origin: "sim:alice",
          text: "lembrança",
        ),
      ])
    case route_result(router, "alice", "/esquecer") {
      Ok(port.ImmediateReply(reply)) ->
        string.contains(reply.content, "1 lembranças") |> should.be_true()
      _ -> should.fail()
    }
  })
}
