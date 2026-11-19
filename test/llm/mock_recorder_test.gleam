import gleam/int
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn prompts_keep_only_the_last_200_test() {
  clear_prompts()
  seeds(1, 250)
  |> list.each(fn(n) { record_prompt(int.to_string(n)) })
  let recorded = prompts()
  recorded |> list.length |> should.equal(200)
  recorded |> list.first |> should.equal(Ok("250"))
  recorded |> list.last |> should.equal(Ok("51"))
  clear_prompts()
}

@external(erlang, "supernova_mock_ffi", "clear_prompts")
fn clear_prompts() -> Nil

@external(erlang, "supernova_mock_ffi", "record_prompt")
fn record_prompt(prompt: String) -> Nil

@external(erlang, "supernova_mock_ffi", "prompts")
fn prompts() -> List(String)

fn seeds(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..seeds(start + 1, stop)]
  }
}
