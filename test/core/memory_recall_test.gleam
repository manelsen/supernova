//// Tests for Memory Recall — Semantic Search via pgvector
////
//// Covers conversion functions, type construction, and ranking logic.
//// Does not require a running PostgreSQL instance.

import gleam/dict
import gleam/float
import gleam/list
import gleeunit
import gleeunit/should
import supernova/adapters/pgvector
import supernova/core/memory_recall

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// RecalledMemory Type Tests
// ============================================================================

pub fn recalled_memory_stores_fields_test() {
  let memory =
    memory_recall.RecalledMemory(
      content: "Gleam is a type-safe language",
      embedding: [0.1, 0.2, 0.3],
      score: 0.95,
    )

  memory.content |> should.equal("Gleam is a type-safe language")
  list.length(memory.embedding) |> should.equal(3)
  memory.score |> should.equal(0.95)
}

pub fn recalled_memory_zero_score_test() {
  let memory =
    memory_recall.RecalledMemory(
      content: "unrelated content",
      embedding: [0.0, 0.0],
      score: 0.0,
    )

  memory.score |> should.equal(0.0)
}

pub fn recalled_memory_perfect_score_test() {
  let memory =
    memory_recall.RecalledMemory(
      content: "exact match",
      embedding: [1.0, 0.0, 0.0],
      score: 1.0,
    )

  memory.score |> should.equal(1.0)
}

// ============================================================================
// from_search_result Conversion Tests
// ============================================================================

pub fn from_search_result_preserves_content_test() {
  let record =
    pgvector.EmbeddingRecord(
      id: "uuid-123",
      content: "important memory",
      embedding: [0.5, 0.5, 0.5],
      metadata: dict.new(),
    )
  let search_result = pgvector.SearchResult(record:, score: 0.87)

  let recalled = memory_recall.from_search_result(search_result)

  recalled.content |> should.equal("important memory")
  recalled.score |> should.equal(0.87)
}

pub fn from_search_result_preserves_embedding_test() {
  let embedding = [0.1, 0.2, 0.3, 0.4]
  let record =
    pgvector.EmbeddingRecord(
      id: "uuid-456",
      content: "test content",
      embedding: embedding,
      metadata: dict.from_list([#("source", "test")]),
    )
  let search_result = pgvector.SearchResult(record:, score: 0.5)

  let recalled = memory_recall.from_search_result(search_result)

  list.length(recalled.embedding) |> should.equal(4)
  recalled.embedding |> should.equal(embedding)
}

pub fn from_search_result_ignores_id_and_metadata_test() {
  let record =
    pgvector.EmbeddingRecord(
      id: "should-be-ignored",
      content: "content only",
      embedding: [1.0],
      metadata: dict.from_list([#("key", "value")]),
    )
  let search_result = pgvector.SearchResult(record:, score: 0.3)

  let recalled = memory_recall.from_search_result(search_result)

  recalled.content |> should.equal("content only")
  recalled.score |> should.equal(0.3)
}

// ============================================================================
// to_embedding_record Conversion Tests
// ============================================================================

pub fn to_embedding_record_stores_content_test() {
  let record = memory_recall.to_embedding_record("my content", [0.1, 0.2, 0.3])

  record.content |> should.equal("my content")
  record.id |> should.equal("")
}

pub fn to_embedding_record_stores_embedding_test() {
  let embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
  let record = memory_recall.to_embedding_record("test", embedding)

  record.embedding |> should.equal(embedding)
}

pub fn to_embedding_record_empty_metadata_test() {
  let record = memory_recall.to_embedding_record("content", [1.0, 2.0])

  dict.size(record.metadata) |> should.equal(0)
}

pub fn to_embedding_record_empty_embedding_test() {
  let record = memory_recall.to_embedding_record("content", [])

  list.length(record.embedding) |> should.equal(0)
}

// ============================================================================
// to_memory_entry Conversion Tests
// ============================================================================

pub fn to_memory_entry_preserves_content_test() {
  let recalled =
    memory_recall.RecalledMemory(
      content: "semantic memory content",
      embedding: [0.1, 0.2],
      score: 0.85,
    )

  let entry =
    memory_recall.to_memory_entry(recalled, 1_000_000, ["ai", "gleam"])

  entry.content |> should.equal("semantic memory content")
  entry.created_at |> should.equal(1_000_000)
  entry.tags |> should.equal(["ai", "gleam"])
}

pub fn to_memory_entry_uses_score_as_relevance_test() {
  let recalled =
    memory_recall.RecalledMemory(content: "test", embedding: [0.0], score: 0.73)

  let entry = memory_recall.to_memory_entry(recalled, 0, [])

  entry.relevance |> should.equal(0.73)
}

pub fn to_memory_entry_generates_digest_test() {
  let recalled =
    memory_recall.RecalledMemory(
      content: "some content for digest generation",
      embedding: [0.0],
      score: 0.5,
    )

  let entry = memory_recall.to_memory_entry(recalled, 0, [])

  // Digest should not be empty
  entry.digest |> should.not_equal("")
}

pub fn to_memory_entry_same_content_same_digest_test() {
  let content = "deterministic digest test content"
  let recalled1 =
    memory_recall.RecalledMemory(content:, embedding: [0.1], score: 0.5)
  let recalled2 =
    memory_recall.RecalledMemory(content:, embedding: [0.2], score: 0.8)

  let entry1 = memory_recall.to_memory_entry(recalled1, 0, [])
  let entry2 = memory_recall.to_memory_entry(recalled2, 0, [])

  entry1.digest |> should.equal(entry2.digest)
}

pub fn to_memory_entry_empty_tags_test() {
  let recalled =
    memory_recall.RecalledMemory(
      content: "no tags",
      embedding: [0.0],
      score: 0.5,
    )

  let entry = memory_recall.to_memory_entry(recalled, 0, [])

  entry.tags |> should.equal([])
}

// ============================================================================
// Ranking by Similarity Tests
// ============================================================================

pub fn search_results_ranked_by_score_test() {
  // Simulate search results with different scores
  let results = [
    pgvector.SearchResult(
      record: pgvector.EmbeddingRecord(
        id: "1",
        content: "low relevance",
        embedding: [0.1],
        metadata: dict.new(),
      ),
      score: 0.3,
    ),
    pgvector.SearchResult(
      record: pgvector.EmbeddingRecord(
        id: "2",
        content: "high relevance",
        embedding: [0.2],
        metadata: dict.new(),
      ),
      score: 0.95,
    ),
    pgvector.SearchResult(
      record: pgvector.EmbeddingRecord(
        id: "3",
        content: "medium relevance",
        embedding: [0.3],
        metadata: dict.new(),
      ),
      score: 0.6,
    ),
  ]

  let recalled = list.map(results, memory_recall.from_search_result)

  // Sort by score descending to verify ranking
  let sorted = list.sort(recalled, fn(a, b) { float.compare(b.score, a.score) })

  case sorted {
    [first, second, third, ..] -> {
      first.score |> should.equal(0.95)
      first.content |> should.equal("high relevance")
      second.score |> should.equal(0.6)
      second.content |> should.equal("medium relevance")
      third.score |> should.equal(0.3)
      third.content |> should.equal("low relevance")
    }
    _ -> should.fail()
  }
}

pub fn recalled_memories_preserve_order_from_pgvector_test() {
  // pgvector returns results already sorted by similarity
  let pre_sorted = [
    pgvector.SearchResult(
      record: pgvector.EmbeddingRecord(
        id: "1",
        content: "most similar",
        embedding: [1.0, 0.0],
        metadata: dict.new(),
      ),
      score: 0.99,
    ),
    pgvector.SearchResult(
      record: pgvector.EmbeddingRecord(
        id: "2",
        content: "less similar",
        embedding: [0.0, 1.0],
        metadata: dict.new(),
      ),
      score: 0.01,
    ),
  ]

  let recalled = list.map(pre_sorted, memory_recall.from_search_result)

  case recalled {
    [first, second, ..] -> {
      first.content |> should.equal("most similar")
      second.content |> should.equal("less similar")
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn pgvector_error_constructor_test() {
  let err = memory_recall.PgVectorError(pgvector.InvalidEmbedding("bad vector"))

  case err {
    memory_recall.PgVectorError(pgvector.InvalidEmbedding(reason)) ->
      reason |> should.equal("bad vector")
    _ -> should.fail()
  }
}

pub fn no_memories_found_error_test() {
  let err = memory_recall.NoMemoriesFound

  case err {
    memory_recall.NoMemoriesFound -> Nil
  }
}

pub fn dimension_mismatch_error_propagation_test() {
  let err =
    memory_recall.PgVectorError(pgvector.VectorDimensionMismatch(
      expected: 1536,
      got: 768,
    ))

  case err {
    memory_recall.PgVectorError(pgvector.VectorDimensionMismatch(
      expected: 1536,
      got: 768,
    )) -> Nil
    _ -> should.fail()
  }
}

// ============================================================================
// Integration: Full Conversion Pipeline Tests
// ============================================================================

pub fn search_result_to_memory_entry_pipeline_test() {
  // Simulate the full pipeline: SearchResult -> RecalledMemory -> MemoryEntry
  let record =
    pgvector.EmbeddingRecord(
      id: "uuid-789",
      content: "Gleam has excellent type inference",
      embedding: [0.8, 0.1, 0.1],
      metadata: dict.from_list([#("source", "docs")]),
    )
  let search_result = pgvector.SearchResult(record:, score: 0.92)

  let recalled = memory_recall.from_search_result(search_result)
  let entry =
    memory_recall.to_memory_entry(recalled, 1_700_000, ["gleam", "types"])

  entry.content |> should.equal("Gleam has excellent type inference")
  entry.relevance |> should.equal(0.92)
  entry.created_at |> should.equal(1_700_000)
  entry.tags |> should.equal(["gleam", "types"])
}

pub fn embed_and_store_record_structure_test() {
  // Verify the record created by embed_and_store has correct structure
  let embedding = [0.1, 0.2, 0.3]
  let record =
    memory_recall.to_embedding_record("new memory content", embedding)

  record.content |> should.equal("new memory content")
  record.embedding |> should.equal(embedding)
  record.id |> should.equal("")
  dict.size(record.metadata) |> should.equal(0)
}
