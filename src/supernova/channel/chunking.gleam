//// Channel Chunking — channel-aware splitting for long outbound replies.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import supernova/channel/port

pub const discord_max_length = 2000

pub const telegram_max_length = 4096

pub const slack_max_length = 40_000

const continuation_marker = "(continued)\n"

const fence_marker = "```"

const reopen_fence_prefix = "```\n"

const close_fence_suffix = "\n```"

/// Prefix added to non-initial chunks to signal continuation.
pub fn continuation_prefix() -> String {
  continuation_marker
}

/// Split a reply into channel-sized chunks while preserving UX metadata.
pub fn split_reply(
  reply: port.ChannelReply,
  max_length: Int,
) -> List(port.ChannelReply) {
  let contents = split_text(reply.content, max_length)
  split_reply_contents(contents, reply, list.length(contents))
}

/// Split plain text into channel-sized parts.
pub fn split_text(text: String, max_length: Int) -> List(String) {
  case string.length(text) <= max_length {
    True -> [text]
    False -> split_text_loop(text, max_length, False, False)
  }
}

fn split_reply_contents(
  contents: List(String),
  reply: port.ChannelReply,
  total: Int,
) -> List(port.ChannelReply) {
  split_reply_contents_loop(contents, reply, total, 0)
}

fn split_reply_contents_loop(
  contents: List(String),
  reply: port.ChannelReply,
  total: Int,
  index: Int,
) -> List(port.ChannelReply) {
  case contents {
    [] -> []
    [content, ..rest] -> {
      let is_first = index == 0
      let is_last = index + 1 == total

      let chunk_reply =
        port.ChannelReply(
          channel_id: reply.channel_id,
          content: content,
          reply_to_id: case is_first {
            True -> reply.reply_to_id
            False -> None
          },
          thread_id: reply.thread_id,
          typing: case is_first {
            True -> reply.typing
            False -> False
          },
          edit_message_id: case is_first {
            True -> reply.edit_message_id
            False -> None
          },
          interactive: case is_last {
            True -> reply.interactive
            False -> None
          },
          media: case is_first {
            True -> reply.media
            False -> []
          },
        )

      [chunk_reply, ..split_reply_contents_loop(rest, reply, total, index + 1)]
    }
  }
}

fn split_text_loop(
  remaining: String,
  max_length: Int,
  has_previous: Bool,
  open_fence_before: Bool,
) -> List(String) {
  let prefix = chunk_prefix(has_previous, open_fence_before)

  case string.length(prefix) + string.length(remaining) <= max_length {
    True -> [prefix <> remaining]
    False -> {
      let available = available_body_length(max_length, prefix)
      let split_point = resolve_split_point(remaining, available)
      let body =
        remaining
        |> string.slice(0, split_point)
        |> trim_trailing_spaces
      let rest =
        remaining
        |> string.drop_start(split_point)
        |> trim_leading_spaces
      let open_fence_after = toggle_fence_state(open_fence_before, body)
      let suffix = case open_fence_after {
        True -> close_fence_suffix
        False -> ""
      }

      [
        prefix <> body <> suffix,
        ..split_text_loop(rest, max_length, True, open_fence_after)
      ]
    }
  }
}

fn chunk_prefix(has_previous: Bool, open_fence_before: Bool) -> String {
  case has_previous, open_fence_before {
    False, _ -> ""
    True, False -> continuation_marker
    True, True -> continuation_marker <> reopen_fence_prefix
  }
}

fn available_body_length(max_length: Int, prefix: String) -> Int {
  let raw_available =
    max_length - string.length(prefix) - string.length(close_fence_suffix)

  case raw_available < 1 {
    True -> 1
    False -> raw_available
  }
}

fn resolve_split_point(text: String, max_length: Int) -> Int {
  let slice = string.slice(text, 0, max_length)

  case find_split_point(slice) {
    Some(AtNewline(point)) -> point
    Some(AtSpace(point)) -> point
    None -> max_length
  }
}

type SplitPoint {
  AtNewline(Int)
  AtSpace(Int)
}

fn find_split_point(text: String) -> Option(SplitPoint) {
  let chars = string.to_graphemes(text)
  find_split_point_loop(chars, 0, None, None)
}

fn find_split_point_loop(
  chars: List(String),
  index: Int,
  last_newline: Option(Int),
  last_space: Option(Int),
) -> Option(SplitPoint) {
  case chars {
    [] ->
      case last_newline {
        Some(point) -> Some(AtNewline(point))
        None ->
          case last_space {
            Some(point) -> Some(AtSpace(point))
            None -> None
          }
      }
    [char, ..rest] -> {
      let next_newline = case char {
        "\n" -> Some(index + 1)
        _ -> last_newline
      }

      let next_space = case char {
        " " -> Some(index)
        _ -> last_space
      }

      find_split_point_loop(rest, index + 1, next_newline, next_space)
    }
  }
}

fn toggle_fence_state(open_fence_before: Bool, body: String) -> Bool {
  let occurrence_count = fence_count(body)
  let toggles = occurrence_count % 2 == 1

  case open_fence_before, toggles {
    True, True -> False
    False, True -> True
    current, False -> current
  }
}

fn fence_count(text: String) -> Int {
  case string.split(text, fence_marker) {
    [] -> 0
    parts -> list.length(parts) - 1
  }
}

fn trim_leading_spaces(text: String) -> String {
  case string.starts_with(text, " ") {
    True -> trim_leading_spaces(string.drop_start(text, 1))
    False -> text
  }
}

fn trim_trailing_spaces(text: String) -> String {
  case string.ends_with(text, " ") {
    True -> trim_trailing_spaces(string.drop_end(text, 1))
    False -> text
  }
}
