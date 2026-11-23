//// Stress test: many agents with long histories, under parallel load, with
//// chaos in the middle. The LLM is the mock, so what is measured is the
//// platform (channels, lanes, sessions, gate, disk, search), not a provider.
////
////     gleam run -m supernova/stress/run -- --agents 200 --history 5000 \
////       --groups 10 --workers 100 --seconds 120 --search-every 5
////
//// Phases: seed every agent (born, with a private and a group history);
//// boot the whole Supernova with the sim channel; workers send messages in
//// parallel until the deadline (every Nth a search, a fifth to the groups,
//// whose lane serialises its members); halfway in, kill sessions, then
//// stop and boot the whole runtime again; sample the VM every second.
//// At the end: no answered turn may be missing on disk, and the search must
//// see every seeded message.

import gleam/dict
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import supernova
import supernova/config
import supernova/core/session/history_store
import supernova/core/session/supervisor
import supernova/harness/sim_client
import supernova/self/core as self_core
import supernova/self/sampler
import supernova/tools/buscar_conversa

pub type Options {
  Options(
    agents: Int,
    history: Int,
    groups: Int,
    workers: Int,
    seconds: Int,
    search_every: Int,
    chaos: Bool,
    /// `routing.parallel`: the pre-LLM phase in each chat's lane.
    parallel: Bool,
    out: String,
  )
}

pub fn default_options() -> Options {
  Options(
    agents: 200,
    history: 5000,
    groups: 10,
    workers: 100,
    seconds: 120,
    search_every: 5,
    chaos: True,
    parallel: False,
    out: "stress-out",
  )
}

pub fn parse_args(args: List(String)) -> Result(Options, String) {
  parse_loop(args, default_options())
}

fn parse_loop(args: List(String), o: Options) -> Result(Options, String) {
  let number = fn(value, rest, set) {
    case int.parse(value) {
      Ok(n) if n > 0 -> parse_loop(rest, set(n))
      _ -> Error("invalid number: " <> value)
    }
  }
  case args {
    [] -> Ok(o)
    ["--agents", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, agents: n) })
    ["--history", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, history: n) })
    ["--groups", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, groups: n) })
    ["--workers", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, workers: n) })
    ["--seconds", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, seconds: n) })
    ["--search-every", v, ..rest] ->
      number(v, rest, fn(n) { Options(..o, search_every: n) })
    ["--no-chaos", ..rest] -> parse_loop(rest, Options(..o, chaos: False))
    ["--parallel", ..rest] -> parse_loop(rest, Options(..o, parallel: True))
    ["--out", v, ..rest] -> parse_loop(rest, Options(..o, out: v))
    [unknown, ..] -> Error("unknown argument: " <> unknown)
  }
}

pub fn main() -> Nil {
  case parse_args(cli_args()) {
    Error(message) -> {
      io.println(message)
      halt(2)
    }
    Ok(options) ->
      case run(options) {
        Ok(ok) -> halt(bool_code(ok))
        Error(message) -> {
          io.println("stress failed: " <> message)
          halt(1)
        }
      }
  }
}

fn bool_code(ok: Bool) -> Int {
  case ok {
    True -> 0
    False -> 1
  }
}

// ============================================================================
// Seeding
// ============================================================================

fn principal(i: Int) -> String {
  "sim:u" <> int.to_string(i)
}

fn user(i: Int) -> String {
  "u" <> int.to_string(i)
}

fn dm(i: Int) -> String {
  "dm-u" <> int.to_string(i)
}

fn group(o: Options, i: Int) -> String {
  "grp-" <> int.to_string(i % o.groups)
}

fn group_history(o: Options) -> Int {
  int.max(o.history / 5, 2)
}

/// Every seeded message holds "semente" and one of 37 words; a live message
/// never holds "semente", so a search for both counts only the seed.
fn seeded_content(i: Int, k: Int) -> String {
  "semente "
  <> int.to_string(k)
  <> " da agente "
  <> int.to_string(i)
  <> " sobre palavra"
  <> int.to_string(k % 37)
}

/// Seeded messages of agent `i` holding "palavra7" and "semente".
fn expected_palavra7(o: Options) -> Int {
  let count = fn(n) { seq(0, n - 1) |> list.count(fn(k) { k % 37 == 7 }) }
  count(o.history) + count(group_history(o))
}

fn seed_agent(
  o: Options,
  data_dir: String,
  i: Int,
  now: Int,
) -> Result(Nil, String) {
  let who = principal(i)
  use _ <- result.try(self_core.save_birth(
    data_dir,
    who,
    sampler.Sampled(traits: ["calma", "curiosa"], seed: i, attempts: 1),
    1,
    "Prosa do teste de estresse.",
    now - 400 * 86_400_000,
  ))
  use born <- result.try(
    self_core.load(data_dir, who) |> option.to_result("core not saved"),
  )
  use _ <- result.try(self_core.set_name(
    data_dir,
    who,
    born,
    "Agente" <> int.to_string(i),
    now - 399 * 86_400_000,
  ))
  let store = history_store.HistoryStore(data_dir: data_dir, limit: 100)
  let history = fn(count, span_days) {
    let first = now - span_days * 86_400_000
    seq(0, count - 1)
    |> list.map(fn(k) {
      history_store.StoredMessage(
        role: case k % 2 {
          0 -> "user"
          _ -> "assistant"
        },
        content: seeded_content(i, k),
        at: first + k * { span_days * 86_400_000 / count },
      )
    })
  }
  use _ <- result.try(history_store.append(
    store,
    "sim:" <> dm(i) <> ":" <> user(i),
    history(o.history, 365),
  ))
  history_store.append(
    store,
    "sim:" <> group(o, i) <> ":" <> user(i),
    history(group_history(o), 365),
  )
}

/// Seed every agent, a process each; fails on the first error.
fn seed_all(o: Options, data_dir: String, now: Int) -> Result(Int, String) {
  let started = mono_ms()
  let done = process.new_subject()
  seq(1, o.agents)
  |> list.each(fn(i) {
    process.spawn(fn() { process.send(done, seed_agent(o, data_dir, i, now)) })
  })
  seq(1, o.agents)
  |> list.try_each(fn(_) {
    case process.receive(done, within: 600_000) {
      Ok(result) -> result
      Error(Nil) -> Error("seeding timed out")
    }
  })
  |> result.map(fn(_) { mono_ms() - started })
}

// ============================================================================
// Runtime
// ============================================================================

fn build_config(
  o: Options,
  data_dir: String,
  port: Int,
  token: String,
) -> config.Config {
  let base = config.default_config()
  let agents = seq(1, o.agents)
  config.Config(
    ..base,
    environment: "harness",
    routing: config.RoutingConfig(parallel: o.parallel),
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
      record_prompts: False,
    ),
    access: config.AccessConfig(
      mode: config.Allowlist,
      admins: [],
      members: list.map(agents, principal),
      denied_reply: "Esta instância é privada.",
      allowed_chats: list.flatten([
        list.map(agents, fn(i) { "sim:" <> dm(i) }),
        seq(0, o.groups - 1)
          |> list.map(fn(g) { "sim:grp-" <> int.to_string(g) }),
      ]),
    ),
    rate_limit: config.RateLimitConfig(
      member: config.RoleRateLimitConfig(messages_per_minute: 1_000_000),
      admin: config.RoleRateLimitConfig(messages_per_minute: 1_000_000),
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
    budgets: config.BudgetsConfig(
      ..base.budgets,
      default: config.BudgetConfigYaml(
        ..base.budgets.default,
        tokens_per_hour: -1,
        tool_calls_per_minute: -1,
      ),
    ),
    instance_budget: config.InstanceBudgetConfig(
      ..base.instance_budget,
      daily_usd: 1_000_000.0,
    ),
  )
}

const port_key = "supernova_stress_port"

// ============================================================================
// Host: each runtime lives in its own process, as in production it lives in
// its own OS process. Stopping it is the graceful shutdown followed by the
// end of that process, which takes whatever it started (routers, listeners)
// with it, as the end of the OS process would.
// ============================================================================

type HostMessage {
  StopHost(done: process.Subject(Int))
}

type Host {
  Host(runtime: supernova.Runtime, control: process.Subject(HostMessage))
}

fn start_host(cfg: config.Config) -> Result(Host, String) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let control = process.new_subject()
    case supernova.boot(cfg, now_ms) {
      Error(reason) -> process.send(reply, Error(reason))
      Ok(runtime) -> {
        process.send(reply, Ok(Host(runtime: runtime, control: control)))
        let StopHost(done) = process.receive_forever(control)
        let started = mono_ms()
        supernova.shutdown(runtime)
        process.send(done, mono_ms() - started)
        process.kill(process.self())
      }
    }
  })
  case process.receive(reply, within: 120_000) {
    Ok(result) -> result
    Error(Nil) -> Error("boot timed out")
  }
}

/// Graceful shutdown, then the host ends; returns the shutdown's duration.
fn stop_host(host: Host) -> Int {
  let done = process.new_subject()
  process.send(host.control, StopHost(done))
  process.receive(done, within: 120_000) |> result.unwrap(-1)
}

// ============================================================================
// Load
// ============================================================================

pub type Turn {
  Turn(
    agent: Int,
    chat: String,
    kind: String,
    outcome: String,
    ms: Int,
    at: Int,
  )
}

type WorkerMessage {
  Done(Turn)
  Finished
}

fn worker(
  o: Options,
  token: String,
  deadline: Int,
  out: process.Subject(WorkerMessage),
  n: Int,
) -> Nil {
  case mono_ms() >= deadline {
    True -> process.send(out, Finished)
    False -> {
      let i = rand_int(o.agents)
      let #(chat, is_group) = case rand_int(5) {
        1 -> #(group(o, i), True)
        _ -> #(dm(i), False)
      }
      let #(kind, content) = case n % o.search_every {
        0 -> #(
          "search",
          "[mock-busca palavra"
            <> int.to_string(rand_int(37) - 1)
            <> "] procura",
        )
        _ -> #("plain", "[mock-sem-ferramenta] mensagem " <> int.to_string(n))
      }
      let port = global_get_int(port_key)
      let started = mono_ms()
      let outcome = case
        sim_client.send_for_outcome(
          port,
          token,
          chat,
          user(i),
          user(i),
          content,
          is_group,
        )
      {
        Ok(outcome) -> outcome
        Error(reason) -> reason
      }
      let elapsed = mono_ms() - started
      process.send(
        out,
        Done(Turn(
          agent: i,
          chat: chat,
          kind: kind,
          outcome: outcome,
          ms: elapsed,
          at: started,
        )),
      )
      // A refused connection (the runtime is restarting) is retried soon,
      // not spun on.
      case outcome {
        "ok" -> Nil
        _ -> process.sleep(100)
      }
      worker(o, token, deadline, out, n + 1)
    }
  }
}

// ============================================================================
// VM sampling
// ============================================================================

pub type Sample {
  Sample(
    at: Int,
    processes: Int,
    memory_mb: Float,
    max_queue: Int,
    run_queue: Int,
    busiest: String,
  )
}

fn sampler_loop(
  until: Int,
  out: process.Subject(Sample),
  collector: process.Pid,
) -> Nil {
  case mono_ms() >= until {
    True -> Nil
    False -> {
      let #(processes, memory, max_queue, run_queue, busiest) =
        vm_snapshot(collector)
      process.send(
        out,
        Sample(
          at: mono_ms(),
          processes: processes,
          memory_mb: int.to_float(memory) /. 1_048_576.0,
          max_queue: max_queue,
          run_queue: run_queue,
          busiest: busiest,
        ),
      )
      process.sleep(1000)
      sampler_loop(until, out, collector)
    }
  }
}

// ============================================================================
// Run
// ============================================================================

pub fn run(o: Options) -> Result(Bool, String) {
  let dir = o.out <> "/" <> int.to_string(now_ms())
  let data_dir = dir <> "/data"
  use _ <- result.try(ensure_dir(data_dir))
  use _ <- result.try(write_file(data_dir <> "/.stress", ""))
  log(
    "seeding "
    <> int.to_string(o.agents)
    <> " agents x "
    <> int.to_string(o.history)
    <> " private + "
    <> int.to_string(group_history(o))
    <> " group messages",
  )
  let now = now_ms()
  use seed_ms <- result.try(seed_all(o, data_dir, now))
  let seeded_bytes = dir_bytes(data_dir)
  log(
    "seeded in "
    <> int.to_string(seed_ms)
    <> " ms, "
    <> int.to_string(seeded_bytes / 1_048_576)
    <> " MB on disk",
  )

  open_client(o.workers)
  let token = "stress-token"
  let port = free_port()
  global_put_int(port_key, port)
  let cfg = build_config(o, data_dir, port, token)
  let boot_started = mono_ms()
  use host <- result.try(start_host(cfg))
  let boot_ms = mono_ms() - boot_started
  log(
    "booted in "
    <> int.to_string(boot_ms)
    <> " ms; load for "
    <> int.to_string(o.seconds)
    <> " s",
  )

  let started = mono_ms()
  let deadline = started + o.seconds * 1000
  let results = process.new_subject()
  let samples = process.new_subject()
  let collector = process.self()
  process.spawn(fn() { sampler_loop(deadline + 30_000, samples, collector) })
  seq(1, o.workers)
  |> list.each(fn(w) {
    process.spawn(fn() { worker(o, token, deadline, results, w * 1000) })
  })

  // Chaos, by wall clock: a third in, kill sessions mid-turn; halfway, stop
  // the whole runtime and boot it again on a new port.
  let #(host, chaos) = case o.chaos {
    False -> #(host, [])
    True -> {
      process.sleep(int.max(o.seconds * 1000 / 3, 1))
      let killed = kill_sessions(host.runtime, 20)
      log("chaos: killed " <> int.to_string(killed) <> " sessions")
      process.sleep(int.max(o.seconds * 1000 / 2 - o.seconds * 1000 / 3, 1))
      let stopped_ms = stop_host(host)
      let new_port = free_port()
      let reboot_started = mono_ms()
      case start_host(build_config(o, data_dir, new_port, token)) {
        Ok(rebooted) -> {
          global_put_int(port_key, new_port)
          let reboot_ms = mono_ms() - reboot_started
          log(
            "chaos: stopped in "
            <> int.to_string(stopped_ms)
            <> " ms, booted again in "
            <> int.to_string(reboot_ms)
            <> " ms",
          )
          #(rebooted, [
            "sessions killed mid-load: " <> int.to_string(killed),
            "shutdown under load: " <> int.to_string(stopped_ms) <> " ms",
            "boot again under load: "
              <> int.to_string(reboot_ms)
              <> " ms (at "
              <> int.to_string({ reboot_started - started } / 1000)
              <> " s)",
          ])
        }
        Error(reason) -> {
          log("chaos: boot again failed: " <> reason)
          #(host, ["boot again FAILED: " <> reason])
        }
      }
    }
  }

  let turns = collect(results, o.workers, [])
  let load_ms = mono_ms() - started
  log("load done: " <> int.to_string(list.length(turns)) <> " turns")

  // Let what the restart left in the inbox be answered before counting.
  process.sleep(3000)
  let integrity = check_integrity(o, data_dir, turns)
  let search = check_search(o, data_dir)
  let _ = stop_host(host)
  let vm = drain_samples(samples, [])

  let report =
    render(
      o,
      seed_ms,
      seeded_bytes,
      boot_ms,
      load_ms,
      turns,
      vm,
      chaos,
      integrity,
      search,
    )
  use _ <- result.try(write_file(dir <> "/report.md", report))
  io.println(report)
  log("report: " <> dir <> "/report.md")
  // With chaos on, turns cut by the kill or the restart are expected; what
  // fails the run is a lost turn or a wrong search. Without chaos, every
  // turn must be answered.
  Ok(
    integrity.missing == 0
    && search.wrong == 0
    && { o.chaos || failed(turns) == 0 },
  )
}

fn collect(
  results: process.Subject(WorkerMessage),
  remaining: Int,
  acc: List(Turn),
) -> List(Turn) {
  case remaining {
    0 -> acc
    _ ->
      case process.receive(results, within: 600_000) {
        Ok(Done(turn)) -> collect(results, remaining, [turn, ..acc])
        Ok(Finished) -> collect(results, remaining - 1, acc)
        Error(Nil) -> acc
      }
  }
}

fn drain_samples(
  samples: process.Subject(Sample),
  acc: List(Sample),
) -> List(Sample) {
  case process.receive(samples, within: 0) {
    Ok(sample) -> drain_samples(samples, [sample, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

fn kill_sessions(runtime: supernova.Runtime, count: Int) -> Int {
  supervisor.list_sessions(runtime.session_supervisor)
  |> list.shuffle
  |> list.take(count)
  |> list.filter_map(fn(id) {
    case supervisor.get_session(runtime.session_supervisor, id) {
      Ok(session) ->
        case process.subject_owner(session) {
          Ok(pid) -> {
            process.kill(pid)
            Ok(Nil)
          }
          Error(Nil) -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
  |> list.length
}

fn failed(turns: List(Turn)) -> Int {
  list.count(turns, fn(t) { t.outcome != "ok" })
}

// ============================================================================
// Checks
// ============================================================================

pub type Integrity {
  Integrity(
    checked: Int,
    exact: Int,
    extra: Int,
    missing: Int,
    examples: List(String),
  )
}

/// Each answered turn adds the person's message and the reply to the chat's
/// file. A file with fewer lines than seed + 2 x answered lost a turn; more
/// lines are turns answered after the restart whose HTTP reply was lost
/// with the old runtime, or replays from the inbox.
fn check_integrity(
  o: Options,
  data_dir: String,
  turns: List(Turn),
) -> Integrity {
  let store = history_store.HistoryStore(data_dir: data_dir, limit: 1_000_000)
  let answered =
    turns
    |> list.filter(fn(t) { t.outcome == "ok" })
    |> list.fold(dict.new(), fn(acc, t) {
      dict.upsert(acc, #(t.agent, t.chat), fn(n) { option.unwrap(n, 0) + 1 })
    })
  seq(1, o.agents)
  |> list.flat_map(fn(i) {
    [#(i, dm(i), o.history), #(i, group(o, i), group_history(o))]
  })
  |> list.fold(Integrity(0, 0, 0, 0, []), fn(acc, item) {
    let #(i, chat, seeded) = item
    let ok = dict.get(answered, #(i, chat)) |> result.unwrap(0)
    let expected = seeded + 2 * ok
    let found =
      list.length(
        history_store.read_file_messages(history_store.path(
          store,
          "sim:" <> chat <> ":" <> user(i),
        )),
      )
    let label = chat <> "/" <> user(i)
    case int.compare(found, expected) {
      order.Eq ->
        Integrity(..acc, checked: acc.checked + 1, exact: acc.exact + 1)
      order.Gt ->
        Integrity(..acc, checked: acc.checked + 1, extra: acc.extra + 1)
      order.Lt ->
        Integrity(
          ..acc,
          checked: acc.checked + 1,
          missing: acc.missing + 1,
          examples: list.take(
            [
              label
                <> ": "
                <> int.to_string(found)
                <> " < "
                <> int.to_string(expected),
              ..acc.examples
            ],
            10,
          ),
        )
    }
  })
}

pub type SearchCheck {
  SearchCheck(checked: Int, wrong: Int, worst_ms: Int, examples: List(String))
}

/// The search sees every seeded message: "palavra7 semente" finds exactly
/// what the seed put there, for a sample of agents, while the load ran.
fn check_search(o: Options, data_dir: String) -> SearchCheck {
  let expected = expected_palavra7(o)
  seq(1, int.min(o.agents, 20))
  |> list.fold(SearchCheck(0, 0, 0, []), fn(acc, i) {
    let started = mono_ms()
    let found =
      buscar_conversa.search(data_dir, principal(i), ["palavra7", "semente"])
    let ms = mono_ms() - started
    let acc =
      SearchCheck(
        ..acc,
        checked: acc.checked + 1,
        worst_ms: int.max(acc.worst_ms, ms),
      )
    case found {
      Ok(f) if f.matches == expected -> acc
      Ok(f) ->
        SearchCheck(..acc, wrong: acc.wrong + 1, examples: [
          user(i)
            <> ": "
            <> int.to_string(f.matches)
            <> " != "
            <> int.to_string(expected),
          ..acc.examples
        ])
      Error(reason) ->
        SearchCheck(..acc, wrong: acc.wrong + 1, examples: [
          user(i) <> ": " <> reason,
          ..acc.examples
        ])
    }
  })
}

// ============================================================================
// Report
// ============================================================================

fn percentile(sorted: List(Int), p: Int) -> Int {
  case sorted {
    [] -> 0
    _ -> {
      let n = list.length(sorted)
      let index = int.min(n - 1, n * p / 100)
      list.drop(sorted, index) |> list.first |> result.unwrap(0)
    }
  }
}

fn latency_line(label: String, turns: List(Turn)) -> String {
  let ok =
    turns
    |> list.filter(fn(t) { t.outcome == "ok" })
    |> list.map(fn(t) { t.ms })
    |> list.sort(int.compare)
  "| "
  <> label
  <> " | "
  <> int.to_string(list.length(ok))
  <> " | "
  <> int.to_string(percentile(ok, 50))
  <> " | "
  <> int.to_string(percentile(ok, 95))
  <> " | "
  <> int.to_string(percentile(ok, 99))
  <> " | "
  <> int.to_string(list.last(ok) |> result.unwrap(0))
  <> " |"
}

fn render(
  o: Options,
  seed_ms: Int,
  seeded_bytes: Int,
  boot_ms: Int,
  load_ms: Int,
  turns: List(Turn),
  vm: List(Sample),
  chaos: List(String),
  integrity: Integrity,
  search: SearchCheck,
) -> String {
  let ok = list.count(turns, fn(t) { t.outcome == "ok" })
  let errors =
    turns
    |> list.filter(fn(t) { t.outcome != "ok" })
    |> list.fold(dict.new(), fn(acc, t) {
      dict.upsert(acc, t.outcome, fn(n) { option.unwrap(n, 0) + 1 })
    })
    |> dict.to_list
    |> list.map(fn(pair) { "- " <> pair.0 <> ": " <> int.to_string(pair.1) })
  let max_by = fn(f: fn(Sample) -> Int) {
    vm |> list.map(f) |> list.fold(0, int.max)
  }
  let max_mem =
    vm |> list.map(fn(s) { s.memory_mb }) |> list.fold(0.0, float.max)
  let first_mem =
    vm |> list.first |> result.map(fn(s) { s.memory_mb }) |> result.unwrap(0.0)
  let last_mem =
    vm |> list.last |> result.map(fn(s) { s.memory_mb }) |> result.unwrap(0.0)
  [
    "# Teste de estresse",
    "",
    "## Carga",
    "",
    "- agentes: "
      <> int.to_string(o.agents)
      <> "; histórico semeado: "
      <> int.to_string(o.history)
      <> " mensagens no privado e "
      <> int.to_string(group_history(o))
      <> " no grupo, por agente ("
      <> int.to_string(o.agents * { o.history + group_history(o) })
      <> " no total, "
      <> int.to_string(seeded_bytes / 1_048_576)
      <> " MB, semeados em "
      <> int.to_string(seed_ms)
      <> " ms)",
    "- grupos: "
      <> int.to_string(o.groups)
      <> "; workers em paralelo: "
      <> int.to_string(o.workers)
      <> "; duração: "
      <> int.to_string(o.seconds)
      <> " s; uma busca a cada "
      <> int.to_string(o.search_every)
      <> " mensagens; roteamento "
      <> case o.parallel {
      True -> "paralelo (na fila do chat)"
      False -> "no ator do canal"
    },
    "- boot: " <> int.to_string(boot_ms) <> " ms",
    "",
    "## Turnos",
    "",
    "- respondidos: "
      <> int.to_string(ok)
      <> " de "
      <> int.to_string(list.length(turns))
      <> " ("
      <> float.to_string(float.to_precision(
      int.to_float(ok) *. 1000.0 /. int.to_float(int.max(load_ms, 1)),
      1,
    ))
      <> " por segundo)",
    "- sem resposta: " <> int.to_string(failed(turns)),
    ..list.append(errors, [
      "",
      "| tipo | respondidos | p50 ms | p95 ms | p99 ms | máx ms |",
      "|---|---|---|---|---|---|",
      latency_line(
        "conversa privada",
        list.filter(turns, fn(t) {
          t.kind == "plain" && string.starts_with(t.chat, "dm-")
        }),
      ),
      latency_line(
        "grupo (fila do chat)",
        list.filter(turns, fn(t) { string.starts_with(t.chat, "grp-") }),
      ),
      latency_line(
        "com busca",
        list.filter(turns, fn(t) { t.kind == "search" }),
      ),
      latency_line("todos", turns),
      "",
      "## Caos",
      "",
      ..list.append(
        case chaos {
          [] -> ["- desligado"]
          lines -> list.map(lines, fn(l) { "- " <> l })
        },
        [
          "",
          "## BEAM (amostra por segundo)",
          "",
          "- processos: máx " <> int.to_string(max_by(fn(s) { s.processes })),
          "- memória: início "
            <> float.to_string(float.to_precision(first_mem, 1))
            <> " MB, máx "
            <> float.to_string(float.to_precision(max_mem, 1))
            <> " MB, fim "
            <> float.to_string(float.to_precision(last_mem, 1))
            <> " MB",
          "- maior fila de mensagens de um processo: "
            <> int.to_string(max_by(fn(s) { s.max_queue })),
          "- run queue máx: " <> int.to_string(max_by(fn(s) { s.run_queue })),
          "- processo com a maior fila, nas amostras com fila acima de 20: "
            <> busiest_summary(vm),
          "",
          "## Integridade",
          "",
          "- conversas conferidas: " <> int.to_string(integrity.checked),
          "- exatas (semente + 2 x turnos respondidos): "
            <> int.to_string(integrity.exact),
          "- com turnos a mais (respondidos depois do restart): "
            <> int.to_string(integrity.extra),
          "- **com turnos faltando: "
            <> int.to_string(integrity.missing)
            <> "**",
          ..list.append(list.map(integrity.examples, fn(e) { "  - " <> e }), [
            "",
            "## Busca no histórico inteiro",
            "",
            "- agentes conferidas: "
              <> int.to_string(search.checked)
              <> "; esperado: "
              <> int.to_string(expected_palavra7(o))
              <> " mensagens semeadas por agente",
            "- **resultados errados: " <> int.to_string(search.wrong) <> "**",
            "- busca mais lenta (fora da carga): "
              <> int.to_string(search.worst_ms)
              <> " ms",
            ..list.map(search.examples, fn(e) { "  - " <> e })
          ])
        ],
      )
    ])
  ]
  |> string.join("\n")
}

fn busiest_summary(vm: List(Sample)) -> String {
  vm
  |> list.filter(fn(s) { s.max_queue > 20 })
  |> list.fold(dict.new(), fn(acc, s) {
    dict.upsert(acc, s.busiest, fn(n) { option.unwrap(n, 0) + 1 })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
  |> list.take(5)
  |> list.map(fn(pair) { int.to_string(pair.1) <> "x " <> pair.0 })
  |> string.join("; ")
}

fn log(message: String) -> Nil {
  io.println("[stress] " <> message)
}

// ============================================================================
// FFI
// ============================================================================

@external(erlang, "supernova_stress_ffi", "vm_snapshot")
fn vm_snapshot(exclude: process.Pid) -> #(Int, Int, Int, Int, String)

@external(erlang, "supernova_stress_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "supernova_stress_ffi", "mono_ms")
fn mono_ms() -> Int

@external(erlang, "supernova_stress_ffi", "rand_int")
fn rand_int(n: Int) -> Int

@external(erlang, "supernova_stress_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "supernova_stress_ffi", "dir_bytes")
fn dir_bytes(dir: String) -> Int

@external(erlang, "supernova_stress_ffi", "open_client")
fn open_client(workers: Int) -> Nil

@external(erlang, "supernova_harness_ffi", "free_port")
fn free_port() -> Int

@external(erlang, "supernova_cli_ffi", "get_args")
fn cli_args() -> List(String)

@external(erlang, "supernova_global_ffi", "global_put")
fn global_put_int(key: String, value: Int) -> Nil

@external(erlang, "supernova_global_ffi", "global_get")
fn global_get_int(key: String) -> Int

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

/// from..to, inclusive; empty when to < from.
@external(erlang, "lists", "seq")
fn seq_raw(from: Int, to: Int) -> List(Int)

fn seq(from: Int, to: Int) -> List(Int) {
  case to < from {
    True -> []
    False -> seq_raw(from, to)
  }
}
