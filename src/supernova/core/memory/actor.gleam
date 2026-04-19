//// Memory System — Actor
////
//// Actor that maintains memory state and executes I/O commands.
//// Delegates pure logic to the pure module, executes side effects via FFI.
////
//// ## Usage
////
//// ```gleam
//// let assert Ok(memory) = actor.start("MEMORY.md", "HISTORY.md")
//// let assert Ok(entry) = actor.append_history(memory, "session_1", "User said hello")
//// let context = actor.load_context(memory, 5)
//// actor.stop(memory)
//// ```

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/string
import supernova/core/introspection/lesson
import supernova/core/memory/pure
import supernova/core/memory/types.{
  type ConsolidationResult, type HistoryEntry, type MemoryCommand,
  type MemoryEntry, type MemoryError, type MemoryState, EmitTelemetry,
  FileOperationError, HistoryEntry, MemoryState, ReadFile, WriteFile,
}

// ============================================================================
// FFI — File Operations (Erlang)
// ============================================================================

/// Write content to a file (Erlang FFI).
@external(erlang, "supernova_memory_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

/// Get current timestamp in milliseconds (Erlang FFI).
@external(erlang, "supernova_memory_ffi", "current_timestamp")
fn ffi_current_timestamp() -> Int

// ============================================================================
// Types
// ============================================================================

/// Messages that the memory actor handles.
pub type MemoryMessage {
  /// Append a history entry
  AppendHistory(
    reply_to: Subject(Result(HistoryEntry, MemoryError)),
    session_id: String,
    content: String,
  )
  /// Consolidate old history into memory
  Consolidate(reply_to: Subject(ConsolidationResult), max_age_ms: Int)
  /// Recall memories matching a query
  Recall(reply_to: Subject(List(MemoryEntry)), query: String)
  /// Load context for prompt injection
  LoadContext(reply_to: Subject(String), max_entries: Int)
  /// Get all history entries
  GetHistory(reply_to: Subject(List(HistoryEntry)))
  /// Get all memory entries
  GetMemories(reply_to: Subject(List(MemoryEntry)))
  /// Store a learned lesson
  StoreLesson(
    reply_to: Subject(Result(Nil, MemoryError)),
    lesson: lesson.Lesson,
  )
  /// Get the most recent lessons
  GetRecentLessons(reply_to: Subject(List(lesson.Lesson)), limit: Int)
  /// Stop the actor
  Stop(reply_to: Subject(Nil))
}

/// A handle to a running memory actor.
pub type Memory =
  Subject(MemoryMessage)

type ActorState {
  ActorState(
    memory_state: MemoryState,
    lessons: List(lesson.Lesson),
    lessons_path: String,
  )
}

// ============================================================================
// Actor Handler
// ============================================================================

/// Execute a list of commands returned by pure functions.
fn execute_commands(commands: List(MemoryCommand)) -> Nil {
  list.each(commands, fn(cmd) {
    case cmd {
      WriteFile(path, content) -> {
        let _ = ffi_write_file(path, content)
        Nil
      }
      ReadFile(_path) -> {
        // Read commands are handled by the actor directly
        Nil
      }
      EmitTelemetry(_name, _measurements) -> {
        // Telemetry is a no-op for now; in production, emit to telemetry system
        Nil
      }
    }
  })
}

/// Handle memory messages.
fn handle_memory_message(
  state: ActorState,
  message: MemoryMessage,
) -> actor.Next(ActorState, MemoryMessage) {
  case message {
    AppendHistory(reply_to, session_id, content) -> {
      let digest = pure.generate_digest(content)
      let timestamp = ffi_current_timestamp()

      let entry =
        HistoryEntry(
          digest: digest,
          content: content,
          timestamp: timestamp,
          session_id: session_id,
          consolidated: False,
        )

      let #(next_memory_state, commands) =
        pure.append_entry(state.memory_state, entry)
      execute_commands(commands)

      actor.send(reply_to, Ok(entry))
      actor.continue(ActorState(..state, memory_state: next_memory_state))
    }

    Consolidate(reply_to, max_age_ms) -> {
      let current_time = ffi_current_timestamp()
      let #(next_memory_state, result, commands) =
        pure.consolidate(state.memory_state, current_time, max_age_ms)
      execute_commands(commands)

      actor.send(reply_to, result)
      actor.continue(ActorState(..state, memory_state: next_memory_state))
    }

    Recall(reply_to, query) -> {
      let memories = pure.recall(state.memory_state.memories, query)
      actor.send(reply_to, memories)
      actor.continue(state)
    }

    LoadContext(reply_to, max_entries) -> {
      let context = pure.build_context(state.memory_state.memories, max_entries)
      actor.send(reply_to, context)
      actor.continue(state)
    }

    GetHistory(reply_to) -> {
      actor.send(reply_to, state.memory_state.history)
      actor.continue(state)
    }

    GetMemories(reply_to) -> {
      actor.send(reply_to, state.memory_state.memories)
      actor.continue(state)
    }

    StoreLesson(reply_to, new_lesson) -> {
      let updated_lessons =
        [new_lesson, ..state.lessons]
        |> list.sort(fn(a, b) { int.compare(b.created_at, a.created_at) })
        |> list.take(100)

      case ffi_write_file(state.lessons_path, render_lessons(updated_lessons)) {
        Ok(_) -> {
          actor.send(reply_to, Ok(Nil))
          actor.continue(ActorState(..state, lessons: updated_lessons))
        }
        Error(reason) -> {
          actor.send(
            reply_to,
            Error(FileOperationError(path: state.lessons_path, reason: reason)),
          )
          actor.continue(state)
        }
      }
    }

    GetRecentLessons(reply_to, limit) -> {
      actor.send(reply_to, list.take(state.lessons, limit))
      actor.continue(state)
    }

    Stop(reply_to) -> {
      actor.send(reply_to, Nil)
      actor.stop()
    }
  }
}

// ============================================================================
// Public API
// ============================================================================

/// Start a new memory actor.
///
/// Loads existing HISTORY.md and MEMORY.md files if they exist.
/// Returns the memory actor subject on success.
pub fn start(
  memory_path: String,
  history_path: String,
) -> Result(Memory, actor.StartError) {
  let initial_memory_state =
    MemoryState(
      history: [],
      memories: [],
      history_path: history_path,
      memory_path: memory_path,
    )
  let initial_state =
    ActorState(
      memory_state: initial_memory_state,
      lessons: [],
      lessons_path: history_path <> ".lessons.json",
    )

  case
    actor.new(initial_state)
    |> actor.on_message(handle_memory_message)
    |> actor.start
  {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Append a history entry.
///
/// Creates a new history entry with the given content and session ID.
/// Returns the created entry on success.
pub fn append_history(
  memory: Memory,
  session_id: String,
  content: String,
) -> Result(HistoryEntry, MemoryError) {
  actor.call(memory, waiting: 5000, sending: AppendHistory(
    _,
    session_id,
    content,
  ))
}

/// Consolidate old history entries into memory.
///
/// Moves entries older than max_age_ms from HISTORY.md to MEMORY.md.
/// Returns the consolidation result.
pub fn consolidate(memory: Memory, max_age_ms: Int) -> ConsolidationResult {
  actor.call(memory, waiting: 5000, sending: Consolidate(_, max_age_ms))
}

/// Recall memories matching a query.
///
/// Searches memory content for the query string.
/// Returns matching entries sorted by relevance.
pub fn recall(memory: Memory, query: String) -> List(MemoryEntry) {
  actor.call(memory, waiting: 5000, sending: Recall(_, query))
}

/// Load context for prompt injection.
///
/// Returns a formatted string with top memories by relevance.
pub fn load_context(memory: Memory, max_entries: Int) -> String {
  actor.call(memory, waiting: 5000, sending: LoadContext(_, max_entries))
}

/// Get all history entries.
pub fn get_history(memory: Memory) -> List(HistoryEntry) {
  actor.call(memory, waiting: 5000, sending: GetHistory)
}

/// Get all memory entries.
pub fn get_memories(memory: Memory) -> List(MemoryEntry) {
  actor.call(memory, waiting: 5000, sending: GetMemories)
}

/// Store one lesson in memory.
pub fn store_lesson(
  memory: Memory,
  new_lesson: lesson.Lesson,
) -> Result(Nil, MemoryError) {
  actor.call(memory, waiting: 5000, sending: StoreLesson(_, new_lesson))
}

/// Fetch recent lessons (most recent first).
pub fn get_recent_lessons(memory: Memory, limit: Int) -> List(lesson.Lesson) {
  actor.call(memory, waiting: 5000, sending: GetRecentLessons(_, limit))
}

/// Stop the memory actor gracefully.
pub fn stop(memory: Memory) -> Nil {
  actor.call(memory, waiting: 5000, sending: Stop)
}

fn render_lessons(lessons: List(lesson.Lesson)) -> String {
  case lessons {
    [] -> "# Lessons\n\n_No lessons yet._\n"
    _ ->
      "# Lessons\n\n"
      <> string.join(
        list.map(lessons, fn(item) {
          "- ["
          <> lesson_type_label(item.lesson_type)
          <> "] "
          <> item.content
          <> " ("
          <> item.context
          <> ")"
        }),
        "\n",
      )
      <> "\n"
  }
}

fn lesson_type_label(value: lesson.LessonType) -> String {
  case value {
    lesson.ErrorLesson -> "error"
    lesson.SuccessLesson -> "success"
  }
}
