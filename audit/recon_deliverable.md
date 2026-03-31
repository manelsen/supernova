# Reconnaissance Deliverable:

## 0) HOW TO READ THIS
This reconnaissance report provides a comprehensive map of the Supernova application's attack surface, with special emphasis on authorization and privilege escalation opportunities for the Authorization Analysis Specialist.

**Key Sections for Authorization Analysis:**
- **Section 4 (API Endpoint Inventory):** Contains authorization details for each endpoint - focus on "Required Role" and "Object ID Parameters" columns to identify IDOR candidates.
- **Section 6.4 (Guards Directory):** Catalog of authorization controls - understand what each guard means before analyzing vulnerabilities.
- **Section 7 (Role & Privilege Architecture):** Complete role hierarchy and privilege mapping - use this to understand the privilege lattice and identify escalation targets.
- **Section 8 (Authorization Vulnerability Candidates):** Pre-prioritized lists of endpoints for horizontal, vertical, and context-based authorization testing.

**How to Use the Network Mapping (Section 6):** The entity/flow mapping shows system boundaries and data sensitivity levels. Pay special attention to flows marked with authorization guards and entities handling PII/sensitive data.

**Priority Order for Testing:** Start with Section 8's High-priority horizontal candidates, then vertical escalation endpoints for each role level, finally context-based workflow bypasses.

---

## 1. Executive Summary

**Supernova** is a multi-agent AI Operating System built on the Erlang/OTP BEAM virtual machine using the Gleam programming language. The application functions as a sophisticated chatbot framework that integrates with 9+ messaging platforms (Discord, Telegram, Slack, Matrix, Lark, Google Chat, Mattermost, WeChat Work, WhatsApp) to provide AI-powered conversational capabilities through Large Language Models (LLMs).

**Unique Architecture:** Unlike traditional web applications, Supernova does not expose a user-facing HTTP API or web interface for end users. Instead, it operates as a bot that receives messages from external platforms and processes them through an LLM-backed agent system. The primary network-exposed component is a health check server on port 8080.

**Attack Surface Characteristics:**
- **Health Server (Port 8080):** Unauthenticated endpoints `/health`, `/health/live`, `/health/ready`, `/metrics`
- **Channel Adapters:** 9 messaging platform integrations receiving user messages
- **Tool Execution Pipeline:** User messages flow through LLM to tool execution (shell, filesystem, browser, etc.)
- **Kernel/Userland Architecture:** Security relies on workspace policies, budget controls, and capability manifests

**Critical Security Model:**
- No traditional user authentication - identity derived from platform tokens
- Session IDs are predictable: `platform:channel_id:user_id`
- Authorization enforced via workspace policies, budget policies, and capability manifests
- All privileged operations pass through a syscall gateway with policy enforcement

---

## 2. Technology & Service Map

### Frontend
- **None** - No user-facing web interface
- **Browser Automation:** Playwright-based browser runner (`scripts/browser_runner.mjs`)

### Backend
- **Language:** Gleam 1.15.0 (statically typed functional language)
- **Runtime:** Erlang/OTP 28 (BEAM VM)
- **HTTP Server:** `mist 6.0.2` (health checks)
- **WebSocket:** `wisp 2.2.2` (real-time streaming)
- **Database Client:** `pog 4.1.0` (PostgreSQL with connection pooling)
- **HTTP Client:** `stratus 2.0.0`, `gleam_hackney`

### Infrastructure
- **Database:** PostgreSQL 16 with pgvector extension
- **Containerization:** Docker (erlang:28-alpine base image)
- **Orchestration:** docker-compose.yml

### Identified Subdomains/Hosts
- `localhost:8080` - Health check server
- `api.openai.com` - OpenAI LLM provider
- `api.anthropic.com` - Anthropic LLM provider
- `api.groq.com` - Groq LLM provider
- `openrouter.ai` - OpenRouter LLM provider
- `localhost:11434` - Ollama local LLM
- `gateway.discord.gg` - Discord WebSocket gateway
- `api.telegram.org` - Telegram Bot API
- Platform-specific endpoints for Slack, Matrix, Lark, etc.

### Open Ports & Services
| Port | Service | Purpose |
|------|---------|---------|
| 8080 | HTTP (mist) | Health check server, metrics |
| 5432 | PostgreSQL | Vector storage (internal) |
| 11434 | Ollama | Local LLM inference (optional) |

---

## 3. Authentication & Session Management Flow

### Entry Points
The application does NOT have traditional login/registration endpoints. Instead:

| Entry Point | Description |
|-------------|-------------|
| Platform-specific | Users authenticate through external platforms (Discord, Telegram, Slack, etc.) |
| Health Server | `/health` endpoints require NO authentication |
| Channel Messages | Messages arrive via platform adapters with platform-provided identity |

### Authentication Mechanism

**Step-by-Step Process:**

1. **Platform Authentication:**
   - Users authenticate to their messaging platform (Discord, Telegram, etc.)
   - Platform validates user identity and delivers messages to Supernova via bot webhooks/polling

2. **Token Validation:**
   - Discord: Bot token validated via Discord Gateway (`discord_gateway.gleam:171-202`)
   - Telegram: Bot token validated via API responses (`telegram.gleam:433`)
   - Slack: Bot token validated via Bearer header (`slack_adapter.gleam:676`)

3. **Session Resolution:**
   - Location: `src/supernova/channel/session.gleam:29-74`
   - Session IDs constructed from platform identifiers:
     - Telegram: `telegram:{channel_id}`
     - Discord: `discord:{channel_id}:{user_id}`
     - Slack: `slack:{channel_id}:{user_id}`
     - Matrix: `matrix:{channel_id}:{user_id}`

4. **Session Storage:**
   - In-memory only via Erlang/OTP actors
   - No persistent storage (lost on restart)
   - No session expiration mechanism

### Code Pointers

| Component | File | Lines |
|----------|------|-------|
| Session Resolution | `src/supernova/channel/session.gleam` | 29-74 |
| Session Server | `src/supernova/core/session/server.gleam` | 26-86 |
| Session Supervisor | `src/supernova/core/session/supervisor.gleam` | 71-74, 189-200 |
| Discord Gateway Auth | `src/supernova/adapters/discord_gateway.gleam` | 171-202 |
| Telegram Auth | `src/supernova/adapters/telegram.gleam` | 433 |

### 3.1 Role Assignment Process

**Role Determination:**
- Roles are NOT assigned per traditional user authentication
- Instead, **agent-level roles** exist for LLM agent instances:
  - Default agent role defined by workspace policy
  - Capability manifest defines allowed/denied tools per agent
  - Budget policy defines resource limits per agent

**Default Agent Role:**
- Workspace: `workspaces/<agent_id>/`
- Allowed tools: `filesystem`, `web`, `read_file`, `write_file`, `list_directory`
- Denied tools: `shell`, `execute_command`, `github`, `git_push`, `git_commit`

**Role Upgrade Path:**
- Sub-agents inherit parent's workspace (reduced budget)
- External read permission can be granted via `external_read_allowed: true`
- Unlimited budget available via `unlimited_budget_config()`

**Code Implementation:**
| File | Lines | Purpose |
|------|-------|---------|
| `src/supernova/core/workspace_policy/types.gleam` | 79-86 | Default rule definition |
| `src/supernova/core/capability_manifest/types.gleam` | 59-76 | Default allowed/denied tools |
| `src/supernova/core/budget_policy/types.gleam` | 116-123 | Default budget limits |

### 3.2 Privilege Storage & Validation

**Storage Location:**
- Workspace policies: In-memory via policy actor (`workspace_policy/actor.gleam`)
- Capability manifests: In-memory via manifest actor (`capability_manifest/actor.gleam`)
- Budget policies: In-memory via budget actor (`budget_policy/actor.gleam`)

**Validation Points:**
| Check Type | Location | File:Line |
|------------|----------|---------|
| Workspace policy | `workspace_policy/pure.gleam` | 28-58 |
| Budget check | `budget_policy/pure.gleam` | 269-295 |
| Capability check | `capability_manifest/pure.gleam` | 24-36 |
| Syscall gateway | `syscall/actor.gleam` | 191-253 |

**Cache/Session Persistence:**
- All policies stored in-memory only
- No expiration or refresh mechanism
- Lost on application restart

### 3.3 Role Switching & Impersonation

**Impersonation Features:**
- **Not Implemented** - No user impersonation capability
- Agent hierarchy exists (parent-child) but for resource inheritance, not impersonation

**Role Switching:**
- Sub-agents inherit reduced privileges (20% of parent budget by default)
- No temporary privilege elevation ("sudo mode")
- No audit trail for role changes (audit log is optional and not persisted)

**Code Implementation:**
- Parent-child relationship: `src/supernova/core/workspace_policy/pure.gleam:78-101`
- Budget inheritance: `src/supernova/core/budget_policy/pure.gleam:530-545`

---

## 4. API Endpoint Inventory

### Health Server Endpoints (Port 8080)

| Method | Endpoint Path | Required Role | Object ID Parameters | Authorization Mechanism | Description & Code Pointer |
|--------|---------------|---------------|---------------------|------------------------|---------------------------|
| GET | `/health` | anon | None | None | Health status with uptime. `health/server.gleam:41-55` |
| GET | `/health/live` | anon | None | None | Liveness probe (returns 404 - may not be implemented). `health/server.gleam:57-63` |
| GET | `/health/ready` | anon | None | None | Readiness probe (returns 404 - may not be implemented). `health/server.gleam:65-80` |
| GET | `/metrics` | anon | None | None | Prometheus metrics (returns 404 - may not be implemented). `health/server.gleam:82-91` |
| * | `*` (fallback) | anon | None | None | Returns 404 error. `health/server.gleam:93-96` |

**Note:** Live browser testing showed only `/health` is functional. Other documented endpoints return 404.

### Internal Channel Message Handlers

| Message Type | Handler | Required Role | Authorization | Code Pointer |
|--------------|---------|---------------|---------------|---------------|
| Discord Message | `discord_router.gleam:76-134` | Valid bot token | Platform token validation | `discord_router.gleam` |
| Telegram Message | `telegram_router.gleam:58-116` | Valid bot token | Platform token validation | `telegram_router.gleam` |
| Slack Message | `slack_router.gleam:56-114` | Valid bot token | Platform token validation | `slack_router.gleam` |
| Matrix Message | `matrix_router.gleam:56-114` | Valid bot token | Platform token validation | `matrix_router.gleam` |
| Generic Channel | `generic_channel_router.gleam:30-50` | Valid bot token | Platform token validation | `generic_channel_router.gleam` |

### Outbound API Calls (Client-Side)

| Method | Endpoint Pattern | Purpose | Code Pointer |
|--------|-----------------|---------|---------------|
| POST | `/channels/{id}/messages` | Discord send message | `discord_rest.gleam:759-778` |
| PATCH | `/channels/{id}/messages/{msg_id}` | Discord edit message | `discord_rest.gleam:780-798` |
| GET | `/bot{token}/getUpdates` | Telegram polling | `telegram.gleam:476-490` |
| POST | `/bot{token}/sendMessage` | Telegram send message | `telegram.gleam:1337-1355` |
| WebSocket | `wss://gateway.discord.gg` | Discord real-time events | `discord_gateway.gleam:553-558` |

---

## 5. Potential Input Vectors for Vulnerability Analysis

### URL Parameters
| Parameter | Endpoint | Source | Validation | Code Pointer |
|-----------|----------|--------|------------|--------------|
| None | Health endpoints | Query strings | None | `health/server.gleam:28-39` |

### POST Body Fields (JSON/Form)
| Field | Source | Validation | Code Pointer |
|-------|--------|------------|--------------|
| Message content | Platform messages | Bot filtering, empty check | `channel_common_router.gleam:58-99` |
| Tool arguments | LLM tool calls | JSON parsing, tool-specific | `executor.gleam` |
| File paths | File system tool | `workspace_guard` checks | `file_system.gleam:112-120` |
| Shell commands | Safe shell tool | Command whitelist, operator blocking | `safe_shell.gleam:68-88` |
| URLs | Web fetch tool | URL parsing only | `web.gleam:12-29` |
| JavaScript | Browser evaluate | JSON escaping only | `browser.gleam:79-84`, `browser_ffi.erl:248-253` |

### HTTP Headers
| Header | Usage | Validation | Code Pointer |
|--------|-------|------------|--------------|
| Authorization | Platform API calls | Platform-specific token validation | `discord_rest.gleam`, `telegram.gleam` |
| X-Forwarded-For | Not used | N/A | N/A |

### Cookie Values
| Cookie | Purpose | Validation | Code Pointer |
|--------|---------|------------|--------------|
| None | Application doesn't use cookies | N/A | N/A |

### Tool Input Vectors (Channel Message Processing)
| Tool | Input Parameter | Validation | Bypass Possibility | Code Pointer |
|------|-----------------|------------|-------------------|--------------|
| safe_shell | command | Whitelist + operator blocking | `cat /etc/passwd` allowed | `safe_shell.gleam:68-88` |
| file_system | path | `..` detection, absolute path block | URL encoding, null bytes | `file_system.gleam:112-120` |
| browser | url, script | URL parsing, JSON escape | Arbitrary URLs, arbitrary JS | `browser.gleam:79-84` |
| web_fetch | url | URL parsing | SSRF to internal URLs | `web.gleam:12-29` |
| process | command (spawn_background) | PID validation | Arbitrary command execution | `process_ffi.erl:39-68` |
| pgvector | key (delete_by_metadata) | Parameterized (partial) | SQL via key interpolation | `pgvector.gleam:396-412` |

---

## 6. Network & Interaction Map

### 6.1 Entities

| Title | Type | Zone | Tech | Data | Notes |
|-------|------|------|------|------|-------|
| Health Server | Service | App | Mist HTTP | Public | Unauthenticated health check endpoints |
| Channel Adapters | Service | App | Gleam/OTP | PII, Tokens | 9 platform integrations (Discord, Telegram, etc.) |
| Session Supervisor | Service | App | Gleam/OTP | Session State | In-memory session management |
| LLM Gateway | Service | App | Gleam | PII, Tokens | Multi-provider LLM integration |
| PostgreSQL | DataStore | Data | PostgreSQL 16 + pgvector | PII, Embeddings | Vector storage for memory |
| Discord Platform | ThirdParty | Internet | WebSocket/REST | Messages | External messaging platform |
| Telegram Platform | ThirdParty | Internet | REST API | Messages | External messaging platform |
| OpenAI API | ThirdParty | Internet | REST | PII, Prompts | LLM provider |
| Anthropic API | ThirdParty | Internet | REST | PII, Prompts | LLM provider |

### 6.2 Entity Metadata

| Title | Metadata |
|-------|----------|
| Health Server | Hosts: `0.0.0.0:8080`; Endpoints: `/health`, `/health/live`, `/health/ready`, `/metrics`; Auth: None; No rate limiting |
| Channel Adapters | Platforms: Discord, Telegram, Slack, Matrix, Lark, Google Chat, Mattermost, WeChat Work, WhatsApp; Auth: Platform tokens |
| Session Supervisor | Storage: In-memory Dict; Isolation: Per-session OTP actors; No persistence |
| LLM Gateway | Providers: OpenAI, Anthropic, Groq, OpenRouter, Ollama; Auth: API keys from env vars |
| PostgreSQL | Engine: PostgreSQL 16; Extension: pgvector; Connection: pog library with pooling; Credentials: From env vars |
| Discord Platform | Gateway: `wss://gateway.discord.gg`; API: `https://discord.com/api/v10`; Auth: Bot token |

### 6.3 Flows (Connections)

| FROM → TO | Channel | Path/Port | Guards | Touches |
|-----------|---------|-----------|--------|---------|
| User Browser → Health Server | HTTP | `:8080 /health` | None | Public |
| Discord Platform → Channel Adapter | WebSocket | `wss://gateway.discord.gg` | Platform token | Messages |
| Channel Adapter → Session Supervisor | Internal | Actor message | None | Session State |
| Session Supervisor → LLM Gateway | Internal | Function call | Budget policy | Prompts |
| LLM Gateway → OpenAI API | HTTPS | `api.openai.com` | API key | PII, Prompts |
| Tool Execution → PostgreSQL | TCP | `:5432` | None | Embeddings, Metadata |
| Tool Execution → File System | Internal | Local FS | Workspace policy | Files |
| Tool Execution → Shell | Internal | Erlang port | Safe shell whitelist | Command output |
| Browser Tool → External URL | HTTPS | Arbitrary URL | None | Web content |

### 6.4 Guards Directory

| Guard Name | Category | Statement |
|------------|----------|-----------|
| auth:platform | Auth | Requires valid platform bot token for message delivery |
| auth:none | Auth | No authentication required (health endpoints) |
| workspace:confine | Authorization | Path must be within agent's workspace directory |
| workspace:external_read | Authorization | Allows reading files outside workspace (OpRead only) |
| budget:tokens | Authorization | Token consumption limit per agent per hour |
| budget:tool_calls | Authorization | Tool call rate limit per agent per minute |
| budget:recursion | Authorization | Maximum recursion depth for sub-agents |
| capability:allow | Authorization | Tool must be in allowed_tools list |
| capability:deny | Authorization | Tool must NOT be in denied_tools list (takes precedence) |
| syscall:gateway | Authorization | All privileged operations pass through syscall gateway with policy enforcement |

---

## 7. Role & Privilege Architecture

### 7.1 Discovered Roles

| Role Name | Privilege Level | Scope/Domain | Code Implementation |
|-----------|-----------------|--------------|---------------------|
| anon | 0 | Global | No authentication (health endpoints) |
| platform_bot | 1 | Platform | Platform token validation (channel adapters) |
| agent_default | 2 | Session | Default workspace/capability/budget policies |
| agent_external_read | 3 | Session | Agent with `external_read_allowed: true` |
| agent_unlimited | 4 | Session | Agent with `unlimited_budget_config()` |

### 7.2 Privilege Lattice

```
Privilege Ordering (→ means "can access resources of"):
anon → platform_bot → agent_default → agent_external_read
                      ↓
                agent_unlimited (parallel to external_read)

Sub-agent Inheritance:
parent_agent → child_agent (inherits 20% budget, same workspace)
```

**Note:** No user impersonation or role switching mechanisms exist. Agent hierarchy is for resource inheritance only.

### 7.3 Role Entry Points

| Role | Default Landing | Accessible Route Patterns | Authentication Method |
|------|-----------------|---------------------------|----------------------|
| anon | `/health` | `/health`, `/health/*`, `/metrics` | None |
| platform_bot | N/A | Internal message handlers only | Platform token |
| agent_default | Session workspace | Tool execution via LLM | Session creation |
| agent_external_read | Session workspace | Tool execution + external file read | Session with policy |

### 7.4 Role-to-Code Mapping

| Role | Middleware/Guards | Permission Checks | Storage Location |
|------|-------------------|-------------------|------------------|
| anon | None | None | N/A |
| platform_bot | Platform token validation | `discord_gateway.gleam:302`, `telegram.gleam:433` | Config YAML / Env vars |
| agent_default | Workspace policy actor | `workspace_policy/pure.gleam:28-58` | In-memory actor |
| agent_default | Budget policy actor | `budget_policy/pure.gleam:269-295` | In-memory actor |
| agent_default | Capability manifest actor | `capability_manifest/pure.gleam:24-36` | In-memory actor |

---

## 8. Authorization Vulnerability Candidates

### 8.1 Horizontal Privilege Escalation Candidates

| Priority | Endpoint/Vector | Object ID Parameter | Data Type | Sensitivity |
|----------|-----------------|---------------------|-----------|-------------|
| High | Session ID prediction | `platform:channel_id:user_id` | Session state | Predictable format allows session hijacking |
| High | Workspace path access | `agent_id` in workspace path | File data | Access other agents' workspaces |
| Medium | Vector memory access | Session ID in pgvector | Embeddings | Access other sessions' stored memories |
| Medium | Tool execution context | Session ID | LLM responses | Potential cross-session data leakage |

**Explanation:** Session IDs follow predictable patterns (`discord:123456:789012`). If an attacker knows channel_id and user_id from public sources, they could potentially predict or forge session identifiers.

### 8.2 Vertical Privilege Escalation Candidates

| Target Role | Endpoint/Vector | Functionality | Risk Level |
|-------------|-----------------|---------------|------------|
| agent_external_read | `external_read_allowed: true` | Read files outside workspace | High |
| agent_unlimited | `unlimited_budget_config()` | Unlimited token consumption | Medium |
| agent_unlimited | Budget limit set to `-1` | Disable rate limiting | Medium |
| syscall_bypass | Gateway started without policies | No authorization checks | Critical |

**Explanation:** The syscall gateway can be started without policies via `start()` instead of `start_with_policies()`, bypassing all authorization. Budget limits can be disabled by setting to `-1`.

### 8.3 Context-Based Authorization Candidates

| Workflow | Endpoint | Expected Prior State | Bypass Potential |
|----------|----------|---------------------|------------------|
| Tool execution | `executor.run()` | Valid session, budget available | Direct tool invocation |
| File access | `file_system.read_authorized()` | Workspace policy allows | Policy bypass via path traversal |
| Shell execution | `safe_shell.execute()` | Command in whitelist | Whitelist bypass via `cat /etc/passwd` |
| Browser automation | `browser.evaluate()` | Valid session | Arbitrary JavaScript execution |

---

## 9. Injection Sources

### Command Injection Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| safe_shell command | `safe_shell.gleam:68-88` | User message → LLM → tool call → shell execution | Whitelist + operator blocking | `cat /etc/passwd`, `find / -name "*.env"` |
| process spawn_background | `process_ffi.erl:39-68` | Tool call → `open_port({spawn, Command})` | PID validation only | Arbitrary command execution |
| MCP server spawn | `mcp/stdio.gleam:133-164` | YAML config → `open_port({spawn, Command})` | None | Arbitrary process from config |

### SQL Injection Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| pgvector delete_by_metadata | `pgvector.gleam:396-412` | Key parameter interpolated into SQL | Partial parameterization | SQL via key field |

### Path Traversal (LFI) Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| file_system.validate_path | `file_system.gleam:112-120` | Path → `workspace <> "/" <> path` | `..` detection, absolute path block | URL encoding (`%2e`), null bytes |
| workspace_guard.validate_path | `workspace_guard.gleam:21-36` | Path check | `..` and `/` prefix check | Symlink resolution, encoded variants |

### SSTI/JavaScript Injection Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| browser.evaluate | `browser.gleam:79-84` | Script → `page.evaluate()` | JSON escaping only | Arbitrary JavaScript execution |
| browser_runner.mjs | `scripts/browser_runner.mjs:100-107` | Script → `globalThis.eval()` | None | Direct eval of user script |

### SSRF Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| web_fetch URL | `web.gleam:12-29` | URL → HTTP request | URL parsing | Internal URLs, file:// scheme |
| browser.open URL | `browser.gleam` | URL → `page.goto()` | URL parsing | Internal URLs, file:// scheme |

### Insecure Deserialization Sources

| Source | File:Line | Data Flow | Validation | Bypass |
|--------|-----------|-----------|------------|--------|
| MCP tool handler | `mcp.gleam:1470-1523` | JSON arguments → handler | None | Handler receives arbitrary data |

---

## 10. Summary of Critical Attack Surface

### High-Priority Attack Vectors

1. **Health Server (Port 8080)**
   - Unauthenticated access to `/health`, `/metrics`
   - No rate limiting, no security headers
   - Information disclosure via metrics

2. **Tool Execution Pipeline**
   - Command injection via safe_shell (whitelist bypass)
   - Path traversal via file_system (incomplete validation)
   - Arbitrary JavaScript via browser tool
   - SSRF via web_fetch and browser tools

3. **Session Management**
   - Predictable session IDs: `platform:channel_id:user_id`
   - In-memory only (lost on restart)
   - No session expiration

4. **Authorization Gaps**
   - Syscall gateway can run without policies
   - Budget limits can be disabled (-1)
   - External read flag bypasses workspace confinement

### Recommended Testing Priorities

1. Test command whitelist bypasses in safe_shell
2. Test path traversal in file_system operations
3. Test session ID prediction/forgery
4. Test SSRF via web_fetch and browser tools
5. Test JavaScript injection via browser.evaluate
6. Test SQL injection in pgvector delete_by_metadata