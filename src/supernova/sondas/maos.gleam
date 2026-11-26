//// The hands of each kind of probe (PRD-S, S-07, S22): its tools, how they
//// run, its folder in the computer, and how to let go of them.
////
//// - web: `buscar` (in Supernova) and the browser tools of a Playwright MCP
////   session in the computer;
//// - disco: the tools of a filesystem MCP session, confined to the
////   person's folder;
//// - codigo: the `computador` tool, through the gateway with the person's
////   role (only those who have the computer, S15).
////
//// If the conductor is killed (its time limit, a cancel, /esquecer), a
//// watcher closes the MCP session anyway (S-I5).

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import supernova/adapters/mcp/computer
import supernova/sondas/buscar
import supernova/sondas/condutor
import supernova/tools/computador

/// Open the hands of `kind` for the agent's probe `probe`. `gateway` runs a
/// tool call for the person through the syscall gateway.
pub fn open(
  pc: computer.Computer,
  kind: condutor.Kind,
  agent_id: String,
  probe: Int,
  gateway: fn(String, String) -> Result(String, String),
) -> Result(condutor.Hands, String) {
  let folder = computer.probe_folder(agent_id, probe)
  let keep = fn(text) {
    let _ = computer.keep_result(pc, agent_id, probe, text)
    Nil
  }
  case kind {
    condutor.Code ->
      Ok(
        condutor.Hands(
          tools: [computador.tool()],
          invoke: fn(name, args) {
            case name == computador.name {
              True -> gateway(name, args)
              False -> Error("ferramenta desconhecida: " <> name)
            }
          },
          folder: folder,
          keep: keep,
          close: fn() { Nil },
        ),
      )
    condutor.Web | condutor.Disk -> {
      let #(server, extra) = case kind {
        condutor.Web -> #(computer.Playwright, [buscar.tool()])
        _ -> #(computer.Filesystem, [])
      }
      let session_id =
        "sonda-"
        <> computer.person_hash(agent_id)
        <> "-"
        <> int.to_string(probe)
      use session <- result.try(computer.open(
        pc,
        session_id,
        server,
        agent_id,
        probe,
      ))
      case computer.tools(session) {
        Error(reason) -> {
          computer.close(session)
          Error(reason)
        }
        Ok(tools) -> {
          let close = fn() { computer.close(session) }
          watch(close)
          Ok(condutor.Hands(
            tools: list.append(extra, tools),
            invoke: fn(name, args) {
              case name == buscar.name && kind == condutor.Web {
                True -> buscar.execute(args)
                False -> computer.call(session, name, args)
              }
            },
            folder: folder,
            keep: keep,
            close: close,
          ))
        }
      }
    }
  }
}

/// Close the session when the calling process ends in any way but
/// normally: a conductor stopped at its limit never reaches its own close.
fn watch(close: fn() -> Nil) -> Nil {
  let owner = process.self()
  let _ =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(owner)
      let down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down.reason })
        |> process.selector_receive_forever
      case down {
        process.Normal -> Nil
        _ -> close()
      }
    })
  Nil
}
