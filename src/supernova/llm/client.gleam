//// LLM Client — dispatcher for LLM provider calls.
////
//// Routes chat completion requests to the appropriate provider based on config.
//// Includes a mock provider for testing.
////
//// ## Usage
////
//// ```gleam
//// let config = provider.ProviderConfig(name: "openai", ...)
//// let result = client.chat(messages, config, [])
//// ```

import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import supernova/llm/provider
import supernova/llm/providers/anthropic
import supernova/llm/providers/minimax
import supernova/llm/providers/ollama
import supernova/llm/providers/openai
import supernova/llm/providers/openai_compatible
import supernova/llm/providers/opencode_zen
import supernova/llm/providers/openrouter
import supernova/llm/providers/zhipu

type MockToolMode {
  MockToolDefault
  /// `[mock-busca termos]`: call buscar_conversa with those terms.
  MockToolBusca(terms: String)
  /// `[mock-sem-ferramenta]`: answer without calling any tool.
  MockToolNone
  MockToolLoopSuccess
  MockToolLoopError
  MockToolWriteSelf
  /// `[mock-lenta N]`, `[mock-trava]`, `[mock-explode]`: call the test tool
  /// (PRD-F, F-01; on only in stress runs and tests).
  MockToolFake(name: String, ms: Int)
  /// `[mock-varias N]`: N calls of `lenta` in one round, the first the
  /// slowest, so the results come back out of order.
  MockToolMany(count: Int)
  /// `[mock-tarefa ferramenta N]`: start that tool in the background with
  /// `{"ms": N}` (PRD-F, F-06).
  MockToolTask(tool: String, ms: Int)
  /// `[mock-sonda tipo instruções]`: send a probe (PRD-S, S-07).
  MockToolProbe(kind: String, instructions: String)
}

// ============================================================================
// Public API
// ============================================================================

/// Mistral's OpenAI-compatible chat endpoint. It also serves DeepSeek models
/// (`deepseek-v4-1-flash-1017`), the agents' model after the first battery.
pub const mistral_chat_url = "https://api.mistral.ai/v1/chat/completions"

/// Send a chat completion request.
///
/// Dispatches to the provider specified in config.
/// Returns a ChatResponse on success or LLMError on failure.
pub fn chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case config.name {
    "mock" -> mock_chat(messages, config, tools)
    "openai" -> openai.chat(messages, config, tools)
    "anthropic" -> anthropic.chat(messages, config, tools)
    "opencode_zen" -> opencode_zen.chat(messages, config, tools)
    "openrouter" -> openrouter.chat(messages, config, tools)
    "zhipu" -> zhipu.chat(messages, config, tools)
    "zhipu_coding" -> zhipu.chat_coding(messages, config, tools)
    "minimax" -> minimax.chat(messages, config, tools)
    "ollama" -> ollama.chat(messages, config, tools)
    "zai" ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: "https://api.z.ai/api/paas/v4/chat/completions",
        extra_headers: [],
      )
    "zai_coding" ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: "https://api.z.ai/api/paas/v4/chat/completions",
        extra_headers: [],
      )
    "mistral" ->
      openai_compatible.chat(
        messages,
        config,
        tools,
        base_url: option.unwrap(config.base_url, mistral_chat_url),
        extra_headers: [],
      )
    _ -> Error(provider.ProviderNotFound(name: config.name))
  }
}

// ============================================================================
// Mock Provider (for testing)
// ============================================================================

@external(erlang, "supernova_mock_ffi", "network_fail_once")
fn mock_network_fail_once(key: String) -> Bool

@external(erlang, "supernova_mock_ffi", "record_prompt")
fn record_prompt(prompt: String) -> Nil

fn mock_delay(content: String) -> Option(Int) {
  case string.split_once(content, "[mock-delay-ms=") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]") {
        Ok(#(digits, _)) -> option.from_result(int.parse(digits))
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

/// Mock chat completion — returns a canned response.
fn mock_chat(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  record_prompt(
    messages
    |> list.map(fn(message) { message.content })
    |> string.join("\n---\n"),
  )
  case latest_user_content(messages) {
    Some(content) -> {
      case string.contains(content, "[mock-crash]") {
        True -> panic as "simulated executor crash"
        False -> Nil
      }
      // `[mock-delay-ms=N]`: the call takes N ms, as a slow model would. The
      // streaming mock had it; the gated path (closed group) calls this one.
      case mock_delay(content) {
        Some(ms) -> process.sleep(ms)
        None -> Nil
      }
      case mock_forced_error(content) {
        Some(error) -> Error(error)
        None -> mock_chat_success(messages, config, tools)
      }
    }
    None -> mock_chat_success(messages, config, tools)
  }
}

fn mock_chat_success(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  // Tests see what reached the model: images in the person's message.
  let seen_images =
    messages
    |> list.filter(fn(message) { message.role == "user" })
    |> list.last
    |> result.map(fn(message) { list.length(message.images) })
    |> result.unwrap(0)
  case seen_images > 0 {
    True ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "vi " <> int.to_string(seen_images) <> " imagem(ns)",
        tool_calls: None,
        reasoning_content: None,
      ))
    False -> mock_chat_answer(messages, config, tools)
  }
}

fn mock_chat_answer(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  case special_mock_response(messages, config) {
    Some(content) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: content,
        tool_calls: None,
        reasoning_content: None,
      ))
    None -> mock_chat_default(messages, config, tools)
  }
}

fn mock_forced_error(content: String) -> Option(provider.LLMError) {
  case string.contains(content, "[mock-network-fail-once]") {
    True ->
      case mock_network_fail_once(content) {
        True -> Some(provider.NetworkError("mock network failure"))
        False -> None
      }
    False ->
      case string.contains(content, "[mock-429]") {
        True -> Some(provider.APIError(status: 429, message: "mock rate limit"))
        False ->
          case string.contains(content, "[mock-400]") {
            True ->
              Some(provider.APIError(status: 400, message: "mock bad request"))
            False -> None
          }
      }
  }
}

fn mock_chat_default(
  messages: List(provider.ChatMessage),
  _config: provider.ProviderConfig,
  tools: List(provider.ToolDefinition),
) -> Result(provider.ChatResponse, provider.LLMError) {
  // Only this turn's tool results count: the history keeps those of past
  // turns (#59), and they must not stop a new turn from calling its tool.
  let this_turn = after_last_user(messages)
  let has_tool_result =
    list.any(this_turn, fn(message) { message.role == "tool" })
  let has_tool_error =
    list.any(this_turn, fn(message) {
      message.role == "tool" && string.starts_with(message.content, "ERROR:")
    })
  let tool_mode = mock_tool_mode(messages)

  case tools, has_tool_result, tool_mode {
    _, False, MockToolBusca(terms) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: "buscar_conversa",
            arguments: json.to_string(
              json.object([#("terms", json.string(terms))]),
            ),
          ),
        ]),
        reasoning_content: None,
      ))
    _, False, MockToolFake(name, ms) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: name,
            arguments: json.to_string(json.object([#("ms", json.int(ms))])),
          ),
        ]),
        reasoning_content: None,
      ))
    _, False, MockToolProbe(kind, instructions) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: "sonda",
            arguments: json.to_string(
              json.object([
                #("tipo", json.string(kind)),
                #("instrucoes", json.string(instructions)),
                #("motivo", json.string("teste")),
              ]),
            ),
          ),
        ]),
        reasoning_content: None,
      ))
    _, False, MockToolTask(tool, ms) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: "tarefa",
            arguments: json.to_string(
              json.object([
                #("acao", json.string("iniciar")),
                #("ferramenta", json.string(tool)),
                #("argumentos", json.object([#("ms", json.int(ms))])),
                #("motivo", json.string("teste")),
              ]),
            ),
          ),
        ]),
        reasoning_content: None,
      ))
    _, False, MockToolMany(count) ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some(
          int.range(from: count, to: 0, with: [], run: fn(acc, index) {
            [index, ..acc]
          })
          |> list.map(fn(index) {
            provider.ToolCall(
              id: "mock_tool_call_" <> int.to_string(index),
              name: "lenta",
              arguments: json.to_string(
                json.object([#("ms", json.int({ count - index + 1 } * 20))]),
              ),
            )
          }),
        ),
        reasoning_content: None,
      ))
    _, False, MockToolNone ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "Mock response",
        tool_calls: None,
        reasoning_content: None,
      ))
    [], _, _ ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "Mock response",
        tool_calls: None,
        reasoning_content: None,
      ))
    _, True, _ ->
      Ok(provider.ChatResponse(
        role: "assistant",
        content: case has_tool_error {
          True -> "Mock tool error"
          False ->
            case tool_mode {
              MockToolLoopSuccess -> "Mock tool success"
              _ -> "Mock response"
            }
        },
        tool_calls: None,
        reasoning_content: None,
      ))
    [first_tool, ..], False, _ -> {
      let #(tool_name, tool_arguments) = case tool_mode {
        MockToolWriteSelf -> #(
          "file_system",
          "{\"action\":\"write\",\"path\":\"../self/core.json\",\"content\":\"tampered\"}",
        )
        _ -> #(
          first_tool.name,
          mock_arguments_for_tool(first_tool.name, tool_mode),
        )
      }
      Ok(provider.ChatResponse(
        role: "assistant",
        content: "",
        tool_calls: Some([
          provider.ToolCall(
            id: "mock_tool_call_1",
            name: tool_name,
            arguments: tool_arguments,
          ),
        ]),
        reasoning_content: None,
      ))
    }
  }
}

fn special_mock_response(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> Option(String) {
  let system_text =
    messages
    |> list.filter(fn(message) { message.role == "system" })
    |> list.map(fn(message) { message.content })
    |> string.join("\n")
  case harness_mock_response(system_text) {
    Some(content) -> Some(content)
    None -> reflection_or_plain(messages, config, system_text)
  }
}

fn reflection_or_plain(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
  system_text: String,
) -> Option(String) {
  // Reflection calls are recognized by the fixed user message the runtime
  // sends; the system prompt belongs to the maintainer and can change.
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "Qual nome a pessoa quer dar à agente?") {
        True -> Some(name_mock_json(content))
        False ->
          case string.contains(content, "Escreva o parágrafo agora.") {
            True -> Some(drift_mock_addendum(system_text))
            False ->
              case string.contains(content, "Reflita agora") {
                True ->
                  case
                    string.contains(system_text, "[mock-invalid-reflection]"),
                    string.contains(system_text, "[mock-fenced-reflection]")
                  {
                    True, _ -> Some("not json")
                    False, True ->
                      Some(
                        "```json\n"
                        <> reflection_mock_json(system_text)
                        <> "\n```",
                      )
                    False, False -> Some(reflection_mock_json(system_text))
                  }
                False -> special_mock_response_plain(messages, config)
              }
          }
      }
    None -> special_mock_response_plain(messages, config)
  }
}

/// The name extraction prompt asks which name the person wants to give. The
/// mock reads their reply between the `<<<` markers and picks the first
/// capitalized word, or null when there is none.
fn name_mock_json(content: String) -> String {
  let reply = between_markers(content, "<<<", ">>>")
  case string.contains(reply, "[mock-name-none]") {
    True -> "{\"name\": null}"
    False -> {
      let words =
        reply
        |> string.replace("\n", " ")
        |> string.replace("\r", " ")
        |> string.split(" ")
      case
        list.find_map(words, fn(word) {
          let cleaned = clean_word(word)
          case starts_capitalized(cleaned) {
            True -> Ok(cleaned)
            False -> Error(Nil)
          }
        })
      {
        Ok(name) -> json.to_string(json.object([#("name", json.string(name))]))
        Error(_) -> "{\"name\": null}"
      }
    }
  }
}

fn between_markers(text: String, open: String, close: String) -> String {
  case string.split_once(text, open) {
    Error(_) -> ""
    Ok(#(_, rest)) ->
      case string.split_once(rest, close) {
        Ok(#(inner, _)) -> inner
        Error(_) -> ""
      }
  }
}

fn clean_word(word: String) -> String {
  word
  |> string.to_graphemes
  |> list.drop_while(is_word_punctuation)
  |> list.reverse
  |> list.drop_while(is_word_punctuation)
  |> list.reverse
  |> string.concat
}

fn is_word_punctuation(char: String) -> Bool {
  list.contains(
    [".", ",", "!", "?", ";", ":", "\"", "'", "(", ")", "…", "—"],
    char,
  )
}

fn starts_capitalized(word: String) -> Bool {
  case string.first(word) {
    Error(_) -> False
    Ok(char) -> char == string.uppercase(char) && char != string.lowercase(char)
  }
}

/// Persona and judge prompts are recognized by their first line. This keeps
/// H-05..H-10 tests entirely on the mock, with no CLI and no network.
fn harness_mock_response(system_text: String) -> Option(String) {
  let first_line =
    system_text
    |> string.split("\n")
    |> list.first
    |> result_unwrap("")
  let first_line = string.trim(first_line)
  case first_line {
    "# harness:persona" -> Some(persona_mock_line(system_text))
    "# harness:judge" -> Some(judge_mock_line(system_text))
    _ -> None
  }
}

fn result_unwrap(value: Result(a, b), default: a) -> a {
  case value {
    Ok(inner) -> inner
    Error(_) -> default
  }
}

fn persona_mock_line(system_text: String) -> String {
  let spoken = count_occurrences(system_text, ": persona fala")
  let limit = case string.split(system_text, "[mock-persona-turns=") {
    [_, rest, ..] -> {
      let digits =
        rest
        |> string.to_graphemes
        |> list.take_while(fn(g) { string.contains("0123456789", g) })
        |> string.concat
      case int.parse(digits) {
        Ok(value) -> value
        Error(_) -> 999
      }
    }
    _ -> 999
  }
  case spoken >= limit {
    True -> "[FIM]"
    False -> "persona fala " <> int.to_string(spoken + 1)
  }
}

fn count_occurrences(text: String, needle: String) -> Int {
  list.length(string.split(text, needle)) - 1
}

fn judge_mock_line(system_text: String) -> String {
  case string.contains(system_text, "[mock-judge-invalid]") {
    True -> "isto não é json"
    False -> {
      let ids =
        system_text
        |> string.split("\n")
        |> list.filter_map(fn(line) {
          // Only rubric criteria (`## C1: title`), not section headings of
          // the judge prompt (`## Rubrica`).
          let trimmed = string.trim(line)
          case string.starts_with(trimmed, "## ") {
            True ->
              case string.split_once(string.drop_start(trimmed, 3), ":") {
                Ok(#(id, _)) ->
                  case id != "" && !string.contains(id, " ") {
                    True -> Ok(criterion_id(trimmed))
                    False -> Error(Nil)
                  }
                Error(_) -> Error(Nil)
              }
            False -> Error(Nil)
          }
        })
      let failing = string.contains(system_text, "[mock-judge-fail]")
      let bad_quote = string.contains(system_text, "[mock-judge-bad-quote]")
      let quote = case bad_quote {
        True -> "trecho que nao existe"
        False -> first_transcript_quote(system_text)
      }
      let criteria =
        ids
        |> list.map(fn(id) {
          let score = case failing {
            True -> 0
            False -> 2
          }
          json.object([
            #("id", json.string(id)),
            #("score", json.int(score)),
            #(
              "evidence",
              json.array(
                [
                  json.object([
                    #("line", json.int(1)),
                    #("quote", json.string(quote)),
                  ]),
                ],
                fn(value) { value },
              ),
            ),
            #("why", json.string("mock judge")),
          ])
        })
      json.to_string(
        json.object([#("criteria", json.array(criteria, fn(v) { v }))]),
      )
    }
  }
}

fn criterion_id(trimmed_heading: String) -> String {
  let header = string.drop_start(trimmed_heading, 3)
  case string.split(header, ":") {
    [id, ..] -> string.trim(id)
    [] -> header
  }
}

fn first_transcript_quote(system_text: String) -> String {
  let line =
    system_text
    |> string.split("\n")
    |> list.find(fn(candidate) {
      string.starts_with(string.trim(candidate), "[1] ")
    })
  case line {
    Ok(found) -> {
      let text = string.trim(string.drop_start(string.trim(found), 4))
      case string.length(text) > 40 {
        True -> string.slice(text, 0, 40)
        False -> text
      }
    }
    Error(_) -> "linha"
  }
}

/// A drift addendum must be 40–120 words. Markers in the drift prompt let
/// tests ask for an addendum that is too short or too long.
fn drift_mock_addendum(system_text: String) -> String {
  let words = case string.contains(system_text, "[mock-drift-200]") {
    True -> 200
    False ->
      case string.contains(system_text, "[mock-drift-20]") {
        True -> 20
        False -> 60
      }
  }
  string.join(list.repeat("convivência", words), " ")
}

fn reflection_mock_json(system_text: String) -> String {
  let experiences =
    "{\"experiences\":[{\"text\":\"Aprendi a confiar no que foi vivido.\"}],"
  case reflection_neighbor(system_text) {
    Some(#(from, to)) ->
      experiences
      <> "\"pressures\":[{\"from\":\""
      <> from
      <> "\",\"to\":\""
      <> to
      <> "\",\"strength\":0.9,\"reason\":\"Aprendi com a convivência.\"}]}"
    None -> experiences <> "\"pressures\":[]}"
  }
}

/// First "- from -> to — description" line of the neighbor list.
fn reflection_neighbor(system_text: String) -> Option(#(String, String)) {
  let found =
    system_text
    |> string.split("\n")
    |> list.find_map(fn(line) {
      let stripped = string.trim(line)
      case string.starts_with(stripped, "- ") {
        False -> Error(Nil)
        True ->
          case string.split(string.drop_start(stripped, 2), " -> ") {
            [from, target] -> {
              let to = case string.split(target, " — ") {
                [id, ..] -> id
                _ -> target
              }
              Ok(#(from, string.trim(to)))
            }
            _ -> Error(Nil)
          }
      }
    })
  case found {
    Ok(pair) -> Some(pair)
    Error(_) -> None
  }
}

fn special_mock_response_plain(
  messages: List(provider.ChatMessage),
  config: provider.ProviderConfig,
) -> Option(String) {
  case latest_user_content(messages) {
    Some(content) ->
      case string.contains(content, "[stream-error]") {
        True -> Some("Mock fallback after stream error")
        False ->
          case string.contains(content, "[stream-timeout]") {
            True -> Some("Mock fallback after stream timeout")
            False ->
              case
                string.contains(content, "[mock-eco]"),
                string.contains(content, "[echo-model]")
              {
                // The reply names the message it answers, so a test can
                // check that every reply follows its own question.
                True, _ -> Some("eco: " <> content)
                _, True -> Some("Mock response via " <> config.default_model)
                False, False ->
                  case string.contains(content, "[long-response]") {
                    True -> Some(string.repeat("A", 9000))
                    False -> None
                  }
              }
          }
      }
    None -> None
  }
}

fn mock_tool_mode(messages: List(provider.ChatMessage)) -> MockToolMode {
  case latest_user_content(messages) {
    Some(content) ->
      case
        string.split_once(content, "[mock-busca "),
        string.contains(content, "[mock-sem-ferramenta]")
      {
        Ok(#(_, rest)), _ ->
          case string.split_once(rest, "]") {
            Ok(#(terms, _)) -> MockToolBusca(terms)
            Error(Nil) -> MockToolDefault
          }
        _, True -> MockToolNone
        _, False -> mock_tool_mode_marks(content)
      }
    None -> MockToolDefault
  }
}

fn mock_tool_mode_marks(content: String) -> MockToolMode {
  case mock_fake_tool_mark(content) {
    Some(mode) -> mode
    None -> mock_tool_mode_flags(content)
  }
}

fn mock_fake_tool_mark(content: String) -> Option(MockToolMode) {
  case mock_task_mark(content) {
    Some(mode) -> Some(mode)
    None -> mock_fake_tool_mark_plain(content)
  }
}

fn mock_task_mark(content: String) -> Option(MockToolMode) {
  case string.split_once(content, "[mock-sonda ") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]") {
        Ok(#(inside, _)) ->
          case string.split_once(string.trim(inside), " ") {
            Ok(#(kind, instructions)) ->
              Some(MockToolProbe(kind, string.trim(instructions)))
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
    Error(Nil) -> mock_plain_task_mark(content)
  }
}

fn mock_plain_task_mark(content: String) -> Option(MockToolMode) {
  case string.split_once(content, "[mock-tarefa ") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]") {
        Ok(#(inside, _)) ->
          case string.split(string.trim(inside), " ") {
            [tool, ms] ->
              case int.parse(ms) {
                Ok(ms) -> Some(MockToolTask(tool, ms))
                Error(Nil) -> None
              }
            _ -> None
          }
        Error(Nil) -> None
      }
    Error(Nil) -> None
  }
}

fn mock_fake_tool_mark_plain(content: String) -> Option(MockToolMode) {
  let number_after = fn(mark) {
    case string.split_once(content, mark) {
      Ok(#(_, rest)) ->
        case string.split_once(rest, "]") {
          Ok(#(number, _)) ->
            int.parse(string.trim(number)) |> option.from_result
          Error(Nil) -> None
        }
      Error(Nil) -> None
    }
  }
  case
    number_after("[mock-lenta "),
    number_after("[mock-varias "),
    string.contains(content, "[mock-trava]"),
    string.contains(content, "[mock-explode]")
  {
    Some(ms), _, _, _ -> Some(MockToolFake("lenta", ms))
    _, Some(count), _, _ -> Some(MockToolMany(count))
    _, _, True, _ -> Some(MockToolFake("trava", 0))
    _, _, _, True -> Some(MockToolFake("explode", 0))
    _, _, _, _ -> None
  }
}

fn mock_tool_mode_flags(content: String) -> MockToolMode {
  case
    string.contains(content, "[mock-write-self]"),
    string.contains(content, "[tool-loop-error]"),
    string.contains(content, "[tool-loop-success]")
  {
    True, _, _ -> MockToolWriteSelf
    _, True, _ -> MockToolLoopError
    _, _, True -> MockToolLoopSuccess
    _, _, _ -> MockToolDefault
  }
}

/// The messages after the last user message: the current turn's rounds.
fn after_last_user(
  messages: List(provider.ChatMessage),
) -> List(provider.ChatMessage) {
  messages
  |> list.reverse
  |> list.take_while(fn(message) { message.role != "user" })
  |> list.reverse
}

fn latest_user_content(messages: List(provider.ChatMessage)) -> Option(String) {
  latest_user_content_acc(messages, None)
}

fn latest_user_content_acc(
  messages: List(provider.ChatMessage),
  latest: Option(String),
) -> Option(String) {
  case messages {
    [] -> latest
    [message, ..rest] ->
      case message.role == "user" {
        True -> latest_user_content_acc(rest, Some(message.content))
        False -> latest_user_content_acc(rest, latest)
      }
  }
}

fn mock_arguments_for_tool(tool_name: String, mode: MockToolMode) -> String {
  case mode {
    MockToolLoopError -> "{}"
    _ ->
      case tool_name {
        "safe_shell" -> "{\"command\":\"pwd\"}"
        "canvas" -> "{\"action\":\"create\",\"title\":\"Scratchpad\"}"
        "github" -> "{\"action\":\"get_my_repos\"}"
        "web_fetch" -> "{\"url\":\"https://example.com\"}"
        "git_inspect" -> "{\"action\":\"status\"}"
        "file_system" -> "{\"action\":\"list\",\"path\":\".\"}"
        _ -> "{}"
      }
  }
}
