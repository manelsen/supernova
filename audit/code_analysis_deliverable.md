# Penetration Test Scope & Boundaries

**Primary Directive:** Your analysis is strictly limited to the **network-accessible attack surface** of the application. All subsequent tasks must adhere to this scope. Before reporting any finding (e.g., an entry point, a vulnerability sink), you must first verify it meets the "In-Scope" criteria.

### In-Scope: Network-Reachable Components
A component is considered **in-scope** if its execution can be initiated, directly or indirectly, by a network request that the deployed application server is capable of receiving. This includes:
- Publicly exposed web pages and API endpoints.
- Endpoints requiring authentication via the application's standard login mechanisms.
- Any developer utility, debug console, or script that has been mistakenly exposed through a route or is otherwise callable from other in-scope, network-reachable code.

### Out-of-Scope: Locally Executable Only
A component is **out-of-scope** if it **cannot** be invoked through the running application's network interface and requires an execution context completely external to the application's request-response cycle. This includes tools that must be run via:
- A command-line interface (e.g., `go run ./cmd/...`, `python scripts/...`).
- A development environment's internal tooling (e.g., a "run script" button in an IDE).
- CI/CD pipeline scripts or build tools (e.g., Dagger build definitions).
- Database migration scripts, backup tools, or maintenance utilities.
- Local development servers, test harnesses, or debugging utilities.
- Static files or scripts that require manual opening in a browser (not served by the application).

---

## 1. Executive Summary

**Supernova** is a multi-agent AI Operating System built on the Erlang/OTP BEAM virtual machine using the Gleam programming language. The application functions as a sophisticated chatbot framework that integrates with 9+ messaging platforms (Discord, Telegram, Slack, Matrix, Lark, Google Chat, Mattermost, WeChat Work, WhatsApp) to provide AI-powered conversational capabilities through Large Language Models (LLMs).

From a security perspective, Supernova presents an **unusual attack surface** due to its architecture. Unlike traditional web applications, it does not expose a user-facing HTTP API or web interface. Instead, it operates as a bot that receives messages from external platforms and processes them through an LLM-backed agent system. The primary network-exposed component is a health check server on port 8080, which provides unauthenticated access to `/health`, `/health/live`, `/health/ready`, and `/metrics` endpoints.

**Critical security concerns identified include:**
- **Command Injection vulnerabilities** in the safe shell implementation and process FFI modules where user commands may bypass sanitization
- **XSS/JavaScript injection** in the browser runner script that evaluates user-provided JavaScript
- **Path traversal risks** in file system operations despite workspace guard protections
- **Unauthenticated health/metrics endpoints** exposing system information on port 8080
- **No rate limiting** on the health server or message processing pipeline

**Architecture Note:** The application uses an actor-based model with kernel/userland separation. Security relies heavily on workspace policies, budget controls, and capability manifests rather than traditional web security controls. There is no user authentication system - identity is derived from platform-specific tokens (Discord bot token, Telegram bot token, etc.).

---

## 2. Architecture & Technology Stack

### Framework & Language

**Primary Language:** Gleam 1.15.0
- Statically typed functional language compiling to Erlang BEAM bytecode
- Strong type safety provides inherent protection against many injection classes
- Pattern matching and immutable data structures reduce state-related vulnerabilities

**Runtime Platform:** Erlang/OTP 28
- Actor model concurrency with lightweight processes
- OTP supervisors provide fault tolerance and isolation
- BEAM VM security model isolates processes

**Key Dependencies:**
- `mist 6.0.2` - HTTP server (health checks)
- `wisp 2.2.2` - WebSocket server (real-time streaming)
- `pog 4.1.0` - PostgreSQL client with connection pooling
- `stratus 2.0.0` - HTTP client (external API calls)
- `gleam_hackney` - HTTP client adapter
- `envoy 1.1.0` - Configuration management

### Architectural Pattern

**Actor Model with Kernel/Userland Split:**

The application implements an operating system-like architecture:

1. **Kernel Space** (`src/supernova/core/`):
   - `kernel_scheduler/` - Process scheduling
   - `budget_policy/` - Resource quota enforcement
   - `workspace_policy/` - File system access control
   - `capability_manifest/` - Tool authorization
   - `resource_ledger/` - Usage accounting
   - `audit_log/` - Security event logging
   - `syscall/` - System call interface

2. **Userland** (`src/supernova/adapters/`):
   - Channel adapters (Discord, Telegram, Slack, etc.)
   - Tool implementations (file system, shell, etc.)
   - LLM provider clients

**Trust Boundary:** The kernel gateway acts as the security boundary between userland agents and privileged operations. All system calls pass through policy enforcement.

### Critical Security Components

1. **Workspace Guard** (`src/supernova/core/workspace_guard.gleam`):
   - Path traversal prevention (blocks `..` sequences)
   - Absolute path blocking
   - Workspace confinement enforcement

2. **Budget Policy** (`src/supernova/core/budget_policy/`):
   - Token consumption limits per agent
   - Tool call rate limiting
   - Recursion depth limits
   - Sub-agent concurrency limits

3. **Security Audit** (`src/supernova/core/security_audit.gleam`):
   - Shell execution logging
   - File operation logging
   - Network access logging
   - Policy violation tracking

---

## 3. Authentication & Authorization Deep Dive

### Authentication Mechanisms

**No Traditional Authentication:**
Supernova does not implement user authentication. Instead, authentication is delegated to platform-specific mechanisms:

**Platform Token Authentication:**
| Platform | Token Type | Location |
|----------|------------|----------|
| Discord | Bot Token | `src/supernova/adapters/discord_rest.gleam` |
| Telegram | Bot Token | `src/supernova/adapters/telegram.gleam` |
| Matrix | Access Token | `src/supernova/adapters/matrix.gleam` |
| Slack | Bot Token | `src/supernova/adapters/slack.gleam` |
| Lark | Tenant Token | `src/supernova/adapters/lark.gleam` |

**Discord Authorization Header Example:**
```gleam
% src/supernova/adapters/discord_rest.gleam
let authorization = "Bot " <> bot_token
```

**Session Resolution:**
- Location: `src/supernova/channel/session.gleam`
- Session IDs constructed from channel-specific identifiers:
  - Telegram: `"telegram:" <> channel_id`
  - Discord: `"discord:" <> channel_id <> ":" <> user_id`

### Authorization Model

**Workspace Policy System** (Primary Authorization):

Location: `src/supernova/core/workspace_policy/`

**Operations Protected:**
- `OpRead` - Read files/directories
- `OpWrite` - Write files
- `OpShell` - Execute shell commands

**Policy Rules:**
- Per-agent policy configuration
- Allowed/denied path prefixes
- External read permission flag
- Parent-child inheritance for sub-agents

**Policy Enforcement Point:**
```gleam
% src/supernova/core/workspace_policy/pure.gleam
pub fn check_path_access(policy: Policy, path: String, op: Op) -> Result(Nil, Violation)
```

### Session Management

**No HTTP Cookies:** Session management does not use cookies as the application operates through chat APIs.

**Session Context:**
- Location: `src/supernova/core/session/context.gleam`
- Each session has:
  - Unique session ID
  - Key-value bindings for state
  - Workspace path (defaults to `/tmp/supernova/<session_id>`)

**Session Supervision:**
- Location: `src/supernova/core/session/supervisor.gleam`
- Each session runs as an independent actor for fault isolation

### SSO/OAuth/OIDC Flows

**Not Implemented:** No OAuth, OIDC, or SSO flows exist in the codebase. No `state` or `nonce` parameter validation code is present. The application relies entirely on platform-provided authentication (Discord bot tokens, Telegram bot tokens, etc.).

---

## 4. Data Security & Storage

### Database Security

**PostgreSQL with pgvector Extension:**
- Location: `src/supernova/adapters/pgvector.gleam`
- Connection pooling via `pog` library (configurable pool size, default: 10)

**Query Safety Analysis:**
```gleam
% Example parameterized query (pgvector.gleam, lines 322-325)
pog.query(sql)
|> pog.parameter(pog.text(record.content))
|> pog.parameter(pog.text(vector_str))
|> pog.parameter(pog.text(metadata_json))
```

**Positive Security Controls:**
- All database queries use parameterized statements
- No string concatenation in SQL queries
- Connection credentials stored in environment variables
- PostgreSQL 16 with modern security features

**Potential Concerns:**
- No row-level security (RLS) detected
- Single database user for all operations
- No query result size limiting

### Data Flow Security

**Sensitive Data Paths:**

1. **User Messages → LLM Providers:**
   - Messages flow from external platforms → channel adapters → LLM providers
   - No encryption at rest for message content
   - Transit security relies on HTTPS to LLM APIs

2. **Embeddings Storage:**
   - User content converted to vectors via OpenAI/other embedding APIs
   - Stored in PostgreSQL with pgvector
   - Metadata stored as JSONB alongside vectors

3. **Configuration Data:**
   - API keys flow from environment variables → config module → channel adapters
   - No runtime encryption of in-memory secrets

### Secret Management

**Environment Variable Pattern:**
- All secrets accessed via `envoy.get()` from environment variables
- Pattern: `SUPERNOVA_{COMPONENT}_{KEY}`
- Example: `SUPERNOVA_OPENAI_API_KEY`, `SUPERNOVA_DISCORD_TOKEN`

**Configuration Priority:**
```gleam
% config.gleam - environment variables override file configuration
let token = option.or(env_token, file_token)
```

**Security Implications:**
- Secrets visible in process environment (accessible to privileged users)
- No secret rotation mechanism
- No integration with secret managers (HashiCorp Vault, AWS Secrets Manager)
- Docker environment variables may leak in inspect commands

### Multi-Tenant Data Isolation

**Session-Level Isolation:**
- Each session maintains separate context and workspace
- No database-level tenant isolation
- Vector embeddings share database without tenant separation

**Assessment:** Multi-tenancy is implemented at application level only, not at infrastructure level. A database compromise would expose all tenant data.

---

## 5. Attack Surface Analysis

### External Entry Points

#### Health Check Server (Port 8080)
**File:** `src/supernova/health/server.gleam`

| Endpoint | Method | Auth | Description | Risk Level |
|----------|--------|------|-------------|------------|
| `/health` | GET | None | General health status | Low |
| `/health/live` | GET | None | Liveness probe | Low |
| `/health/ready` | GET | None | Readiness probe | Low |
| `/metrics` | GET | None | Prometheus metrics | Medium |

**Security Concerns:**
- **No authentication required** - All endpoints are publicly accessible
- **Metrics exposure** - The `/metrics` endpoint may expose sensitive operational data (process information, connection counts, internal state)
- **No rate limiting** - Endpoints have no brute force protection
- **No security headers** - Missing CORS, CSP, X-Frame-Options headers

**Network Binding:** `0.0.0.0:8080` (all interfaces)

#### Channel Adapters (External Platform Integration)
**Files:** `src/supernova/adapters/*.gleam`

The application receives messages from external messaging platforms via platform-specific APIs:

| Platform | Protocol | Authentication | Entry Type |
|----------|----------|----------------|------------|
| Discord | WebSocket Gateway + REST | Bot Token | Message Reception |
| Telegram | Long Polling / Webhook | Bot Token | Message Reception |
| Slack | Event Subscription | Bot Token + Signing Secret | Webhook |
| Matrix | Client-Server API | Access Token | Message Reception |
| Lark | Webhook | App Token | Webhook |
| Google Chat | Event Subscription | Service Account | Webhook |
| Mattermost | WebSocket + REST | Bot Token | Message Reception |
| WeChat Work | Webhook | Webhook URL | Message Reception |
| WhatsApp | Webhook | Bridge URL | Message Reception |

**Security Model:**
- Authentication delegated to external platforms
- Each platform validates bot/user identity before delivering messages
- Supernova trusts platform-provided user identification

#### MCP (Model Context Protocol) Servers
**File:** `src/supernova/adapters/mcp.gleam`

- **Transport:** STDIO JSON-RPC (not network-accessible)
- **Configuration:** Defined in `supernova.yaml` under `mcp_servers`
- **Risk:** Local-only, requires filesystem access to configure

### Internal Service Communication

**Database Connections:**
- PostgreSQL on port 5432 (internal network)
- Connection pooling with `pog` library
- Credentials from environment variables

**LLM Provider APIs:**
- OpenAI API: `https://api.openai.com/v1/chat/completions`
- Anthropic API: `https://api.anthropic.com/v1/messages`
- Ollama: `http://localhost:11434/v1/chat/completions` (configurable)

**Trust Boundaries:**
1. **External Platforms → Supernova:** Trust established via platform-specific tokens
2. **Supernova → LLM Providers:** Trust via API keys
3. **Supernova → PostgreSQL:** Trust via database credentials
4. **User Sessions → Kernel:** Trust via workspace policies

### Input Validation Patterns

**Path Validation (Workspace Guard):**
**File:** `src/supernova/core/workspace_guard.gleam`

```gleam
% Blocks path traversal
let blocked_patterns = [".."]

% Blocks absolute paths
case string.starts_with(path, "/") {
  True -> Error(AbsolutePathBlocked)
  False -> ...
}
```

**Command Validation (Safe Shell):**
**File:** `src/supernova/tools/safe_shell.gleam`

- Whitelist of allowed commands (`ls`, `pwd`, `cat`, `grep`, etc.)
- Blocks shell operators (`;`, `|`, `&&`, `$()`, backticks)
- **CRITICAL GAP:** Validation may be bypassed via FFI layer (see Section 9)

**JSON Sanitization:**
- JSON string escaping in channel adapters
- No HTML sanitization (no web interface)

### Background Processing

**Session Supervision:**
**File:** `src/supernova/core/session/supervisor.gleam`

- Each session runs as independent OTP actor
- Fault isolation between sessions
- Resource budgets enforced per-session

**Kernel Scheduler:**
**File:** `src/supernova/core/kernel_scheduler/`

- Manages agent execution scheduling
- Enforces budget policies
- Handles sub-agent spawning

**Async Job Security:**
- Jobs inherit parent session's workspace policy
- Budget limits apply to async operations
- Audit logging for all privileged operations

---

## 6. Infrastructure & Operational Security

### Secrets Management

**Storage Mechanism:** Environment variables only

**Pattern:**
```
SUPERNOVA_OPENAI_API_KEY        # OpenAI API key
SUPERNOVA_ANTHROPIC_API_KEY     # Anthropic API key
SUPERNOVA_DISCORD_TOKEN         # Discord bot token
SUPERNOVA_TELEGRAM_TOKEN        # Telegram bot token
SUPERNOVA_MATRIX_TOKEN          # Matrix access token
SUPERNOVA_DATABASE_USER         # PostgreSQL username
SUPERNOVA_DATABASE_password     # PostgreSQL password
```

**Configuration File:** `supernova.yaml` (YAML format)

**Security Concerns:**
- No encryption at rest
- No secret rotation mechanism
- Visible in `docker inspect` output
- Environment variables logged in process listings
- No integration with external secret managers

### Configuration Security

**Environment Separation:**
- Configuration loaded from `supernova.yaml` with environment variable overrides
- No explicit dev/staging/production environment flags
- Same configuration format for all environments

**Infrastructure Security Headers:**
- **No HSTS configuration** found in codebase
- **No CSP headers** defined
- **No CORS configuration** for health server
- **No X-Frame-Options, X-Content-Type-Options headers**

**Docker Configuration:**
**File:** `Dockerfile`
- Base image: `erlang:28-alpine`
- No security hardening in Dockerfile
- Secrets passed via environment variables

### External Dependencies

**Critical Dependencies:**
| Package | Version | Purpose | Security Concern |
|---------|---------|---------|-------------------|
| `mist` | 6.0.2 | HTTP server | Well-maintained |
| `wisp` | 2.2.2 | WebSocket | No known vulnerabilities |
| `pog` | 4.1.0 | PostgreSQL client | Uses parameterized queries |
| `stratus` | 2.0.0 | HTTP client | No SSRF sinks found |
| `gleam_hackney` | N/A | HTTP client | No SSRF sinks found |

**LLM Provider APIs:**
- OpenAI API (api.openai.com)
- Anthropic API (api.anthropic.com)
- Ollama (localhost:11434)
- Groq (api.groq.com)
- OpenRouter (openrouter.ai)

### Monitoring & Logging

**Audit Logging:**
**File:** `src/supernova/core/security_audit.gleam`

**Logged Events:**
- Shell execution (ALLOWED/BLOCKED)
- File operations (read/write)
- Network access
- Policy violations

**Log Format:**
```
[AUDIT] [ALLOWED/BLOCKED] [session:ID] operation: details
```

**Observability:**
- OpenTelemetry integration for tracing
- Custom metrics collection
- Health check endpoints for monitoring

**Log Sanitization:**
- No PII redaction detected
- Session IDs logged
- File paths logged
- No API key redaction (stored separately)

---

## 7. Overall Codebase Indexing

The Supernova codebase follows a functional architecture organized around the **Actor Model** pattern of Erlang/OTP. The project is written in **Gleam** (a statically-typed functional language that compiles to Erlang BEAM bytecode), The directory structure reflects clear separation of concerns between core system components, adapters, and external platforms, and LLM integrations.

**Top-Level Organization:**
- `/src/supernova/` - Main source code directory
  - `supernova.gleam` - Application entry point
  - `adapters/` - Platform-specific adapters (Discord, Telegram, Slack, etc.)
  - `channel/` - Message routing and session management
  - `core/` - Kernel components (scheduler, policies, guards)
  - `llm/` - LLM provider integrations
  - `health/` - HTTP health check server
  - `tools/` - Utility tools (file system, shell, browser)

**Build and Configuration:**
- `gleam.toml` - Gleam project configuration and dependencies
- `manifest.toml` - Additional manifest configuration
- `supernova.yaml` - Application configuration (YAML format)
- `Dockerfile` - Multi-stage Docker build for Erlang/OTP
- `docker-compose.yml` - Service orchestration (PostgreSQL + Supernova)

**Foreign Function Interface (FFI) Layer:**
- `/src/supernova_*_ffi.erl` - Erlang FFI implementations for low-level operations
  - `supernova_file_system_ffi.erl` - File operations
  - `supernova_safe_shell_ffi.erl` - Shell command execution
  - `supernova_process_ffi.erl` - Process management
  - `supernova_mcp_ffi.erl` - MCP protocol handling
  - `supernova_browser_ffi.erl` - Browser automation

**Documentation:**
- `/docs/` - Comprehensive documentation including architecture, operations, and API research
- `/examples/` - Example configuration files

**Security-Relevant Structure:**
The codebase separates security controls into distinct modules:
- `core/workspace_guard.gleam` - Path confinement
- `core/workspace_policy/` - Authorization policies
- `core/budget_policy/` - Resource quotas
- `core/security_audit.gleam` - Audit logging
- `tools/safe_shell.gleam` - Command sanitization

This organization facilitates security review by concentrating sensitive operations in dedicated modules with clear interfaces.

---

## 8. Critical File Paths

### Configuration
- `supernova.yaml` - Main application configuration file
- `gleam.toml` - Gleam project dependencies
- `docker-compose.yml` - Docker service orchestration
- `Dockerfile` - Container build definition
- `.env.example` - Environment variable template

### Authentication & Authorization
- `src/supernova/core/workspace_guard.gleam` - Path confinement validation
- `src/supernova/core/workspace_policy/actor.gleam` - Workspace policy actor
- `src/supernova/core/workspace_policy/pure.gleam` - Policy evaluation logic
- `src/supernova/channel/session.gleam` - Session resolution and management

### API & Routing
- `src/supernova/health/server.gleam` - HTTP health check server (port 8080)
- `src/supernova/adapters/discord_router.gleam` - Discord message routing
- `src/supernova/adapters/telegram.gleam` - Telegram bot integration
- `src/supernova/adapters/slack.gleam` - Slack integration
- `src/supernova/adapters/matrix.gleam` - Matrix integration

### Data Models & DB Interaction
- `src/supernova/adapters/pgvector.gleam` - PostgreSQL with pgvector operations
- `src/supernova/config.gleam` - Configuration types and loading

### Sensitive Data & Secrets Handling
- `src/supernova/config.gleam` - Environment variable access for secrets
- `src/supernova/adapters/discord_rest.gleam` - Discord API token usage

### Middleware & Input Validation
- `src/supernova/tools/safe_shell.gleam` - Shell command sanitization
- `src/supernova/tools/file_system.gleam` - File operation validation
- `src/supernova/core/workspace_guard.gleam` - Path traversal prevention

### FFI (Foreign Function Interface) - HIGH RISK
- `src/supernova_safe_shell_ffi.erl` - Shell execution FFI (COMMAND INJECTION RISK)
- `src/supernova_file_system_ffi.erl` - File operations FFI (PATH TRAVERSAL RISK)
- `src/supernova_process_ffi.erl` - Process management FFI (COMMAND INJECTION RISK)
- `src/supernova_browser_ffi.erl` - Browser automation FFI

### Logging & Monitoring
- `src/supernova/core/security_audit.gleam` - Security audit logging
- `src/supernova/core/session/logger.gleam` - Session logging
- `src/supernova/core/audit_log/` - Audit log directory

### Infrastructure & Deployment
- `docker-compose.yml` - Service configuration (PostgreSQL + App)
- `Dockerfile` - Container build instructions

### Additional High-Risk Files
- `scripts/browser_runner.mjs` - Browser automation script (XSS/JS INJECTION RISK)

