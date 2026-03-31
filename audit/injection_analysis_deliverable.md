{
  "vulnerabilities": [
    {
      "id": "CMD-001",
      "type": "COMMAND_INJECTION",
      "severity": "MEDIUM",
      "title": "SafeShell Command Execution via Erlang Port",
      "description": "User-supplied commands flow through the executor tool dispatch to safe_shell.execute(), which passes commands to an Erlang port for shell execution. While command whitelisting and operator blocking exist, the whitelist includes potentially dangerous commands like 'cat', 'find', and 'head' that can read arbitrary files.",
      "file_path": "/repos/supernova/src/supernova/tools/safe_shell.gleam",
      "line_numbers": [25-30, 146-153],
      "sink_file": "/repos/supernova/src/supernova_safe_shell_ffi.erl",
      "sink_line": 7,
      "data_flow": [
        "Channel message received (telegram, discord, etc.) -> port.ChannelMessage.content",
        "channel_common_router.handle_inbound_message() -> executor.run()",
        "executor.run_loop() -> execute_single_tool_call() -> dispatch_builtin_tool()",
        "dispatch_builtin_tool('safe_shell') -> execute_safe_shell() -> safe_shell.execute()",
        "safe_shell.execute() -> validate_command() -> run_command() -> do_run_command() FFI",
        "supernova_safe_shell_ffi:run_command() -> open_port({spawn, Command}, ...)"
      ],
      "validation": {
        "exists": true,
        "type": "whitelist + operator blocking",
        "location": "safe_shell.gleam:68-88, 91-101, 118-131",
        "bypass_possible": true,
        "bypass_description": "Commands 'cat', 'find', 'head', 'tail' can access arbitrary file paths. The '..' blocking only applies to command string, not to file arguments. E.g., 'cat /etc/passwd' is allowed, 'find / -name secret' is allowed."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "Telegram adapter",
          "Discord adapter", 
          "Slack adapter",
          "Matrix adapter",
          "All channel adapters via channel_common_router"
        ]
      },
      "cwe": "CWE-78",
      "recommendation": "Restrict whitelisted commands to safe operations only. Add path validation for file-reading commands. Consider using workspace_guard for file path arguments."
    },
    {
      "id": "CMD-002",
      "type": "COMMAND_INJECTION",
      "severity": "HIGH",
      "title": "MCP STDIO Arbitrary Command Execution",
      "description": "The MCP STDIO transport allows spawning arbitrary processes via stdio.start(command, args, env). The command and arguments come from MCP server configuration which could be manipulated if config file is attacker-controlled.",
      "file_path": "/repos/supernova/src/supernova/adapters/mcp/stdio.gleam",
      "line_numbers": [23-28, 133-164],
      "sink_file": "/repos/supernova/src/supernova_mcp_ffi.erl",
      "sink_line": 6-31,
      "data_flow": [
        "YAML config file (supernova.yaml) -> mcp/config_loader.parse_servers()",
        "ServerConfig(command, args, env) -> mcp_manager.register()",
        "mcp_manager handle_message RegisterServer -> stdio.start(command, args, env)",
        "stdio.do_open_port() FFI -> supernova_mcp_ffi:open_port()",
        "erlang:open_port({spawn_executable, Executable}, [{args, Args}, {env, Env}...])"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "No validation on command, args, or environment variables. Any executable in PATH or absolute path can be spawned with arbitrary arguments."
      },
      "network_exposure": {
        "reachable": false,
        "entry_points": [],
        "note": "Requires local file system access to modify supernova.yaml configuration file. Not directly reachable via network requests."
      },
      "cwe": "CWE-78",
      "recommendation": "Add command whitelist for MCP servers. Validate command paths. Restrict to specific directories. Consider sandboxing MCP server processes."
    },
    {
      "id": "LFI-001",
      "type": "PATH_TRAVERSAL",
      "severity": "MEDIUM",
      "title": "FileSystem Tool Path Traversal via Workspace Bypass",
      "description": "The file_system tool validates paths against '..' sequences but uses string-based detection which can be bypassed. Additionally, workspace confinement relies on simple string concatenation.",
      "file_path": "/repos/supernova/src/supernova/tools/file_system.gleam",
      "line_numbers": [20-25, 42-51, 112-120],
      "sink_file": "/repos/supernova/src/supernova_file_system_ffi.erl",
      "sink_line": 4-20,
      "data_flow": [
        "Channel message -> executor.run() -> execute_file_system()",
        "file_system_args_decoder extracts path from JSON",
        "file_system.read('.', path) -> validate_path('.', path)",
        "validate_path checks for '..' string -> do_read_file(full_path) FFI",
        "supernova_file_system_ffi:read_file() -> file:read_file(Path)"
      ],
      "validation": {
        "exists": true,
        "type": "string contains '..' check",
        "location": "file_system.gleam:112-120",
        "bypass_possible": true,
        "bypass_description": "Only checks for literal '..' in path. URL encoding, double encoding, null bytes, and other encoding tricks may bypass. Also does not check for absolute paths starting with '/'. Note: workspace_guard.gleam does check for absolute paths but file_system.gleam does not use it."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ]
      },
      "cwe": "CWE-22",
      "recommendation": "Use workspace_guard.validate_path() which also blocks absolute paths. Implement path canonicalization before validation. Use allowlist of permitted directories."
    },
    {
      "id": "LFI-002",
      "type": "PATH_TRAVERSAL",
      "severity": "LOW",
      "title": "Gateway Tool File Read/Write Operations",
      "description": "The gateway tool exposes read_file and write_file syscalls that accept arbitrary path strings without path traversal protection.",
      "file_path": "/repos/supernova/src/supernova/tools/gateway.gleam",
      "line_numbers": [218-225],
      "sink_file": null,
      "sink_line": null,
      "data_flow": [
        "Channel message -> executor.run() -> execute_gateway()",
        "gateway_args_decoder extracts path parameter",
        "build_syscall_op() -> ReadFile(path) or WriteFile(path, content)",
        "invoke_once() -> syscall_actor.invoke(gateway, agent_id, op)"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "No path validation. Paths passed directly to syscall gateway."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ],
        "note": "However, the syscall actor likely has its own authorization layer. Need to verify syscall/actor.gleam for additional protections."
      },
      "cwe": "CWE-22",
      "recommendation": "Verify syscall actor implements path confinement. Add workspace_guard validation at gateway tool level."
    },
    {
      "id": "SSTI-001",
      "type": "SERVER_SIDE_TEMPLATE_INJECTION",
      "severity": "HIGH",
      "title": "Browser Tool JavaScript Evaluation",
      "description": "The browser tool's evaluate operation allows arbitrary JavaScript execution in the browser page context. While this is sandboxed to the browser, it can access page DOM, make authenticated requests as the browser session, and exfiltrate data.",
      "file_path": "/repos/supernova/src/supernova/tools/browser.gleam",
      "line_numbers": [78-85, 174-184],
      "sink_file": "/repos/supernova/src/supernova_browser_ffi.erl",
      "sink_line": 53-61,
      "secondary_sink": "/repos/supernova/scripts/browser_runner.mjs",
      "secondary_sink_line": 100-107,
      "data_flow": [
        "Channel message -> executor.run() -> execute_browser()",
        "browser.execute() -> browser_args_decoder extracts script",
        "dispatch('evaluate') -> evaluate(session_id, script, timeout_ms)",
        "do_evaluate() FFI -> supernova_browser_ffi:evaluate()",
        "evaluate_command() -> send to browser_runner.mjs",
        "page.evaluate((script) => globalThis.eval(script), command.script)"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "Arbitrary JavaScript is evaluated via globalThis.eval(). No sandboxing within the browser context. Can access cookies, localStorage, make fetch requests with browser credentials."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ]
      },
      "cwe": "CWE-94",
      "recommendation": "Consider restricting JavaScript evaluation to a predefined set of safe operations. Implement script validation/sandboxing. Limit what APIs are accessible from evaluated scripts."
    },
    {
      "id": "SSRF-001",
      "type": "SSRF",
      "severity": "MEDIUM",
      "title": "Browser Tool Open URL SSRF",
      "description": "The browser tool allows navigating to arbitrary URLs, enabling Server-Side Request Forgery. The browser instance can access internal network resources, metadata services, and bypass network segmentation.",
      "file_path": "/repos/supernova/src/supernova/tools/browser.gleam",
      "line_numbers": [54-57, 154-156],
      "sink_file": "/repos/supernova/scripts/browser_runner.mjs",
      "sink_line": 69-81,
      "data_flow": [
        "Channel message -> executor.run() -> execute_browser()",
        "browser.execute() -> browser_args_decoder extracts url",
        "dispatch('open') -> open(url, timeout_ms)",
        "do_open_session() FFI -> supernova_browser_ffi:open_session()",
        "open_command() JSON -> browser_runner.mjs",
        "page.goto(command.url, ...)"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "No URL validation. Can access file:// URLs, internal IP ranges (10.x, 172.16.x, 192.168.x), localhost, cloud metadata endpoints (169.254.169.254)."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ]
      },
      "cwe": "CWE-918",
      "recommendation": "Implement URL allowlist/blocklist. Block internal IP ranges. Block cloud metadata IPs. Validate URL schemes (only allow http/https)."
    },
    {
      "id": "SSRF-002",
      "type": "SSRF",
      "severity": "LOW",
      "title": "Web Fetch Tool SSRF",
      "description": "The web_fetch tool fetches content from arbitrary URLs. While only HTTP GET is supported, it can still be used for SSRF attacks.",
      "file_path": "/repos/supernova/src/supernova/tools/web.gleam",
      "line_numbers": [12-29],
      "sink_file": null,
      "sink_line": null,
      "data_flow": [
        "Channel message -> executor.run() -> execute_web_fetch()",
        "web_fetch_args_decoder extracts url",
        "web.fetch(url) -> request.to(url)",
        "hackney.send(req) - HTTP GET request"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "No URL validation. Can fetch internal resources if the server has access to internal networks."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ]
      },
      "cwe": "CWE-918",
      "recommendation": "Implement URL validation. Block internal IP ranges. Consider using an HTTP client with redirect limits and timeout controls."
    },
    {
      "id": "SQL-001",
      "type": "SQL_INJECTION",
      "severity": "LOW",
      "title": "PgVector Table Name String Concatenation",
      "description": "The pgvector adapter constructs SQL queries by concatenating the table_name configuration value. While table_name comes from configuration (not user input), if the configuration is attacker-controlled, SQL injection is possible.",
      "file_path": "/repos/supernova/src/supernova/adapters/pgvector.gleam",
      "line_numbers": [193-217, 230-265, 311-334, 352-379, 387-393, 401-412],
      "sink_file": null,
      "sink_line": null,
      "data_flow": [
        "Configuration (PgVectorConfig.table_name) -> schema_sql(), ensure_schema(), insert(), similarity_search(), delete(), delete_by_metadata()",
        "String concatenation: \"CREATE TABLE \" <> table <> \"...\"",
        "pog.query(sql) |> pog.execute(conn)"
      ],
      "validation": {
        "exists": false,
        "type": "none",
        "location": null,
        "bypass_possible": true,
        "bypass_description": "Table name is directly concatenated into SQL without quoting or validation. If config is attacker-controlled, SQL injection via table name is possible."
      },
      "network_exposure": {
        "reachable": false,
        "entry_points": [],
        "note": "Table name comes from code configuration, not from network input. Only exploitable if attacker can modify application configuration."
      },
      "cwe": "CWE-89",
      "recommendation": "Use parameterized identifiers or validate table name against a strict pattern (alphanumeric + underscore only). Quote table names properly in SQL."
    },
    {
      "id": "PROCESS-001",
      "type": "COMMAND_INJECTION",
      "severity": "LOW",
      "title": "Process Tool OS Command Execution",
      "description": "The process tool executes system commands (ps, kill) via FFI. While the actions are limited to list/info/kill and pid is validated, the underlying FFI could be vulnerable if process info parsing is manipulated.",
      "file_path": "/repos/supernova/src/supernova/tools/process.gleam",
      "line_numbers": [41-72, 281-288],
      "sink_file": null,
      "sink_line": null,
      "data_flow": [
        "Channel message -> executor.run() -> execute_process()",
        "process_args_decoder extracts action and pid",
        "list() -> do_list_processes() FFI",
        "info(pid) -> do_process_info(pid) FFI",
        "kill(pid) -> do_kill_process(pid) FFI"
      ],
      "validation": {
        "exists": true,
        "type": "action whitelist + pid validation",
        "location": "process.gleam:114-134, 142-147",
        "bypass_possible": false,
        "bypass_description": "Actions are limited to list/info/kill. Pid must be positive integer. No arbitrary command execution."
      },
      "network_exposure": {
        "reachable": true,
        "entry_points": [
          "All channel adapters via executor tool dispatch"
        ]
      },
      "cwe": "CWE-78",
      "recommendation": "The current implementation appears reasonably safe. Consider adding rate limiting to prevent process enumeration abuse."
    }
  ],
  "summary": {
    "total_vulnerabilities": 9,
    "by_severity": {
      "high": 2,
      "medium": 4,
      "low": 3
    },
    "by_type": {
      "COMMAND_INJECTION": 3,
      "PATH_TRAVERSAL": 2,
      "SSRF": 2,
      "SERVER_SIDE_TEMPLATE_INJECTION": 1,
      "SQL_INJECTION": 1
    },
    "network_reachable": 7,
    "critical_paths": [
      "Channel Message -> executor.run() -> tool dispatch -> dangerous sink",
      "All channel adapters (Telegram, Discord, Slack, Matrix, etc.) feed into channel_common_router",
      "channel_common_router calls executor.run() with user message content",
      "Executor dispatches to tools based on LLM-generated tool calls",
      "Tools execute with varying levels of input validation"
    ]
  },
  "attack_surface": {
    "network_entry_points": [
      {
        "name": "Health Server",
        "port": "configurable",
        "endpoints": ["/health", "/health/live", "/health/ready", "/metrics"],
        "note": "Read-only, no user input processing"
      },
      {
        "name": "Channel Adapters",
        "protocol": "various (Telegram Bot API, Discord Gateway, Slack Events, Matrix, etc.)",
        "data_flow": "User messages -> ChannelMessage -> executor -> tools",
        "note": "Primary attack surface for injection"
      }
    ],
    "trust_boundaries": [
      {
        "from": "External Channel (Telegram/Discord/etc.)",
        "to": "Channel Adapter",
        "risk": "Untrusted user input enters system"
      },
      {
        "from": "Channel Adapter",
        "to": "Executor",
        "risk": "User content becomes LLM prompt, LLM generates tool calls"
      },
      {
        "from": "Executor",
        "to": "Tools (safe_shell, browser, file_system, etc.)",
        "risk": "Tool arguments derived from LLM output (influenced by user input)"
      }
    ]
  },
  "recommendations": {
    "priority_high": [
      "Add URL validation to browser.open() and web.fetch() - block internal IPs, metadata endpoints",
      "Implement JavaScript sandboxing or restrictions for browser.evaluate()"
    ],
    "priority_medium": [
      "Use workspace_guard.validate_path() in file_system.gleam to also block absolute paths",
      "Add command argument validation for safe_shell - validate file paths for cat/head/tail/find",
      "Review and restrict MCP server command configuration"
    ],
    "priority_low": [
      "Add table name validation in pgvector adapter",
      "Consider rate limiting for process listing"
    ]
  }
}
