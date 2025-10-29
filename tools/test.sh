#!/usr/bin/env bash
# Dynamic tool provider: implements echo and add tools.
set -Eeuom pipefail

# Usage:
#   ./test.sh list                      # prints tool definitions (one JSON object per line)
#   ./test.sh echo '{"text":"hi"}'    # runs echo tool
#   ./test.sh add '{"a":1,"b":2}'     # runs add tool

log() { echo >&2 -e "[tools/test.sh] $*"; }

tool_list() {
  # Echo tool definition
  jq -cn '{
    name: "echo",
    title: "Echo Tool",
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
    name: "add",
    title: "Addition Tool",
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

tool_echo() {
  local json="$1"
  jq -c '{
      content: [
        {
          type: "text",
          text: .text
        }
      ],
      isError: false
    }' <<< "$json"
}

tool_add() {
  local json="$1" a b sum
  a="$(jq -r '.a' <<< "$json")"
  b="$(jq -r '.b' <<< "$json")"
  if [[ -z "$a" || -z "$b" ]]; then
    jq -cn '{error:{message:"Missing parameters"}}'
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
    list)
      tool_list
      ;;
    echo)
      tool_echo "${1-}" || return 1
      ;;
    add)
      tool_add "${1-}" || return 1
      ;;
    *)
      jq -cn --arg cmd "$cmd" '{error:{message:"Unknown tool command", command:$cmd}}'
      return 1
      ;;
  esac
}

main "$@"
