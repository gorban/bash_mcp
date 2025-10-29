#!/usr/bin/env bash
# Dynamic tool provider: implements echo and add tools.
set -Eeuom pipefail

# Usage:
#   ./test.sh list                    # prints tool definitions (one JSON object per line)
#   ./test.sh instructions            # prints extra usage instructions for the parent MCP server
#   ./test.sh echo '{"text":"hi"}'    # runs echo tool
#   ./test.sh add '{"a":1,"b":2}'     # runs add tool

tool_instructions() {
  cat <<'EOF'
Extra usage notes for test tools:
- test_echo: returns the text verbatim.
- test_add: integer addition only (bash arithmetic). Provide numbers, not strings.
EOF
}

tool_list() {
  # Echo tool definition
  jq -cn '{
    name: "test_echo",
    title: "Test echo tool",
    description: "Echoes the input text.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The text to echo." }
      },
      required: ["text"]
    }
  }'

  # Addition tool definition
  jq -cn '{
    name: "test_add",
    title: "Test add tool",
    description: "Adds two numbers.",
    inputSchema: {
      type: "object",
      properties: {
        a: { type: "number", description: "The first number." },
        b: { type: "number", description: "The second number." }
      },
      required: ["a","b"]
    }
  }'
}

log() { echo >&2 -e "[tools/test.sh] $*"; }

tool_echo() {
  local json="$1" text
  text="$(jq -r '.text' <<< "$json")"
  if [[ -z "$text" ]]; then
    echo "Missing 'text' parameter"
    return 1
  fi
  jq -c '{
      content: [
        {
          type: "text",
          text: .text
        }
      ],
      isError: false
    }' <<< "$text"
}

tool_add() {
  local json="$1" a b sum
  a="$(jq -r '.a' <<< "$json")"
  b="$(jq -r '.b' <<< "$json")"
  if [[ -z "$a" || -z "$b" ]]; then
    echo "Missing 'a' and/or 'b' parameters"
    return 1
  fi
  sum=$((a + b))
  jq -cn --argjson sum "$sum" '{
      content: [
        {
          type: "text",
          text: $sum | tostring
        }
      ],
      isError: false
    }'
}

main() {
  local cmd="${1-}"; shift || true
  case "$cmd" in
    # List is required to declare available tools
    list)
      tool_list
      ;;

    # And you must implement them, matching the declared names from the list
    test_echo)
      tool_echo "${1-}" || return 1
      ;;
    test_add)
      tool_add "${1-}" || return 1
      ;;
    
    # Optional additional instructions (helps the LLM use the tools correctly)
    instructions)
      tool_instructions
      ;;

    *)
      echo "Unknown tool command: $cmd"
      return 1
      ;;
  esac
}

main "$@"
