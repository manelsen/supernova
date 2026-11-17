//// PostgreSQL + pgvector adapter for vector memory persistence.
////
//// Provides a connection pool and operations for storing and searching
//// embeddings using PostgreSQL with the pgvector extension.
////
//// ## Usage
////
//// ```gleam
//// import supernova/adapters/pgvector
//// import pog
//// import gleam/erlang/process
////
//// let config =
////   pgvector.new_config("ralph_memory", "localhost", 5432, "ralph", "ralph")
////   |> pgvector.with_dimensions(1536)
////   |> pgvector.with_pool_size(10)
////
//// let assert Ok(conn) = pgvector.connect(config)
//// let assert Ok(_) = pgvector.ensure_schema(conn, config)
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import pog

// ============================================================================
// Types
// ============================================================================

/// Configuration for the pgvector adapter.
pub type PgVectorConfig {
  PgVectorConfig(
    /// pog connection configuration
    pog_config: pog.Config,
    /// Name of the table to store embeddings in
    table_name: String,
    /// Number of dimensions for the vector (must match your embedding model)
    dimensions: Int,
    /// Number of results to return by default in similarity search
    default_limit: Int,
  )
}

/// An embedding record stored in the database.
pub type EmbeddingRecord {
  EmbeddingRecord(
    /// UUID primary key (empty string means auto-generated on insert)
    id: String,
    /// Text content that was embedded
    content: String,
    /// The embedding vector
    embedding: List(Float),
    /// Optional metadata as key-value pairs
    metadata: Dict(String, String),
  )
}

/// Result of a similarity search.
pub type SearchResult {
  SearchResult(
    /// The matching record
    record: EmbeddingRecord,
    /// Cosine similarity score (0.0 to 1.0, higher is more similar)
    score: Float,
  )
}

/// Errors that can occur during pgvector operations.
pub type PgVectorError {
  /// A PostgreSQL query failed
  QueryFailed(pog.QueryError)
  /// The embedding dimensions don't match the configured dimensions
  VectorDimensionMismatch(expected: Int, got: Int)
  /// A metadata key contains unsafe characters
  InvalidMetadataKey(key: String)
  /// The vector formatting failed
  InvalidEmbedding(reason: String)
  /// Schema migration failed
  MigrationFailed(reason: String)
}

/// An active PostgreSQL connection pool.
pub type Connection =
  pog.Connection

// ============================================================================
// Configuration
// ============================================================================

/// Create a new pgvector configuration with default settings.
///
/// `pool_name` must be a unique atom name for the connection pool.
/// Uses default dimensions of 1536 (OpenAI text-embedding-ada-002).
pub fn new_config(
  pool_name: String,
  host: String,
  port: Int,
  database: String,
  user: String,
) -> PgVectorConfig {
  let name = process.new_name(pool_name)
  let pog_config =
    pog.default_config(name)
    |> pog.host(host)
    |> pog.port(port)
    |> pog.database(database)
    |> pog.user(user)
  PgVectorConfig(
    pog_config:,
    table_name: "embeddings",
    dimensions: 1536,
    default_limit: 10,
  )
}

/// Set the password for the PostgreSQL connection.
pub fn with_password(
  config: PgVectorConfig,
  password: String,
) -> PgVectorConfig {
  PgVectorConfig(
    ..config,
    pog_config: pog.password(config.pog_config, Some(password)),
  )
}

/// Set the connection pool size.
pub fn with_pool_size(config: PgVectorConfig, size: Int) -> PgVectorConfig {
  PgVectorConfig(..config, pog_config: pog.pool_size(config.pog_config, size))
}

/// Set the table name for embeddings.
pub fn with_table_name(
  config: PgVectorConfig,
  table_name: String,
) -> PgVectorConfig {
  PgVectorConfig(..config, table_name:)
}

/// Set the number of dimensions for the embedding vectors.
pub fn with_dimensions(
  config: PgVectorConfig,
  dimensions: Int,
) -> PgVectorConfig {
  PgVectorConfig(..config, dimensions:)
}

/// Set the default limit for similarity search results.
pub fn with_default_limit(
  config: PgVectorConfig,
  limit: Int,
) -> PgVectorConfig {
  PgVectorConfig(..config, default_limit: limit)
}

/// Create a PgVectorConfig from a PostgreSQL URL.
///
/// URL format: `postgresql://user:password@host:port/database`
pub fn from_url(url: String, pool_name: String) -> Result(PgVectorConfig, Nil) {
  let name = process.new_name(pool_name)
  use pog_config <- result.map(pog.url_config(name, url))
  PgVectorConfig(
    pog_config:,
    table_name: "embeddings",
    dimensions: 1536,
    default_limit: 10,
  )
}

// ============================================================================
// Connection Management
// ============================================================================

/// Start a connection pool for the pgvector adapter.
///
/// Returns the connection that can be used for subsequent operations.
/// The connection pool will automatically reconnect on failure.
pub fn connect(config: PgVectorConfig) -> Result(Connection, String) {
  case pog.start(config.pog_config) {
    Ok(started) -> Ok(started.data)
    Error(reason) ->
      Error(
        "Failed to start PostgreSQL connection pool: " <> string.inspect(reason),
      )
  }
}

// ============================================================================
// Schema Management
// ============================================================================

/// SQL to create the schema (for documentation/migration tools).
pub fn schema_sql(config: PgVectorConfig) -> String {
  let table = sanitize_identifier(config.table_name)
  let index_name = sanitize_identifier(config.table_name <> "_embedding_idx")
  let dims = int.to_string(config.dimensions)
  "-- Enable pgvector extension\n"
  <> "CREATE EXTENSION IF NOT EXISTS vector;\n\n"
  <> "-- Embeddings table\n"
  <> "CREATE TABLE IF NOT EXISTS "
  <> table
  <> " (\n"
  <> "  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),\n"
  <> "  content TEXT NOT NULL,\n"
  <> "  embedding vector("
  <> dims
  <> ") NOT NULL,\n"
  <> "  metadata JSONB NOT NULL DEFAULT '{}'\n"
  <> ");\n\n"
  <> "-- IVFFlat index for approximate nearest neighbor search\n"
  <> "CREATE INDEX IF NOT EXISTS "
  <> index_name
  <> "\n"
  <> "  ON "
  <> table
  <> " USING ivfflat (embedding vector_cosine_ops)\n"
  <> "  WITH (lists = 100);\n"
}

/// Ensure the pgvector schema exists in the database.
///
/// Creates the `vector` extension, the embeddings table, and an IVFFlat index
/// if they do not already exist.
pub fn ensure_schema(
  conn: Connection,
  config: PgVectorConfig,
) -> Result(Nil, PgVectorError) {
  let table = sanitize_identifier(config.table_name)
  let dims = int.to_string(config.dimensions)

  let extension_sql = "CREATE EXTENSION IF NOT EXISTS vector"
  let table_sql =
    "CREATE TABLE IF NOT EXISTS "
    <> table
    <> " ("
    <> "id UUID PRIMARY KEY DEFAULT gen_random_uuid(), "
    <> "content TEXT NOT NULL, "
    <> "embedding vector("
    <> dims
    <> ") NOT NULL, "
    <> "metadata JSONB NOT NULL DEFAULT '{}')"

  let index_sql =
    "CREATE INDEX IF NOT EXISTS "
    <> sanitize_identifier(config.table_name <> "_embedding_idx")
    <> " ON "
    <> table
    <> " USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)"

  use _ <- result.try(
    pog.query(extension_sql)
    |> pog.execute(conn)
    |> result.map_error(fn(e) { MigrationFailed(string.inspect(e)) }),
  )
  use _ <- result.try(
    pog.query(table_sql)
    |> pog.execute(conn)
    |> result.map_error(fn(e) { MigrationFailed(string.inspect(e)) }),
  )
  use _ <- result.try(
    pog.query(index_sql)
    |> pog.execute(conn)
    |> result.map_error(fn(e) { MigrationFailed(string.inspect(e)) }),
  )
  Ok(Nil)
}

// ============================================================================
// Vector Formatting
// ============================================================================

/// Format a list of floats as a pgvector literal string.
///
/// Example: `[1.0, 2.0, 3.0]` → `"[1.0,2.0,3.0]"`
pub fn format_vector(embedding: List(Float)) -> String {
  let values =
    list.map(embedding, float.to_string)
    |> string.join(",")
  "[" <> values <> "]"
}

/// Validate that an embedding has the expected dimensions.
pub fn validate_dimensions(
  embedding: List(Float),
  expected: Int,
) -> Result(List(Float), PgVectorError) {
  let got = list.length(embedding)
  case got == expected {
    True -> Ok(embedding)
    False -> Error(VectorDimensionMismatch(expected:, got:))
  }
}

// ============================================================================
// CRUD Operations
// ============================================================================

/// Insert an embedding record into the database.
///
/// Returns the auto-generated UUID id of the inserted record.
pub fn insert(
  conn: Connection,
  config: PgVectorConfig,
  record: EmbeddingRecord,
) -> Result(String, PgVectorError) {
  use validated <- result.try(validate_dimensions(
    record.embedding,
    config.dimensions,
  ))
  let vector_str = format_vector(validated)
  let metadata_json = metadata_to_json(record.metadata)
  let table = sanitize_identifier(config.table_name)
  let sql =
    "INSERT INTO "
    <> table
    <> " (content, embedding, metadata) VALUES ($1, $2::vector, $3::jsonb) RETURNING id::text"

  let id_decoder = {
    use id <- decode.field("id", decode.string)
    decode.success(id)
  }

  pog.query(sql)
  |> pog.parameter(pog.text(record.content))
  |> pog.parameter(pog.text(vector_str))
  |> pog.parameter(pog.text(metadata_json))
  |> pog.returning(id_decoder)
  |> pog.execute(conn)
  |> result.map_error(QueryFailed)
  |> result.try(fn(returned) {
    case returned.rows {
      [id, ..] -> Ok(id)
      [] -> Error(InvalidEmbedding("Insert returned no rows"))
    }
  })
}

/// Search for similar embeddings using cosine similarity.
///
/// Returns up to `limit` results ordered by similarity score (highest first).
/// Uses the configured `default_limit` if `limit` is `None`.
pub fn similarity_search(
  conn: Connection,
  config: PgVectorConfig,
  query_embedding: List(Float),
  limit: Option(Int),
) -> Result(List(SearchResult), PgVectorError) {
  use validated <- result.try(validate_dimensions(
    query_embedding,
    config.dimensions,
  ))
  let vector_str = format_vector(validated)
  let n = option.unwrap(limit, config.default_limit)
  let table = sanitize_identifier(config.table_name)
  let sql =
    "SELECT id::text, content, embedding::text, metadata::text, "
    <> "1 - (embedding <=> $1::vector) as score FROM "
    <> table
    <> " ORDER BY embedding <=> $1::vector LIMIT $2"

  let row_decoder = {
    use id <- decode.field("id", decode.string)
    use content <- decode.field("content", decode.string)
    use embedding_str <- decode.field("embedding", decode.string)
    use metadata_str <- decode.field("metadata", decode.string)
    use score <- decode.field("score", decode.float)
    let embedding = parse_vector(embedding_str)
    let metadata = parse_metadata(metadata_str)
    decode.success(SearchResult(
      record: EmbeddingRecord(id:, content:, embedding:, metadata:),
      score:,
    ))
  }

  pog.query(sql)
  |> pog.parameter(pog.text(vector_str))
  |> pog.parameter(pog.int(n))
  |> pog.returning(row_decoder)
  |> pog.execute(conn)
  |> result.map_error(QueryFailed)
  |> result.map(fn(returned) { returned.rows })
}

/// Delete an embedding record by its UUID.
pub fn delete(
  conn: Connection,
  config: PgVectorConfig,
  id: String,
) -> Result(Bool, PgVectorError) {
  let table = sanitize_identifier(config.table_name)
  let sql = "DELETE FROM " <> table <> " WHERE id = $1::uuid"
  pog.query(sql)
  |> pog.parameter(pog.text(id))
  |> pog.execute(conn)
  |> result.map_error(QueryFailed)
  |> result.map(fn(returned) { returned.count > 0 })
}

/// Delete all embeddings matching a metadata key-value pair.
/// The key is validated to contain only safe identifier characters
/// (alphanumeric, underscore, hyphen) to prevent SQL injection.
pub fn delete_by_metadata(
  conn: Connection,
  config: PgVectorConfig,
  key: String,
  value: String,
) -> Result(Int, PgVectorError) {
  case validate_identifier(key) {
    False -> Error(InvalidMetadataKey(key))
    True -> {
      let table = sanitize_identifier(config.table_name)
      let sql =
        "DELETE FROM " <> table <> " WHERE metadata->>'" <> key <> "' = $1"
      pog.query(sql)
      |> pog.parameter(pog.text(value))
      |> pog.execute(conn)
      |> result.map_error(QueryFailed)
      |> result.map(fn(returned) { returned.count })
    }
  }
}

// ============================================================================
// MCP Tool Integration (RAG)
// ============================================================================

/// Retrieve relevant context for RAG using a query embedding.
///
/// Returns a list of content strings ranked by similarity.
/// Designed for integration with MCP tools.
pub fn retrieve_context(
  conn: Connection,
  config: PgVectorConfig,
  query_embedding: List(Float),
  max_results: Int,
) -> Result(List(String), PgVectorError) {
  use results <- result.map(similarity_search(
    conn,
    config,
    query_embedding,
    Some(max_results),
  ))
  list.map(results, fn(r) { r.record.content })
}

// ============================================================================
// SQL Safety Helpers
// ============================================================================

/// Validate that a string contains only safe identifier characters
/// (alphanumeric, underscore, hyphen). Prevents SQL injection in
/// contexts where parameterized queries can't be used (identifiers).
fn validate_identifier(s: String) -> Bool {
  s != ""
  && string.to_graphemes(s)
  |> list.all(fn(c) { is_safe_identifier_char(c) })
}

fn is_safe_identifier_char(c: String) -> Bool {
  case c {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "_"
    | "-" -> True
    _ -> False
  }
}

/// Sanitize a SQL identifier by quoting it with double quotes and escaping
/// any embedded double quotes. This is the PostgreSQL-standard way to safely
/// use dynamic identifiers.
fn sanitize_identifier(name: String) -> String {
  "\"" <> string.replace(name, "\"", "\"\"") <> "\""
}

// ============================================================================
// Internal Helpers
// ============================================================================

/// Serialize metadata dict to JSON string.
fn metadata_to_json(metadata: Dict(String, String)) -> String {
  let pairs =
    dict.to_list(metadata)
    |> list.map(fn(pair) {
      let #(k, v) = pair
      json.string(k) |> json.to_string
      <> ":"
      <> json.string(v) |> json.to_string
    })
    |> string.join(",")
  "{" <> pairs <> "}"
}

/// Parse a pgvector string like "[1.0,2.0,3.0]" into a List(Float).
fn parse_vector(vector_str: String) -> List(Float) {
  vector_str
  |> string.replace("[", "")
  |> string.replace("]", "")
  |> string.split(",")
  |> list.filter_map(fn(s) { float.parse(string.trim(s)) })
}

/// Parse a JSONB metadata string into a Dict(String, String).
/// Returns empty dict on parse failure.
fn parse_metadata(metadata_str: String) -> Dict(String, String) {
  let decoder = decode.dict(decode.string, decode.string)
  case json.parse(metadata_str, decoder) {
    Ok(d) -> d
    Error(_) -> dict.new()
  }
}
