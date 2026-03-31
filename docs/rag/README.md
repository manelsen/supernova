# Skill: RAG Documentation Fetcher

Downloads Gleam/OTP package documentation from HexDocs for RAG ingestion.

## Usage

```bash
# Download all docs
./scripts/fetch_docs.sh

# Docs are saved to:
#   docs/rag/           - Raw HTML
#   docs/rag/markdown/  - Converted to Markdown
```

## Packages Included

| Package | Description |
|---------|-------------|
| `gleam_stdlib` | Gleam standard library |
| `gleam_otp` | OTP actor/supervisor patterns |
| `wisp` | Web framework |
| `mist` | HTTP server adapter |
| `yay` | YAML parsing |
| `envoy` | Environment variables |
| `gleam_json` | JSON serialization |
| `gleam_http` | HTTP client/server |
| `gleam_hackney` | HTTP requests |
| `gleam_time` | Time/date utilities |
| `pog` | PostgreSQL driver |

## LSP Integration

Gleam has a built-in LSP:

```bash
# Run the language server (for editors)
gleam lsp

# VS Code: install gleam-lang/vscode-gleam extension
# Neovim: use nvim-lspconfig with gleam_lsp
```

## For RAG Ingestion

The markdown files in `docs/rag/markdown/` can be ingested into:
- Vector databases (Pinecone, Qdrant, Chroma)
- Local embedding models
- LLM context windows

Typical chunking strategy:
- By module/section headers
- 500-1000 tokens per chunk
- Overlap 10-20% between chunks
