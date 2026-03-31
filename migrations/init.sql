-- Supernova initial database schema
-- Applied automatically via docker-entrypoint-initdb.d

-- Enable pgvector extension for embedding storage
CREATE EXTENSION IF NOT EXISTS vector;

-- Embeddings table for agent memory (matches pgvector.gleam ensure_schema)
CREATE TABLE IF NOT EXISTS embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  embedding vector(1536) NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'
);

-- IVFFlat index for approximate nearest neighbor search
CREATE INDEX IF NOT EXISTS embeddings_embedding_idx
  ON embeddings USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);
