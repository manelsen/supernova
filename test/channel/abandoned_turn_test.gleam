//// PRD-F, F-04: when the chat lane gives up on a turn
//// (`turn_hard_timeout_ms`), the turn and its tool calls stop. Before the
//// F-04 the lane only stopped waiting, and a stuck tool kept running for
//// its own limit (here, a minute).

import e2e/e2e_support as support
import exception
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import supernova/adapters/discord_router
import supernova/channel/channel_kit
import supernova/channel/registry
import supernova/config
import supernova/core/access/types as access_types
import supernova/core/closed_group/global as closed_group_global
import supernova/core/closed_group/pure as cg_pure
import supernova/core/session/supervisor as session_supervisor
import supernova/core/syscall/actor as syscall_actor
import supernova/core/tool_dispatch
import supernova/stress/fake_tools
import test_budget

fn cfg() -> config.Config {
  let base = support.channel_config()
  config.Config(
    ..base,
    access: support.access_config([], ["discord:456"]),
    capabilities: config.CapabilitiesConfig(
      ..base.capabilities,
      member: config.RoleCapabilitiesConfig(
        ..base.capabilities.member,
        allowed: list.append(base.capabilities.member.allowed, fake_tools.names),
      ),
    ),
  )
}

pub fn an_abandoned_turn_stops_its_tool_calls_test() {
  support.with_runtime_root(cfg(), fn(root) {
    support.seed_core(root, "discord:456", "Núcleo de teste.")
    fake_tools.enable()
    use <- exception.defer(fake_tools.disable)
    // The tools must really run here (the e2e gateway answers "tool-ok").
    let assert Ok(gateway) =
      syscall_actor.start_with_capabilities(
        None,
        Some(test_budget.unlimited()),
        None,
        dict.from_list([
          #(
            "member",
            cg_pure.manifest_for(cfg().capabilities, access_types.Member),
          ),
        ]),
        tool_dispatch.execute,
      )
    closed_group_global.set_gateway(gateway)
    let started = process.new_subject()
    fake_tools.observe(started)
    let assert Ok(session_sup) = session_supervisor.start()
    let recorder = process.new_subject()
    let assert Ok(channel_registry) =
      registry.start_channels_with_handler_and_hooks(
        support.channel_config(),
        // As in production (`routing.parallel`, the default): the handler
        // runs in the lane's own process, here the shell of the turn.
        discord_router.direct_handler(session_sup, support.mock_config()),
        channel_kit.StartHooks(
          ..channel_kit.no_start_hooks(),
          discord_events: [
            support.discord_message_event("[mock-trava] oi", "456"),
          ],
          discord_gateway: channel_kit.DiscordGatewayOff,
          disable_telegram_polling: True,
          outbound_records: Some(recorder),
          stream_timeout_ms: 300,
          turn_hard_timeout_ms: 1000,
        ),
      )
    use <- exception.defer(fn() { registry.stop_channels(channel_registry) })

    // The tool call starts and gets stuck (its own limit is a minute).
    let assert Ok(tool) = process.receive(started, 5000)
    // The lane gives up after 1 s; the call must not outlive that by much.
    wait_dead(tool, 3000) |> should.be_true
  })
}

fn wait_dead(pid: process.Pid, within: Int) -> Bool {
  case process.is_alive(pid), within <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(10)
      wait_dead(pid, within - 10)
    }
  }
}
