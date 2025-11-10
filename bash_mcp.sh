#!/usr/bin/env bash
# Dynamic MCP server in bash with executable tool discovery (Bash 3.2 compatible).
# Put executable tools in the 'tools' subdirectory. They do not need to be scripts;
# they can be any executable (compiled binary, script with shebang, etc).
# Each tool must support 'list' and any other tool name returned by 'list'.
# Format must follow the MCP tool call "result" schema:
# https://modelcontextprotocol.io/specification/2025-06-18/server/tools#output-schema
#
# For example, see tools/test.sh for a sample tool implementation.
# ./tools/test.sh list
# - Since this outputs `"name":"echo"` and `"name":"add"`, it must also support:
# ./tools/test.sh echo '{"text":"hello"}'
# ./tools/test.sh add '{"a":1,"b":2}'

set -Eeuom pipefail

LOG_FILE="/tmp/mcp_server.log"
TOOLS_DIR="$(dirname "$0")/tools"
JQ_LAST_ERROR=""
TOOL_EXTRA_INSTRUCTIONS=()  # aggregated plain-text instructions from tools

# Mapping structures (avoid associative arrays for macOS default Bash 3.2)
TOOL_NAME_LIST=()          # tool names in discovery order
TOOL_FILE_MAPPING=()       # parallel array: either tool file path or __DUPLICATE__:file1,file2,...
TOOL_AGGREGATED_JSON="[]"  # aggregated definitions (excluding duplicates)
TOOL_DUPLICATES=()         # entries formatted name:fileNew,fileExisting
TOOL_LIST_ERRORS=()        # listing errors per tool file

server_config_json() {
  # Base instructions plus any extra tool-provided instructions (plain text).
  local base="This server provides our team's custom tools." joined="" nl=$'\n\n'
  if (( ${#TOOL_EXTRA_INSTRUCTIONS[@]} > 0 )); then
    local inst
    for inst in "${TOOL_EXTRA_INSTRUCTIONS[@]}"; do
      [[ -z "$inst" ]] && continue
      if [[ -n "$joined" ]]; then
        joined+="$nl"
      fi
      joined+="$inst"
    done
  fi

  local final="$base"
  if [[ -n "$joined" ]]; then
    final+="${nl}${joined}"
  fi
  jq -Mcn --arg instructions "$final" '{
    protocolVersion: "2025-06-18",
    serverInfo: {
      name: "Team MCP Server", version: "0.0.2"
    },
    capabilities: {
      tools: {
        listChanged: true
      }
    },
    instructions: $instructions
  }'
}

msg() {
  echo >&2 -e "${1-}"
}

log() {
  local level="$1" m="$2"
  local ts

  set +e
  ts="$(date "+%Y-%m-%d %H:%M:%S")"
  set -e

  msg "[$ts] [$level] $m" 2>> "$LOG_FILE"
}

create_error_response() {
  local id="$1" code="$2" message="$3"
  log 2 "Error response id=$id code=$code msg=$message"
  jq -Mcn --arg id "$id" \
    --argjson code "$code" \
    --arg message "$message" '{
      jsonrpc: "2.0",
      error: {
        code: $code,
        message: $message
      },
      id: $id | tonumber
    }'
}

create_response() {
  local id="$1" result="$2"
  jq -Mcn --arg id "$id" \
    --argjson result "$result" '{
      jsonrpc: "2.0",
      result: $result,
      id: $id | tonumber
    }'
}

# Helper: run jq on provided data; capture stderr on failure.
# Usage: if ! jq_eval OUT_VAR "$data" -r 'filter'; then ... (error in $JQ_LAST_ERROR)
jq_eval() {
  local __out_var="$1"
  local __data="$2"

  shift 2
  local err_file out rc
  err_file="$(mktemp)"

  # Preserve pipe fail; explicit capture
  set +e
  out="$(jq -Mcb "$@" <<< "$__data" 2> "$err_file")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    # Keep full jq stderr (trim trailing newline)
    JQ_LAST_ERROR="$(tr -d '\r' < "$err_file" | sed 's/[[:space:]]*$//')"
    rm -f "$err_file"
    return $rc
  fi

  rm -f "$err_file"
  JQ_LAST_ERROR=""
  printf -v "$__out_var" '%s' "$out"
}

# Add a noop function to reference globals (helps some static analyzers recognize usage)
_touch_globals() {
  : "${TOOLS_DIR-}" "${TOOL_NAME_LIST[*]-}" "${TOOL_FILE_MAPPING[*]-}" "${TOOL_AGGREGATED_JSON-}" "${TOOL_DUPLICATES[*]-}" "${TOOL_LIST_ERRORS[*]-}" "${TOOL_EXTRA_INSTRUCTIONS[*]-}"
}

# Add tool definition to mapping (handles duplicates)
add_tool_mapping() {
  local name="$1" file="$2" def_json="$3"
  local i
  for i in "${!TOOL_NAME_LIST[@]}"; do
    if [[ "${TOOL_NAME_LIST[$i]}" == "$name" ]]; then
      # Duplicate
      local existing="${TOOL_FILE_MAPPING[$i]}"
      if [[ "$existing" == __DUPLICATE__:* ]]; then
        # Append new file to duplicate list
        TOOL_FILE_MAPPING[$i]="$existing,$file"
      else
        # Convert to duplicate marker
        TOOL_FILE_MAPPING[$i]="__DUPLICATE__:${existing},${file}"
      fi
      TOOL_DUPLICATES+=("$name:$file,${existing#__DUPLICATE__:}")
      return
    fi
  done
  TOOL_NAME_LIST+=("$name")
  TOOL_FILE_MAPPING+=("$file")
  TOOL_AGGREGATED_JSON="$(jq -Mcn --argjson arr "$TOOL_AGGREGATED_JSON" --argjson obj "$def_json" '$arr + [$obj]')"
}

# Lookup tool file; stdout: file path or duplicate marker; return 0 if found else 1
lookup_tool_file() {
  local name="$1" i
  for i in "${!TOOL_NAME_LIST[@]}"; do
    if [[ "${TOOL_NAME_LIST[$i]}" == "$name" ]]; then
      printf '%s' "${TOOL_FILE_MAPPING[$i]}"
      return 0
    fi
  done
  return 1
}

run_and_capture() {
  local exec_path="$1" subcmd="$2" arg_json="${3-}"
  local tmp_stdout tmp_stderr tmp_combined pipe_stdout pipe_stderr
  tmp_stdout="$(mktemp)"
  tmp_stderr="$(mktemp)"
  tmp_combined="$(mktemp)"
  pipe_stdout="$(mktemp -u)"
  pipe_stderr="$(mktemp -u)"

  mkfifo "$pipe_stdout" "$pipe_stderr"

  # Ensure temporary files are removed if the function exits early
  local cleanup_files=("$tmp_stdout" "$tmp_stderr" "$tmp_combined" "$pipe_stdout" "$pipe_stderr")

  trap 'rm -f "${cleanup_files[@]}"; trap - RETURN' RETURN

  log 1 "Running command (background): $exec_path $subcmd ...params..."

  # Start tee processes that preserve ordering via tmp_combined
  tee "$tmp_stdout" >> "$tmp_combined" < "$pipe_stdout" &
  local tee_stdout_pid=$!
  tee "$tmp_stderr" >> "$tmp_combined" < "$pipe_stderr" &
  local tee_stderr_pid=$!

  # Run the command in background and capture its PID
  exec 3>"$pipe_stdout"
  exec 4>"$pipe_stderr"

  set +e
  "$exec_path" "$subcmd" "$arg_json" >&3 2>&4 &
  local cmd_pid=$!
  set -e

  # Close parent copies of the write ends to avoid keeping FIFOs open
  exec 3>&-
  exec 4>&-

  local exit_code="" event="" cmd_done=0 stdout_done=0
  while [[ -z "$event" ]]; do
    if [[ $cmd_done -eq 0 ]] && ! kill -0 "$cmd_pid" 2>/dev/null; then
      set +e
      wait "$cmd_pid" 2>/dev/null
      exit_code=$?
      set -e
      cmd_done=1
      event="cmd"
      continue
    fi

    if [[ $stdout_done -eq 0 ]] && ! kill -0 "$tee_stdout_pid" 2>/dev/null; then
      stdout_done=1
      event="stdout"
      [[ -n "$exit_code" ]] || exit_code="0"
      continue
    fi

    sleep 0.05
  done

  log 1 "Capture completed via ${event}, awaiting tee processes for final flush"

  if [[ "$event" == "cmd" ]]; then
    # Give the tees a moment to drain any buffered output, then terminate them so
    # we do not hang when the tool leaves background children holding the pipe open.
    sleep 0.05
    kill "$tee_stdout_pid" "$tee_stderr_pid" 2>/dev/null || true
  fi

  set +e
  local pid
  for pid in "$tee_stdout_pid" "$tee_stderr_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  set -e

  log 1 "Command monitoring finished (event=${event}) with exit code $exit_code"

  local result
  result="$(jq -Mcn --arg exit_code "$exit_code" \
    --rawfile stdout "$tmp_stdout" \
    --rawfile stderr "$tmp_stderr" \
    --rawfile combined "$tmp_combined" '{
        exit_code: $exit_code,
        stdout: $stdout,
        stderr: $stderr,
        combined: $combined
      }')"

  trap - RETURN
  rm -f "${cleanup_files[@]}"

  echo "$result"
}

# Parse run_and_capture JSON once; set decoded globals.
# Return codes:
#  0 = success
#  2 = jq parse failure
parse_capture() {
  local json="$1"
  local assigns

  # Reset globals
  PARSE_EXIT_CODE=""
  PARSE_STDOUT=""
  PARSE_STDOUT_VALID=""
  PARSE_STDERR=""
  PARSE_COMBINED=""

  # Use jq @sh to emit shell-safe assignments (handles spaces/newlines without base64)
  if ! jq_eval assigns "$json" -Mr '
    def emit(n; v): n + "=" + ((v // "") | @sh);
    emit("PARSE_EXIT_CODE"; .exit_code),
    emit("PARSE_STDOUT"; .stdout),
    emit("PARSE_STDOUT_VALID"; (try (.stdout | fromjson | has("content")) catch false)),
    emit("PARSE_STDERR"; .stderr),
    emit("PARSE_COMBINED"; .combined)
    '; then
    log 2 "jq parse_capture error: $JQ_LAST_ERROR raw=$json"
    return 2
  fi

  # Evaluate assignments safely (produced by jq @sh) to populate globals
  eval "$assigns" || { log 2 "eval failed for parse_capture assigns=$assigns"; return 2; }
}

cache_tool_files() {
  TOOL_AGGREGATED_JSON="[]"
  TOOL_DUPLICATES=()
  TOOL_LIST_ERRORS=()
  TOOL_NAME_LIST=()
  TOOL_FILE_MAPPING=()
  local file_count=0

  if [[ -d "$TOOLS_DIR" ]]; then
    while IFS= read -r f; do
      [[ -x "$f" ]] || continue

      set +e # Bash 3.2 on macOS doesn't give a non-zero exit for ++, but Git Bash on Windows does.
      ((file_count++))
      set -e

      local res
      res="$(run_and_capture "$f" list)"
      if ! parse_capture "$res"; then
        TOOL_LIST_ERRORS+=("$f: parse error")
        log 2 "Parse error listing $f raw=$res"
        continue
      fi
      if [[ "$PARSE_EXIT_CODE" != "0" ]]; then
        TOOL_LIST_ERRORS+=("$f: $PARSE_COMBINED")
        log 2 "List failure $f exit_code=$PARSE_EXIT_CODE combined=$PARSE_COMBINED"
        continue
      fi

      # Slurp all JSON tool definitions the tool emitted on stdout.
      # Each complete JSON object (even multi-line) becomes an element of the array.
      local defs_array
      if ! jq_eval defs_array "$PARSE_STDOUT" -Mcs '.'; then
        TOOL_LIST_ERRORS+=("$f: invalid JSON (slurp failed): $JQ_LAST_ERROR")
        log 2 "Slurp error file=$f jq_error=$JQ_LAST_ERROR stdout=$PARSE_STDOUT"
        continue
      fi

      # Iterate each definition object
      # Use @json to force a compact single-line representation for stable storage.
      while IFS= read -r def_json; do
        [[ -z "$def_json" ]] && continue
        if ! jq -Me . >/dev/null 2> >(read -r err; JQ_LAST_ERROR="$err") <<< "$def_json"; then
          TOOL_LIST_ERRORS+=("$f: invalid JSON definition: $JQ_LAST_ERROR")
          log 2 "Definition JSON error file=$f jq_error=$JQ_LAST_ERROR def=$def_json"
          continue
        fi

        local tool_name
        if ! jq_eval tool_name "$def_json" -Mr '.name // empty'; then
          TOOL_LIST_ERRORS+=("$f: cannot extract name: $JQ_LAST_ERROR")
          log 2 "Name extraction error file=$f jq_error=$JQ_LAST_ERROR def=$def_json"
          continue
        fi
        if [[ -z "$tool_name" ]]; then
          TOOL_LIST_ERRORS+=("$f: missing name in definition")
          log 2 "Missing name $f def=$def_json"
          continue
        fi

        add_tool_mapping "$tool_name" "$f" "$def_json"
      done < <(jq -Mc '.[]' <<< "$defs_array")

      [[ -n "$PARSE_STDERR" ]] && log 1 "List stderr $f: $PARSE_STDERR"

      # Attempt to retrieve optional extra instructions (plain text)
      local instr_res
      instr_res="$(run_and_capture "$f" instructions)" || true
      if parse_capture "$instr_res"; then
        if [[ "$PARSE_EXIT_CODE" == "0" ]]; then
          if [[ -n "$PARSE_STDOUT" ]]; then
            # Trim leading and trailing whitespace/newlines
            local trimmed="$PARSE_STDOUT"
            # Remove leading whitespace
            while [[ "$trimmed" =~ ^[[:space:]] ]]; do
              trimmed="${trimmed#[[:space:]]}"
            done
            # Remove trailing whitespace
            while [[ "$trimmed" =~ [[:space:]]$ ]]; do
              trimmed="${trimmed%[[:space:]]}"
            done

            [[ -n "$trimmed" ]] && TOOL_EXTRA_INSTRUCTIONS+=("$trimmed")
          fi
          [[ -n "$PARSE_STDERR" ]] && log 1 "Instructions stderr $f: $PARSE_STDERR"
        else
          log 2 "Instructions command failure file=$f exit_code=$PARSE_EXIT_CODE combined=$PARSE_COMBINED"
        fi
      else
        log 2 "Instructions parse error file=$f raw=$instr_res"
      fi
    done < <(find "$TOOLS_DIR" -maxdepth 1 -type f 2>/dev/null)
  fi
  log 1 "Cache complete files=$file_count tools=${#TOOL_NAME_LIST[@]} duplicates=${#TOOL_DUPLICATES[@]} errors=${#TOOL_LIST_ERRORS[@]}"
}

handle_tools_list() {
  local id="$1"
  if (( ${#TOOL_LIST_ERRORS[@]} > 0 )); then
    create_error_response "$id" -32603 "Tool listing failed: ${TOOL_LIST_ERRORS[*]}"
    return
  fi
  if (( ${#TOOL_DUPLICATES[@]} > 0 )); then
    create_error_response "$id" -32603 "Duplicate tool names: ${TOOL_DUPLICATES[*]}"
    return
  fi
  create_response "$id" "$(jq -Mcn --argjson tools "$TOOL_AGGREGATED_JSON" '{ tools: $tools }')"
}

handle_tools_call() {
  local id="$1" params="$2"
  local parsed tool_name tool_params mapping

  if ! jq_eval parsed "$params" -Mr '.name, .arguments // {}'; then
    log 2 "jq params parse error id=$id error=$JQ_LAST_ERROR params=$params"
    create_error_response "$id" -32602 "Invalid params: $JQ_LAST_ERROR"
    return
  fi

  read -rd '' tool_name tool_params <<< "$parsed" || true
  if ! mapping="$(lookup_tool_file "$tool_name")"; then
    create_error_response "$id" -32601 "Tool not found"
    return
  fi
  if [[ "$mapping" == __DUPLICATE__:* ]]; then
    create_error_response "$id" -32603 "Tool name '$tool_name' duplicated (${TOOL_DUPLICATES[*]})"
    return
  fi

  local call_res
  call_res="$(run_and_capture "$mapping" "$tool_name" "$tool_params")"
  if ! parse_capture "$call_res"; then
    create_error_response "$id" -32603 "Tool '$tool_name' output parse error"
    return
  fi
  if [[ "$PARSE_EXIT_CODE" != "0" ]]; then
    log 2 "Tool '$tool_name' failed exit_code=$PARSE_EXIT_CODE combined=$PARSE_COMBINED"
    create_error_response "$id" -32603 "Tool '$tool_name' failed (exit $PARSE_EXIT_CODE): $PARSE_COMBINED"
    return
  fi
  if ! jq -Me . >/dev/null 2> >(read -r err; JQ_LAST_ERROR="$err") <<< "$PARSE_STDOUT"; then
    log 2 "Tool JSON output invalid name=$tool_name error=$JQ_LAST_ERROR stdout=$PARSE_STDOUT"
    create_error_response "$id" -32603 "Tool '$tool_name' returned invalid JSON: $JQ_LAST_ERROR"
    return
  fi
  [[ -n "$PARSE_STDERR" ]] && log 1 "stderr $tool_name: $PARSE_STDERR"
  if [[ "$PARSE_STDOUT_VALID" != "true" ]]; then
    log 2 "Tool '$tool_name' returned invalid JSON stdout=$PARSE_STDOUT"
    local nl=$'\n'
    create_error_response "$id" -32603 "Tool '$tool_name' returned invalid JSON:${nl}${PARSE_STDOUT}"
    return
  fi
  create_response "$id" "$PARSE_STDOUT"
}

main() {
  local parsed jsonrpc id method params
  log 1 "Starting MCP server (Bash version: ${BASH_VERSION})"
  cache_tool_files
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    if ! jq_eval parsed "$line" -Mr '.jsonrpc, .id, .method, .params'; then
      log 2 "Incoming parse error jq_error=$JQ_LAST_ERROR line=$line"
      create_error_response "" -32700 "Parse error: $JQ_LAST_ERROR"
      continue
    fi
    log 1 "Received request: $line"

    read -rd '' jsonrpc id method params <<< "$parsed" || true
    [[ "$jsonrpc" != "2.0" ]] && { create_error_response "$id" -32600 "Invalid Request jsonrpc"; continue; }
    [[ -z "$id" ]] && { create_error_response "" -32600 "Missing id"; continue; }
    [[ -z "$method" ]] && { create_error_response "$id" -32600 "Missing method"; continue; }

    case "$method" in
      notifications/initialized) log 1 "Host confirmed toolContract reception with 'notifications/initialized'." ;;
      initialize) create_response "$id" "$(server_config_json)" ;;
      tools/list) handle_tools_list "$id" ;;
      tools/call) handle_tools_call "$id" "$params" ;;
      resources/list) create_response "$id" "$(jq -Mcn '{ resources: [] }')" ;;
      resources/templates/list) create_response "$id" "$(jq -Mcn '{ resourceTemplates: [] }')" ;;
      prompts/list) create_response "$id" "$(jq -Mcn '{ prompts: [] }')" ;;
      *) create_error_response "$id" -32601 "Method not found" ;;
    esac
  done
}

# Call once at startup before cache
_touch_globals

main "$@" | tee -a "$LOG_FILE"
