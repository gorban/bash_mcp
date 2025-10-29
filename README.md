# Team MCP Bash Server

A minimal, dynamic [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server implemented in portable Bash (tested with macOS default Bash 3.2). It discovers executable tools placed in the `tools/` directory at runtime and exposes them over a JSON-RPC 2.0 interface following the MCP tool contract.

---
## Prerequisites
- Bash shell (tested with macOS default Bash 3.2; should work on Linux)
- `jq` command-line JSON processor (install via `brew install jq` on macOS or your package manager on Linux)

---
## Key Features
- Bash (no associative arrays; portable to older shells).
  - But not "pure bash": relies on `jq` for JSON parsing/validation.
- Dynamic tool discovery: any executable in `tools/` that supports a `list` subcommand is loaded.
- Duplicate tool name detection with clear error reporting.
- Structured error responses using JSON-RPC error codes.
- Captures stdout/stderr/exit codes from tool executions robustly.
- Validates JSON output from tools with `jq` for correctness.
- Logs activity to `/tmp/mcp_server.log`.
- Compatible with MCP protocol version `2025-06-18`.

---
## To use
Modify your MCP JSON. 
1. For JetBrains IDEs:
   1. In CoPilot chat, select Agent mode, and click the "Settings" gear icon.
   2. Click "Add More Tools..."
2. For VS Code:
   1. Open command palette, search for "MCP: Add Server...".
   2. Select "Command (stdio)".
   3. Select the full path to bash_mcp.sh.

Ensure the `"servers"` JSON array contains an entry like:
```json
{
  "name": "team",
  "command": ["/full/path/to/bash_mcp.sh"],
  "args": []
}
```

Then, check from CoPilot chat, in Agent mode, that the settings gear icon shows the "team" server as connected with
available tools.

---
## Missing Features
- No resource or prompt support (placeholders return empty lists).
- No hot-reloading of tools on filesystem changes (TODO: needs to send tools change notification).

---
## File Layout
- `bash_mcp.sh` – MCP server main loop and tooling runtime.
- `tools/test.sh` – Example tool provider implementing `echo` and `add`.
- `README.md` – This documentation.
- (You can add more executables to `tools/`).

---
## Protocol Summary
The server reads newline-delimited JSON-RPC 2.0 requests from stdin and writes responses to stdout.

Main `method`s:
- `initialize`
- `tools/list`
- `tools/call`

And each tool name `N` discovered from `tools/` supports:
- `list` (to list any other primary argument supported)
- `X args` (to invoke tool `X` with JSON `arg`uments)
- **NOTE**: If two different executables advertise the same tool `name`, the server will refuse `tools/list` and return
  a duplication error.

Some more methods return placeholders or empty lists (e.g., resource and prompt related methods)
to satisfy MCP compliance:
- `notifications/initialized` (ignored except for logging)
- `resources/list` (returns empty list)
- `resources/templates/list` (returns empty list)
- `prompts/list` (returns empty list)

---
## Example Tool Provider included (`tools/test.sh`)
`list` output (two objects):
```json
{ "name": "echo", "title": "Echo Tool", "description": "Echoes the input text.", "inputSchema": { "type": "object", "properties": { "text": { "type": "string" } }, "required": ["text"] } }
{ "name": "add", "title": "Addition Tool", "description": "Adds two numbers.", "inputSchema": { "type": "object", "properties": { "a": { "type": "number" }, "b": { "type": "number" } }, "required": ["a","b"] } }
```

Run tools directly:
```bash
./tools/test.sh echo '{"text":"Hello"}'
./tools/test.sh add '{"a":4,"b":4}'
```

Successful invocation returns MCP tool result shape, e.g.:
```json
{
  "jsonrpc": "2.0",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "8"
      }
    ],
    "isError": false
  },
  "id": 1
}
```

Bad request example (missing parameter):
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32603,
    "message": "Tool 'add' failed (exit 1): <<message>>"
  },
  "id": 1
}
```

You can also call the tool through the full MCP spec:
```bash
jq -cn '{
  jsonrpc: "2.0",
  method: "tools/call",
  params: {
    name: "add",
    arguments: {
      a: 40,
      b: 2
    }
  },
  id: 1
}' | ./bash_mcp.sh
```

Error codes used:
- `-32700` Parse error (invalid JSON line)
- `-32600` Invalid Request structure
- `-32601` Method or tool not found
- `-32602` Invalid params (malformed arguments JSON)
- `-32603` Internal / tool execution / duplication / invalid tool JSON

---
## Logging
Operational logs and stderr copies are appended to `/tmp/mcp_server.log`. Tool stderr is also logged with level 1.

---
## Adding a New Tool
1. Create an executable file in `tools/` (script or binary) and make it executable (`chmod +x`).
2. Implement a `list` subcommand that prints one JSON object per tool definition line.
3. Implement a subcommand for each advertised `name`.
4. Ensure each tool invocation prints valid JSON to stdout (tool result). Non-zero exit codes trigger server error wrapping.
5. Avoid reusing existing tool names unless intentional (will block `tools/list`).

Template minimal tool:
```bash
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  list)
    jq -cn '{name:"mytool",description:"Does X",inputSchema:{type:"object",properties:{},required:[]}}'
    ;;
  mytool)
    jq -cn '{content:[{type:"text",text:"done"}],isError:false}'
    ;;
  *) echo '{"error":{"message":"Unknown"}}' ; exit 1 ;;
 esac
```

---
## Duplicate Tool Handling
If two executables advertise the same `name`, `tools/list` returns an error:
```
{"jsonrpc":"2.0","error":{"code":-32603,"message":"Duplicate tool names: name:fileNew,fileExisting"},"id":2}
```
Fix by renaming or removing one definition.

---
## Development Notes
- Uses `jq` extensively; ensure it is installed (`brew install jq` on macOS).
- Avoid bashisms not supported by 3.2 (e.g., associative arrays). Parallel arrays are used instead.
- `set -Eeuom pipefail` for strict error handling.
- JSON validation occurs before accepting tool output.

---
## Future Improvements (Ideas)
- Hot reload on filesystem changes (inotify / polling).
- Optional resource and prompt support.
- Limit tool output size, allow parameters to limit N top/tail results.
- Tool execution timeout control.
- Security sandboxing (chroot / seccomp for binaries).
