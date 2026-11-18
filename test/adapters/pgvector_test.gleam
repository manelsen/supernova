//// Tests for the PostgreSQL + pgvector adapter.
////
//// These tests cover configuration, data structures, and pure functions.
//// They do not require a running PostgreSQL instance.

import gleam/dict
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import supernova/adapters/pgvector

pub fn main() {
  gleeunit.main()
}

@external(erlang, "pgvector_test_ffi", "fake_connection")
fn fake_connection() -> pgvector.Connection

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn new_config_default_values_test() {
  let config =
    pgvector.new_config("test_pool", "localhost", 5432, "mydb", "myuser")

  config.table_name |> should.equal("embeddings")
  config.dimensions |> should.equal(1536)
  config.default_limit |> should.equal(10)
}

pub fn with_table_name_test() {
  let config =
    pgvector.new_config("test_pool2", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_table_name("custom_embeddings")

  config.table_name |> should.equal("custom_embeddings")
}

pub fn with_dimensions_test() {
  let config =
    pgvector.new_config("test_pool3", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_dimensions(768)

  config.dimensions |> should.equal(768)
}

pub fn with_default_limit_test() {
  let config =
    pgvector.new_config("test_pool4", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_default_limit(5)

  config.default_limit |> should.equal(5)
}

pub fn with_password_does_not_change_other_fields_test() {
  let config =
    pgvector.new_config("test_pool5", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_password("secret")

  config.table_name |> should.equal("embeddings")
  config.dimensions |> should.equal(1536)
}

pub fn with_pool_size_does_not_change_other_fields_test() {
  let config =
    pgvector.new_config("test_pool6", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_pool_size(20)

  config.table_name |> should.equal("embeddings")
  config.dimensions |> should.equal(1536)
}

pub fn from_url_valid_url_test() {
  let result =
    pgvector.from_url(
      "postgresql://user:pass@localhost:5432/mydb",
      "test_pool7",
    )

  result |> should.be_ok
}

pub fn from_url_invalid_url_test() {
  let result = pgvector.from_url("not-a-url", "test_pool8")
  result |> should.be_error
}

// ============================================================================
// EmbeddingRecord Tests
// ============================================================================

pub fn embedding_record_stores_fields_test() {
  let record =
    pgvector.EmbeddingRecord(
      id: "test-id",
      content: "hello world",
      embedding: [1.0, 2.0, 3.0],
      metadata: dict.from_list([#("source", "test")]),
    )

  record.id |> should.equal("test-id")
  record.content |> should.equal("hello world")
  list.length(record.embedding) |> should.equal(3)
}

pub fn embedding_record_empty_metadata_test() {
  let record =
    pgvector.EmbeddingRecord(
      id: "",
      content: "content",
      embedding: [0.1, 0.2],
      metadata: dict.new(),
    )

  dict.size(record.metadata) |> should.equal(0)
}

// ============================================================================
// SearchResult Tests
// ============================================================================

pub fn search_result_stores_record_and_score_test() {
  let record =
    pgvector.EmbeddingRecord(
      id: "abc-123",
      content: "some content",
      embedding: [1.0, 0.0],
      metadata: dict.new(),
    )
  let result = pgvector.SearchResult(record:, score: 0.95)

  result.score |> should.equal(0.95)
  result.record.id |> should.equal("abc-123")
}

// ============================================================================
// Vector Formatting Tests
// ============================================================================

pub fn format_vector_empty_test() {
  pgvector.format_vector([]) |> should.equal("[]")
}

pub fn format_vector_single_element_test() {
  pgvector.format_vector([1.0]) |> should.equal("[1.0]")
}

pub fn format_vector_multiple_elements_test() {
  let result = pgvector.format_vector([1.0, 2.0, 3.0])
  result |> should.equal("[1.0,2.0,3.0]")
}

pub fn format_vector_negative_values_test() {
  let result = pgvector.format_vector([-1.0, 0.5, -0.25])
  result |> should.equal("[-1.0,0.5,-0.25]")
}

// ============================================================================
// Dimension Validation Tests
// ============================================================================

pub fn validate_dimensions_correct_size_test() {
  let embedding = [1.0, 2.0, 3.0]
  pgvector.validate_dimensions(embedding, 3)
  |> should.be_ok
}

pub fn validate_dimensions_wrong_size_returns_error_test() {
  let embedding = [1.0, 2.0]
  pgvector.validate_dimensions(embedding, 3)
  |> should.be_error
}

pub fn validate_dimensions_error_has_expected_and_got_test() {
  let embedding = [1.0, 2.0]
  case pgvector.validate_dimensions(embedding, 3) {
    Error(pgvector.VectorDimensionMismatch(expected: 3, got: 2)) -> Nil
    _ -> should.fail()
  }
}

pub fn validate_dimensions_empty_embedding_test() {
  pgvector.validate_dimensions([], 0) |> should.be_ok
}

pub fn validate_dimensions_empty_vs_nonzero_test() {
  pgvector.validate_dimensions([], 3)
  |> should.be_error
}

// ============================================================================
// Schema SQL Tests
// ============================================================================

pub fn schema_sql_contains_table_name_test() {
  let config =
    pgvector.new_config("test_pool9", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_table_name("my_embeddings")

  let sql = pgvector.schema_sql(config)
  sql |> string.contains("my_embeddings") |> should.equal(True)
}

pub fn schema_sql_contains_dimensions_test() {
  let config =
    pgvector.new_config("test_pool10", "localhost", 5432, "mydb", "myuser")
    |> pgvector.with_dimensions(768)

  let sql = pgvector.schema_sql(config)
  sql |> string.contains("vector(768)") |> should.equal(True)
}

pub fn schema_sql_contains_vector_extension_test() {
  let config =
    pgvector.new_config("test_pool11", "localhost", 5432, "mydb", "myuser")
  let sql = pgvector.schema_sql(config)
  sql
  |> string.contains("CREATE EXTENSION IF NOT EXISTS vector")
  |> should.equal(True)
}

pub fn schema_sql_contains_index_test() {
  let config =
    pgvector.new_config("test_pool12", "localhost", 5432, "mydb", "myuser")
  let sql = pgvector.schema_sql(config)
  sql |> string.contains("ivfflat") |> should.equal(True)
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn query_failed_error_test() {
  let err = pgvector.InvalidEmbedding("bad vector data")
  case err {
    pgvector.InvalidEmbedding(reason) ->
      reason |> should.equal("bad vector data")
  }
}

pub fn migration_failed_error_test() {
  let err = pgvector.MigrationFailed("table already exists")
  case err {
    pgvector.MigrationFailed(reason) ->
      reason |> should.equal("table already exists")
  }
}

pub fn vector_dimension_mismatch_error_test() {
  let err = pgvector.VectorDimensionMismatch(expected: 1536, got: 768)
  case err {
    pgvector.VectorDimensionMismatch(expected: 1536, got: 768) -> Nil
    _ -> should.fail()
  }
}

// ============================================================================
// Early Validation Branches in DB Operations
// ============================================================================

pub fn insert_dimension_mismatch_short_circuits_before_db_test() {
  let config =
    pgvector.new_config("mismatch_pool_1", "localhost", 5432, "mydb", "user")
    |> pgvector.with_dimensions(3)
  let record =
    pgvector.EmbeddingRecord(
      id: "",
      content: "hello",
      embedding: [1.0, 2.0],
      metadata: dict.new(),
    )

  case pgvector.insert(fake_connection(), config, record) {
    Error(pgvector.VectorDimensionMismatch(expected: 3, got: 2)) -> Nil
    _ -> should.fail()
  }
}

pub fn similarity_search_dimension_mismatch_short_circuits_before_db_test() {
  let config =
    pgvector.new_config("mismatch_pool_2", "localhost", 5432, "mydb", "user")
    |> pgvector.with_dimensions(4)

  case
    pgvector.similarity_search(fake_connection(), config, [1.0, 2.0, 3.0], None)
  {
    Error(pgvector.VectorDimensionMismatch(expected: 4, got: 3)) -> Nil
    _ -> should.fail()
  }
}

pub fn retrieve_context_dimension_mismatch_short_circuits_before_db_test() {
  let config =
    pgvector.new_config("mismatch_pool_3", "localhost", 5432, "mydb", "user")
    |> pgvector.with_dimensions(5)

  case pgvector.retrieve_context(fake_connection(), config, [1.0, 2.0], 3) {
    Error(pgvector.VectorDimensionMismatch(expected: 5, got: 2)) -> Nil
    _ -> should.fail()
  }
}

pub fn delete_by_metadata_rejects_unsafe_key_before_db_test() {
  let config =
    pgvector.new_config("mismatch_pool_4", "localhost", 5432, "mydb", "user")

  case
    pgvector.delete_by_metadata(
      fake_connection(),
      config,
      "unsafe key",
      "value",
    )
  {
    Error(pgvector.InvalidMetadataKey("unsafe key")) -> Nil
    _ -> should.fail()
  }
}

pub fn schema_sql_quotes_unsafe_identifier_characters_test() {
  let config =
    pgvector.new_config("quoted_pool", "localhost", 5432, "mydb", "user")
    |> pgvector.with_table_name("embeddings\"v2")

  let sql = pgvector.schema_sql(config)
  sql |> string.contains("\"embeddings\"\"v2\"") |> should.equal(True)
}

pub fn delete_by_metadata_rejects_empty_key_test() {
  let config =
    pgvector.new_config("empty_key_pool", "localhost", 5432, "mydb", "user")

  case pgvector.delete_by_metadata(fake_connection(), config, "", "value") {
    Error(pgvector.InvalidMetadataKey("")) -> Nil
    _ -> should.fail()
  }
}
