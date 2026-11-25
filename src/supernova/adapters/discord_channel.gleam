//// Discord runtime: gateway bridge, event and interaction conversion,
//// sending, streaming and message components.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/adapters/discord_events
import supernova/adapters/discord_gateway
import supernova/adapters/discord_rest
import supernova/channel/channel_kit
import supernova/channel/chunking
import supernova/channel/health as channel_health
import supernova/channel/port
import supernova/config
import supernova/core/closed_group/commands as closed_group_commands
import supernova/core/closed_group/suggestions
import supernova/infra/safe_io

type DiscordBridgeControl {
  StopDiscordBridge
}

type DiscordBridgeReady {
  DiscordBridgeReady(
    events: process.Subject(discord_gateway.DiscordEvent),
    control: process.Subject(DiscordBridgeControl),
  )
}

type DiscordBridge {
  DiscordBridge(
    events: process.Subject(discord_gateway.DiscordEvent),
    control: process.Subject(DiscordBridgeControl),
    done: process.Subject(Nil),
  )
}

pub fn start_discord_channel(
  discord_cfg: config.DiscordConfig,
  handler: port.ChannelHandler,
  hooks: channel_kit.StartHooks,
  health: channel_health.ChannelHealth,
) -> Result(#(port.ChannelAdapter, channel_kit.StreamSendFn), String) {
  case discord_cfg.token {
    Some(token) -> {
      let report = fn(status) {
        channel_health.report(
          health,
          "discord",
          status_outcome(status),
          channel_health.now_ms(),
        )
      }
      let gateway_config =
        discord_gateway.GatewayConfig(
          ..discord_gateway.default_config(token),
          intents: discord_gateway.message_content_intents(),
          app_id: discord_cfg.app_id,
          on_status: report,
        )
      let gateway_config = case hooks.discord_gateway {
        channel_kit.DiscordGatewayAt(gateway_url: url, ..) ->
          discord_gateway.GatewayConfig(..gateway_config, url: url)
        _ -> gateway_config
      }
      let rest_config = case hooks.discord_gateway {
        channel_kit.DiscordGatewayAt(api_url: api_url, ..) ->
          discord_rest.new_config(token) |> discord_rest.with_base_url(api_url)
        _ -> discord_rest.new_config(token)
      }

      use gateway <- result.try(
        discord_gateway.start(gateway_config)
        |> result.map_error(fn(_) { "failed to start gateway actor" }),
      )

      // Ready only after READY: until then the channel reports itself as
      // connecting. A silent gateway (no heartbeat ACK) stops counting as
      // ready after `max_silence_ms`.
      case hooks.discord_gateway {
        channel_kit.DiscordGatewayOff ->
          channel_health.started(
            health,
            "discord",
            None,
            channel_health.now_ms(),
          )
        _ -> {
          channel_health.started(
            health,
            "discord",
            Some(max_silence_ms),
            channel_health.now_ms(),
          )
          report(discord_gateway.Connecting)
        }
      }

      use _ <- result.try(case hooks.discord_gateway {
        channel_kit.DiscordGatewayOff -> Ok(Nil)
        _ ->
          discord_gateway.connect(gateway)
          |> result.map_error(fn(error) {
            "failed to connect gateway: "
            <> discord_gateway.error_to_string(error)
          })
      })

      use rest_client <- result.try(
        discord_rest.start(rest_config)
        |> result.map_error(fn(_) { "failed to start REST client" }),
      )

      let send_fn = discord_send(rest_client, hooks)
      let stream_send_fn = discord_stream_send(rest_client, hooks)

      // Recorded test runs never reach Discord.
      let acknowledge = case hooks.outbound_records {
        Some(_) -> fn(_interaction) { Nil }
        None -> fn(interaction) {
          acknowledge_interaction(
            rest_config,
            interaction,
            suggestions.for_sender,
          )
        }
      }
      let on_ready = case hooks.outbound_records {
        Some(_) -> fn(_ready) { Nil }
        None -> fn(ready: discord_gateway.ReadyData) {
          register_slash_commands(
            rest_config,
            option.unwrap(discord_cfg.app_id, ready.user.id),
            discord_cfg.guild_id,
          )
        }
      }

      use bridge <- result.try(start_discord_bridge(
        handler,
        send_fn,
        stream_send_fn,
        acknowledge,
        on_ready,
        hooks.registry_id,
        hooks.turn_hard_timeout_ms,
      ))

      let subscription_id = discord_gateway.subscribe(gateway, bridge.events)

      hooks.discord_events
      |> list.each(fn(event) { process.send(bridge.events, event) })

      Ok(#(
        port.ChannelAdapter(
          name: "discord",
          send: send_fn,
          stop_ingress: fn() {
            let _ = discord_gateway.unsubscribe(gateway, subscription_id)
            Nil
          },
          stop: fn() {
            let _ = discord_gateway.unsubscribe(gateway, subscription_id)
            stop_discord_bridge(bridge)
            discord_rest.stop(rest_client)
            discord_gateway.stop(gateway)
          },
        ),
        stream_send_fn,
      ))
    }
    None -> Error("enabled but no token configured")
  }
}

/// Two missed heartbeats (Discord asks for one about every 41 s).
const max_silence_ms = 120_000

/// How a gateway status reads as channel health.
pub fn status_outcome(
  status: discord_gateway.ConnectionStatus,
) -> Result(Nil, String) {
  case status {
    discord_gateway.Connected -> Ok(Nil)
    discord_gateway.ConnectionError(reason) -> Error(reason)
    other -> Error("gateway " <> discord_gateway.status_to_string(other))
  }
}

fn start_discord_bridge(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: channel_kit.StreamSendFn,
  acknowledge: fn(discord_events.Interaction) -> Nil,
  on_ready: fn(discord_gateway.ReadyData) -> Nil,
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Result(DiscordBridge, String) {
  let ready = process.new_subject()
  let done = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      let control = process.new_subject()
      process.send(ready, DiscordBridgeReady(events: events, control: control))
      discord_bridge_loop(
        handler,
        send_fn,
        stream_send_fn,
        acknowledge,
        on_ready,
        events,
        control,
        done,
        registry_id,
        turn_hard_timeout_ms,
      )
    })

  case process.receive(ready, within: 1000) {
    Ok(DiscordBridgeReady(events, control)) ->
      Ok(DiscordBridge(events: events, control: control, done: done))
    Error(_) -> Error("failed to start discord inbound bridge")
  }
}

fn discord_bridge_loop(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: channel_kit.StreamSendFn,
  acknowledge: fn(discord_events.Interaction) -> Nil,
  on_ready: fn(discord_gateway.ReadyData) -> Nil,
  events: process.Subject(discord_gateway.DiscordEvent),
  control: process.Subject(DiscordBridgeControl),
  done: process.Subject(Nil),
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  case process.receive(control, within: 0) {
    Ok(StopDiscordBridge) -> process.send(done, Nil)
    Error(_) -> {
      case process.receive(events, within: 100) {
        Ok(event) -> {
          dispatch_discord_event(
            handler,
            send_fn,
            stream_send_fn,
            acknowledge,
            on_ready,
            event,
            registry_id,
            turn_hard_timeout_ms,
          )
          discord_bridge_loop(
            handler,
            send_fn,
            stream_send_fn,
            acknowledge,
            on_ready,
            events,
            control,
            done,
            registry_id,
            turn_hard_timeout_ms,
          )
        }
        Error(_) ->
          discord_bridge_loop(
            handler,
            send_fn,
            stream_send_fn,
            acknowledge,
            on_ready,
            events,
            control,
            done,
            registry_id,
            turn_hard_timeout_ms,
          )
      }
    }
  }
}

fn stop_discord_bridge(bridge: DiscordBridge) -> Nil {
  process.send(bridge.control, StopDiscordBridge)
  let _ = process.receive(bridge.done, within: 1000)
  Nil
}

fn dispatch_discord_event(
  handler: port.ChannelHandler,
  send_fn: fn(port.ChannelReply) -> Result(Nil, port.ChannelError),
  stream_send_fn: channel_kit.StreamSendFn,
  acknowledge: fn(discord_events.Interaction) -> Nil,
  on_ready: fn(discord_gateway.ReadyData) -> Nil,
  event: discord_gateway.DiscordEvent,
  registry_id: String,
  turn_hard_timeout_ms: Int,
) -> Nil {
  case event {
    discord_gateway.Ready(ready) -> on_ready(ready)
    discord_gateway.MessageCreate(data) ->
      case discord_events.parse_event("MESSAGE_CREATE", data) {
        discord_events.EventMessageCreate(message) ->
          channel_kit.dispatch_inbound(
            handler,
            send_fn,
            stream_send_fn,
            port.inbound_message(discord_message_to_port(message)),
            registry_id,
            turn_hard_timeout_ms,
          )
        _ -> Nil
      }
    discord_gateway.RawEvent("INTERACTION_CREATE", data) ->
      case discord_events.parse_event("INTERACTION_CREATE", data) {
        discord_events.EventInteractionCreate(interaction) -> {
          // The answer to Discord goes first, before any turn: it has 3 s.
          acknowledge(interaction)
          case discord_interaction_to_inbound(interaction) {
            Ok(inbound) ->
              channel_kit.dispatch_inbound(
                handler,
                send_fn,
                stream_send_fn,
                inbound,
                registry_id,
                turn_hard_timeout_ms,
              )
            Error(_) -> Nil
          }
        }
        _ -> Nil
      }
    _ -> Nil
  }
}

/// Answers Discord for an interaction, in a process of its own so that a slow
/// answer never holds the next event.
fn acknowledge_interaction(
  config: discord_rest.RestClientConfig,
  interaction: discord_events.Interaction,
  suggest: fn(String, String, String, String, String) -> List(#(String, String)),
) -> Nil {
  let answer = case autocomplete_request(interaction) {
    Some(#(chat_id, user_id, command, typed)) ->
      Some(fn() {
        discord_rest.autocomplete_response(suggest(
          "discord",
          chat_id,
          user_id,
          command,
          typed,
        ))
      })
    None ->
      interaction_answer(interaction)
      |> option.map(fn(body) { fn() { body } })
  }
  case answer {
    None -> Nil
    Some(body_fn) -> {
      let _ =
        process.spawn_unlinked(fn() {
          let body = body_fn()
          case
            discord_rest.interaction_callback(
              config,
              interaction.id,
              interaction.token,
              body,
            )
          {
            Ok(Nil) -> Nil
            Error(error) ->
              safe_io.println(
                "discord: interaction answer failed: " <> string.inspect(error),
              )
          }
        })
      Nil
    }
  }
}

/// For an autocomplete interaction: the chat, the person, the command and
/// what is typed in its focused option.
pub fn autocomplete_request(
  interaction: discord_events.Interaction,
) -> Option(#(String, String, String, String)) {
  case interaction.interaction_type, interaction.data, interaction.channel_id {
    discord_events.ApplicationCommandAutocomplete,
      Some(discord_events.ApplicationCommandData(name:, options:, ..)),
      Some(raw_channel_id)
    -> {
      let #(user_id, _, _) = discord_interaction_sender(interaction)
      let typed =
        options
        |> list.find(fn(option) { option.focused == Some(True) })
        |> result.map(fn(option) {
          case option.value {
            Some(discord_events.StringValue(text)) -> text
            _ -> ""
          }
        })
        |> result.unwrap("")
      Some(#(
        discord_chat_id(raw_channel_id, interaction.guild_id),
        user_id,
        name,
        typed,
      ))
    }
    _, _, _ -> None
  }
}

/// Registers the member command list globally (D2): it reaches private
/// chats and every server. A configured server gets an empty list, which
/// removes old copies there: a command registered in both places shows
/// twice in Discord.
fn register_slash_commands(
  config: discord_rest.RestClientConfig,
  application_id: String,
  guild_id: Option(String),
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let #(valid, invalid) =
        slash_commands()
        |> list.partition(discord_rest.valid_slash_command)
      list.each(invalid, fn(command) {
        safe_io.println("discord: command skipped, invalid: " <> command.name)
      })
      report_registration(
        "global",
        discord_rest.overwrite_slash_commands(
          config,
          application_id,
          None,
          discord_rest.slash_commands_body(valid),
        ),
      )
      case guild_id {
        Some(guild) ->
          report_registration(
            "server " <> guild,
            discord_rest.overwrite_slash_commands(
              config,
              application_id,
              Some(guild),
              "[]",
            ),
          )
        None -> Nil
      }
    })
  Nil
}

/// The member commands, from the single list `/help` and Telegram use.
pub fn slash_commands() -> List(discord_rest.SlashCommand) {
  closed_group_commands.for_role(False)
  |> list.map(fn(command) {
    discord_rest.SlashCommand(
      name: command.name,
      description: command.description,
      takes_arguments: command.takes_arguments,
    )
  })
}

fn report_registration(
  scope: String,
  outcome: Result(Nil, discord_rest.DiscordRestError),
) -> Nil {
  case outcome {
    Ok(Nil) -> Nil
    Error(error) ->
      safe_io.println(
        "discord: command registration ("
        <> scope
        <> ") failed: "
        <> string.inspect(error),
      )
  }
}

/// What Discord is told right away (PRD-D, 6.2): a button or menu is
/// acknowledged and its message edited later; a slash command is shown in
/// the channel, and the reply follows as a message.
pub fn interaction_answer(
  interaction: discord_events.Interaction,
) -> Option(String) {
  case interaction.interaction_type, interaction.data {
    discord_events.MessageComponent, _ ->
      Some(discord_rest.deferred_update_response())
    discord_events.ApplicationCommand,
      Some(discord_events.ApplicationCommandData(name:, options:, ..))
    ->
      Some(
        discord_rest.command_echo_response(discord_slash_command_text(
          name,
          options,
        )),
      )
    _, _ -> None
  }
}

fn discord_message_to_port(
  message: discord_events.Message,
) -> port.ChannelMessage {
  port.ChannelMessage(
    id: message.id,
    channel: "discord",
    channel_id: discord_chat_id(message.channel_id, message.guild_id),
    user_id: message.author.id,
    username: message.author.username,
    content: message.content,
    is_bot: discord_is_bot(message.author.bot),
    reply_to_id: discord_reply_to_id(message.message_reference),
  )
}

fn discord_chat_id(channel_id: String, guild_id: Option(String)) -> String {
  case guild_id {
    Some(guild) -> channel_id <> "@guild:" <> guild
    None -> "dm:" <> channel_id
  }
}

fn discord_is_bot(bot: Option(Bool)) -> Bool {
  case bot {
    Some(is_bot) -> is_bot
    None -> False
  }
}

fn discord_interaction_to_inbound(
  interaction: discord_events.Interaction,
) -> Result(port.ChannelInbound, port.ChannelError) {
  use raw_channel_id <- result.try(require_discord_channel_id(
    interaction.channel_id,
  ))
  let channel_id = discord_chat_id(raw_channel_id, interaction.guild_id)
  let #(user_id, username, is_bot) = discord_interaction_sender(interaction)

  case interaction.interaction_type, interaction.data {
    discord_events.ApplicationCommand, Some(command_data) ->
      discord_command_interaction_to_inbound(
        interaction,
        channel_id,
        user_id,
        username,
        is_bot,
        command_data,
      )
    discord_events.ApplicationCommandAutocomplete, _ ->
      Error(port.Ignored("discord autocomplete interaction ignored"))
    discord_events.MessageComponent, Some(component_data) ->
      discord_component_interaction_to_inbound(
        interaction,
        channel_id,
        user_id,
        username,
        is_bot,
        component_data,
      )
    _, _ -> Error(port.Ignored("unsupported discord interaction"))
  }
}

fn require_discord_channel_id(
  channel_id: Option(String),
) -> Result(String, port.ChannelError) {
  case channel_id {
    Some(value) -> Ok(value)
    None -> Error(port.Ignored("discord interaction missing channel_id"))
  }
}

fn discord_interaction_sender(
  interaction: discord_events.Interaction,
) -> #(String, String, Bool) {
  case interaction.member {
    Some(member) ->
      case member.user {
        Some(user) -> #(user.id, user.username, discord_is_bot(user.bot))
        None -> discord_optional_user_to_sender(interaction.user)
      }
    None -> discord_optional_user_to_sender(interaction.user)
  }
}

fn discord_optional_user_to_sender(
  user: Option(discord_events.User),
) -> #(String, String, Bool) {
  case user {
    Some(value) -> #(value.id, value.username, discord_is_bot(value.bot))
    // No person on the interaction: `discord:unknown` is never authorized.
    None -> #("unknown", "unknown", False)
  }
}

fn discord_command_interaction_to_inbound(
  interaction: discord_events.Interaction,
  channel_id: String,
  user_id: String,
  username: String,
  is_bot: Bool,
  command_data: discord_events.InteractionData,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case command_data {
    discord_events.ApplicationCommandData(name:, options:, ..) ->
      Ok(
        port.inbound_message(port.ChannelMessage(
          id: interaction.id,
          channel: "discord",
          channel_id: channel_id,
          user_id: user_id,
          username: username,
          content: discord_slash_command_text(name, options),
          is_bot: is_bot,
          reply_to_id: None,
        )),
      )
    _ -> Error(port.Ignored("discord interaction missing command data"))
  }
}

fn discord_slash_command_text(
  name: String,
  options: List(discord_events.ApplicationCommandOption),
) -> String {
  case options {
    [] -> "/" <> name
    _ ->
      "/"
      <> name
      <> " "
      <> string.join(list.map(options, discord_command_option_to_text), " ")
  }
}

fn discord_command_option_to_text(
  option: discord_events.ApplicationCommandOption,
) -> String {
  let discord_events.ApplicationCommandOption(name:, value:, options:, ..) =
    option

  case value, name {
    // The free-text option every command with arguments has (D6).
    Some(option_value), "args" -> discord_option_value_to_text(option_value)
    Some(option_value), _ ->
      name <> ":" <> discord_option_value_to_text(option_value)
    None, _ ->
      case options {
        [] -> name
        _ ->
          name
          <> " "
          <> string.join(list.map(options, discord_command_option_to_text), " ")
      }
  }
}

fn discord_option_value_to_text(
  value: discord_events.CommandOptionValue,
) -> String {
  case value {
    discord_events.StringValue(text) -> text
    discord_events.IntValue(number) -> int.to_string(number)
    discord_events.BoolValue(flag) ->
      case flag {
        True -> "true"
        False -> "false"
      }
    discord_events.UserValue(id) -> id
    discord_events.ChannelValue(id) -> id
    discord_events.RoleValue(id) -> id
  }
}

fn discord_component_interaction_to_inbound(
  interaction: discord_events.Interaction,
  channel_id: String,
  user_id: String,
  username: String,
  is_bot: Bool,
  component_data: discord_events.InteractionData,
) -> Result(port.ChannelInbound, port.ChannelError) {
  case component_data {
    discord_events.MessageComponentData(custom_id:, values:, ..) ->
      Ok(
        port.inbound_interaction(port.ChannelInteractionMessage(
          channel: "discord",
          channel_id: channel_id,
          user_id: user_id,
          username: username,
          is_bot: is_bot,
          event: port.ChannelInteractionEvent(
            id: interaction.id,
            action_id: custom_id,
            values: discord_component_values(values),
            source_message_id: interaction.message_id,
          ),
        )),
      )
    _ -> Error(port.Ignored("discord interaction missing component data"))
  }
}

fn discord_component_values(values: Option(List(String))) -> List(String) {
  case values {
    Some(selected) -> selected
    None -> []
  }
}

fn discord_reply_to_id(
  reference: Option(discord_events.MessageReference),
) -> Option(String) {
  case reference {
    Some(message_reference) -> message_reference.message_id
    None -> None
  }
}

fn discord_send(
  rest_client: discord_rest.RestClient,
  hooks: channel_kit.StartHooks,
) -> fn(port.ChannelReply) -> Result(Nil, port.ChannelError) {
  fn(reply: port.ChannelReply) {
    let replies = chunking.split_reply(reply, chunking.discord_max_length)

    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_reply_for_test(recorder, "discord", replies)
      None ->
        channel_kit.send_chunked_replies(replies, fn(part) {
          // An answer to a button edits the message that held it (D5).
          let sent = case part.edit_message_id {
            Some(message_id) ->
              discord_edit_message(rest_client, part, message_id)
            None -> discord_send_message(rest_client, part)
          }
          result.replace(sent, Nil)
        })
    }
  }
}

fn discord_stream_send(
  rest_client: discord_rest.RestClient,
  hooks: channel_kit.StartHooks,
) -> channel_kit.StreamSendFn {
  fn(
    base_reply: port.ChannelReply,
    events: process.Subject(port.ChannelStreamEvent),
  ) {
    let keepalive_ms =
      channel_kit.normalize_typing_keepalive_ms(hooks.typing_keepalive_ms)
    case hooks.outbound_records {
      Some(recorder) ->
        channel_kit.record_stream_for_test(
          recorder,
          "discord",
          base_reply,
          events,
          keepalive_ms,
          hooks.stream_timeout_ms,
        )
      None ->
        stream_discord_reply(rest_client, base_reply, events, keepalive_ms)
    }
  }
}

fn discord_send_message(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(discord_rest.SentMessage, port.ChannelError) {
  use target_channel <- result.try(discord_delivery_channel(rest_client, reply))
  let options = discord_options_for_reply(reply)

  let typing_result = case reply.typing {
    True -> discord_rest.trigger_typing_indicator(rest_client, target_channel)
    False -> Ok(Nil)
  }

  case typing_result {
    Error(error) -> Error(map_discord_send_error(error))
    Ok(_) ->
      case
        discord_rest.send_message_with_options(
          rest_client,
          target_channel,
          options,
        )
      {
        Ok(message) -> Ok(message)
        Error(error) -> Error(map_discord_send_error(error))
      }
  }
}

/// Alert DMs carry `open-dm:<user_id>`; ordinary replies carry a channel id.
fn discord_delivery_channel(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(String, port.ChannelError) {
  case string.starts_with(reply.channel_id, "open-dm:") {
    True ->
      discord_rest.open_dm(rest_client, string.drop_start(reply.channel_id, 8))
      |> result.map_error(map_discord_send_error)
    False -> Ok(discord_target_channel(reply))
  }
}

fn discord_edit_message(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
  message_id: String,
) -> Result(discord_rest.SentMessage, port.ChannelError) {
  let options = discord_options_for_reply(reply)
  let target_channel = discord_target_channel(reply)

  case
    discord_rest.edit_message_with_options(
      rest_client,
      target_channel,
      message_id,
      options,
    )
  {
    Ok(message) -> Ok(message)
    Error(error) -> Error(map_discord_send_error(error))
  }
}

fn discord_options_for_reply(
  reply: port.ChannelReply,
) -> discord_rest.SendMessageOptions {
  let options = case reply.reply_to_id {
    Some(message_id) ->
      discord_rest.new_message_options()
      |> discord_rest.with_content(reply.content)
      |> discord_rest.with_message_reference(discord_rest.reply_to(message_id))
    None ->
      discord_rest.new_message_options()
      |> discord_rest.with_content(reply.content)
  }

  case reply.interactive {
    Some(interactive) -> {
      let components = discord_components(interactive)
      case components {
        [] -> options
        _ -> discord_rest.with_components(options, components)
      }
    }
    None -> options
  }
}

fn discord_target_channel(reply: port.ChannelReply) -> String {
  case reply.thread_id {
    Some(thread_id) -> thread_id
    None -> discord_route_channel(reply.channel_id)
  }
}

/// Strip policy-only routing annotations before calling Discord.
fn discord_route_channel(channel_id: String) -> String {
  case string.starts_with(channel_id, "dm:") {
    True -> string.drop_start(channel_id, 3)
    False ->
      case string.split(channel_id, "@guild:") {
        [target, _guild] -> target
        _ -> channel_id
      }
  }
}

fn discord_trigger_typing(
  rest_client: discord_rest.RestClient,
  reply: port.ChannelReply,
) -> Result(Nil, port.ChannelError) {
  let target_channel = discord_target_channel(reply)

  case discord_rest.trigger_typing_indicator(rest_client, target_channel) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(map_discord_send_error(error))
  }
}

fn stream_discord_reply(
  rest_client: discord_rest.RestClient,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let placeholder =
    port.ChannelReply(..base_reply, content: "Thinking...", typing: True)

  use placeholder_message <- result.try(discord_send_message(
    rest_client,
    placeholder,
  ))

  consume_discord_stream_events(
    rest_client,
    base_reply,
    events,
    placeholder_message.id,
    "",
    channel_kit.stream_timeout_ms,
    keepalive_ms,
  )
}

fn consume_discord_stream_events(
  rest_client: discord_rest.RestClient,
  base_reply: port.ChannelReply,
  events: process.Subject(port.ChannelStreamEvent),
  message_id: String,
  last_content: String,
  remaining_ms: Int,
  keepalive_ms: Int,
) -> Result(Nil, port.ChannelError) {
  let wait_ms = channel_kit.stream_wait_ms(remaining_ms, keepalive_ms)

  case process.receive(events, within: wait_ms) {
    Ok(port.StreamUpdate(reply)) ->
      case channel_kit.stream_update_fits("discord", reply.content) {
        True -> {
          let next_reply =
            port.ChannelReply(..reply, edit_message_id: Some(message_id))
          use _ <- result.try(discord_edit_message(
            rest_client,
            next_reply,
            message_id,
          ))
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            reply.content,
            remaining_ms,
            keepalive_ms,
          )
        }
        False ->
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms,
            keepalive_ms,
          )
      }
    Ok(port.StreamComplete(reply)) ->
      case reply.content == last_content {
        True -> Ok(Nil)
        False ->
          channel_kit.finish_stream_in_parts(
            reply,
            message_id,
            chunking.discord_max_length,
            fn(part) {
              case part.edit_message_id {
                Some(id) ->
                  discord_edit_message(rest_client, part, id)
                  |> result.map(fn(_) { Nil })
                None ->
                  discord_send_message(rest_client, part)
                  |> result.map(fn(_) { Nil })
              }
            },
          )
      }
    Ok(port.StreamFailure(error)) -> Error(error)
    Error(_) ->
      case remaining_ms <= wait_ms {
        True -> {
          let timeout_reply =
            port.ChannelReply(
              ..base_reply,
              content: "Streaming timed out",
              edit_message_id: Some(message_id),
              typing: False,
            )
          let _ = discord_edit_message(rest_client, timeout_reply, message_id)
          Error(port.SendFailed("stream timed out"))
        }
        False -> {
          use _ <- result.try(discord_trigger_typing(rest_client, base_reply))
          consume_discord_stream_events(
            rest_client,
            base_reply,
            events,
            message_id,
            last_content,
            remaining_ms - wait_ms,
            keepalive_ms,
          )
        }
      }
  }
}

fn discord_components(
  interactive: port.ChannelInteractiveReply,
) -> List(discord_rest.MessageComponentRow) {
  list.fold(interactive.blocks, [], fn(rows, block) {
    case block {
      port.InteractionText(_) -> rows
      port.InteractionButtons(buttons) -> [
        discord_rest.action_row(list.map(buttons, discord_button_component)),
        ..rows
      ]
      port.InteractionSelect(action_id, placeholder, options) -> {
        let select =
          discord_rest.string_select(
            action_id,
            list.map(options, discord_select_option),
          )

        let select = case placeholder {
          Some(text) -> discord_rest.select_with_placeholder(select, text)
          None -> select
        }

        [discord_rest.action_row([select]), ..rows]
      }
    }
  })
  |> list.reverse
}

fn discord_button_component(
  button: port.ChannelButton,
) -> discord_rest.MessageComponent {
  let action_id = port.button_action_id(button)
  let label = port.button_label(button)

  case port.button_style(button) {
    port.ButtonPrimary -> discord_rest.primary_button(action_id, label)
    port.ButtonSecondary -> discord_rest.secondary_button(action_id, label)
    port.ButtonSuccess -> discord_rest.success_button(action_id, label)
    port.ButtonDanger -> discord_rest.danger_button(action_id, label)
  }
}

fn discord_select_option(
  option: port.ChannelSelectOption,
) -> discord_rest.MessageSelectOption {
  discord_rest.select_option(
    port.select_option_label(option),
    port.select_option_value(option),
  )
}

fn map_discord_send_error(
  error: discord_rest.DiscordRestError,
) -> port.ChannelError {
  case error {
    discord_rest.RateLimited(retry_after_ms) ->
      port.RateLimited(retry_after_seconds: retry_after_ms / 1000)
    discord_rest.BadRequest(message) -> port.SendFailed(message)
    discord_rest.Forbidden(message) -> port.SendFailed(message)
    discord_rest.NotFound(message) -> port.SendFailed(message)
    discord_rest.InternalError(message) -> port.SendFailed(message)
    discord_rest.UnknownError(_, body) -> port.SendFailed(body)
    discord_rest.HttpError(message) -> port.SendFailed(message)
    discord_rest.JsonError(message) -> port.SendFailed(message)
    discord_rest.Unauthorized -> port.NotConnected
  }
}
