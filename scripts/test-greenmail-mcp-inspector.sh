#!/usr/bin/env bash
set -euo pipefail

IMAGE="greenmail/standalone:2.1.8"
NAME="mail-imap-mcp-rs-greenmail-inspector-test"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EXTERNAL_ENDPOINT=0
if [[ -n "${GREENMAIL_HOST+x}" || -n "${GREENMAIL_SMTP_PORT+x}" || -n "${GREENMAIL_IMAP_PORT+x}" ]]; then
  EXTERNAL_ENDPOINT=1
fi

GREENMAIL_HOST="${GREENMAIL_HOST:-localhost}"
GREENMAIL_SMTP_PORT="${GREENMAIL_SMTP_PORT:-3025}"
GREENMAIL_IMAP_PORT="${GREENMAIL_IMAP_PORT:-3143}"
GREENMAIL_USER="${GREENMAIL_USER:-test@localhost}"
GREENMAIL_PASS="${GREENMAIL_PASS:-test}"
GREENMAIL_PRELOAD_DIR="${GREENMAIL_PRELOAD_DIR:-$REPO_ROOT/tests/fixtures/greenmail-preload}"

GREENMAIL_OPTS_DEFAULT="-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=test:${GREENMAIL_PASS}@localhost -Dgreenmail.users.login=email -Dgreenmail.preload.dir=/greenmail-preload -Dgreenmail.verbose"
GREENMAIL_OPTS="${GREENMAIL_OPTS:-$GREENMAIL_OPTS_DEFAULT}"

started_local_container=0
cleanup() {
  if [[ "$started_local_container" -eq 1 ]]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

probe_greenmail() {
  python3 - "$GREENMAIL_HOST" "$GREENMAIL_SMTP_PORT" "$GREENMAIL_IMAP_PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
ports = [int(sys.argv[2]), int(sys.argv[3])]

for port in ports:
    try:
        with socket.create_connection((host, port), timeout=1.5):
            pass
    except Exception as exc:
        print(exc)
        sys.exit(1)
PY
}

wait_for_greenmail() {
  local attempts=60
  local last_probe_error=""

  echo "Waiting for GreenMail on ${GREENMAIL_HOST}:${GREENMAIL_SMTP_PORT} and ${GREENMAIL_HOST}:${GREENMAIL_IMAP_PORT}"

  for _ in $(seq 1 "$attempts"); do
    if last_probe_error=$(probe_greenmail 2>&1); then
      return 0
    fi
    sleep 1
  done

  echo "GreenMail unreachable at ${GREENMAIL_HOST}:${GREENMAIL_IMAP_PORT} after ${attempts}s: ${last_probe_error}" >&2
  return 1
}

ensure_docker_available() {
  if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<EOF
docker is required to start GreenMail automatically.

Options:
  1) Install Docker (or provide a docker-compatible CLI on PATH)
  2) Use an externally managed GreenMail endpoint by setting one or more of:
     GREENMAIL_HOST, GREENMAIL_SMTP_PORT, GREENMAIL_IMAP_PORT
EOF
    exit 1
  fi
}

if [[ "$EXTERNAL_ENDPOINT" -eq 0 ]] && probe_greenmail >/dev/null 2>&1; then
  EXTERNAL_ENDPOINT=1
  echo "Detected running GreenMail endpoint on default host/ports"
fi

if [[ "$EXTERNAL_ENDPOINT" -eq 1 ]]; then
  echo "Using externally managed GreenMail endpoint"
else
  ensure_docker_available

  if [[ ! -d "$GREENMAIL_PRELOAD_DIR" ]]; then
    echo "missing preload fixture directory: $GREENMAIL_PRELOAD_DIR" >&2
    exit 1
  fi

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker pull "$IMAGE"

  docker run -d --rm --name "$NAME" \
    -e GREENMAIL_OPTS="$GREENMAIL_OPTS" \
    -v "$GREENMAIL_PRELOAD_DIR:/greenmail-preload:ro" \
    -p "$GREENMAIL_SMTP_PORT:3025" \
    -p "$GREENMAIL_IMAP_PORT:3993" \
    "$IMAGE"

  started_local_container=1
fi

wait_for_greenmail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for inspector assertions" >&2
  exit 1
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required for inspector execution" >&2
  exit 1
fi

cd "$REPO_ROOT"

echo "Building server binary"
cargo build --quiet

SERVER_BIN="$REPO_ROOT/target/debug/mail-mcp"

export MAIL_IMAP_DEFAULT_HOST="$GREENMAIL_HOST"
export MAIL_IMAP_DEFAULT_PORT="$GREENMAIL_IMAP_PORT"
export MAIL_IMAP_DEFAULT_SECURE="true"
export MAIL_IMAP_DEFAULT_USER="$GREENMAIL_USER"
export MAIL_IMAP_DEFAULT_PASS="$GREENMAIL_PASS"
export MAIL_IMAP_WRITE_ENABLED="true"

run_inspector() {
  npx --yes @modelcontextprotocol/inspector "$SERVER_BIN" --cli "$@"
}

expect_failure_with_text() {
  local expected_text="$1"
  shift
  set +e
  local output
  output=$(run_inspector "$@" 2>&1)
  local exit_code=$?
  set -e

  if [[ "$exit_code" -eq 0 ]]; then
    echo "Expected inspector call to fail" >&2
    echo "$output" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected_text"* ]]; then
    echo "Inspector failure did not include expected text: ${expected_text}" >&2
    echo "$output" >&2
    exit 1
  fi
}

echo "Checking MCP tool discovery"
TOOLS_JSON=$(run_inspector --method tools/list)
printf '%s\n' "$TOOLS_JSON" | jq -e '
  .tools | map(.name) as $names
  | [
      "imap_list_accounts",
      "imap_verify_account",
      "imap_list_mailboxes",
      "imap_search_messages",
      "imap_get_message",
      "imap_get_message_raw",
      "imap_update_message_flags",
      "imap_copy_message",
      "imap_move_message",
      "imap_delete_message"
    ]
  | all(. as $tool | ($names | index($tool) != null))
' >/dev/null

echo "Checking imap_list_accounts"
LIST_ACCOUNTS_JSON=$(run_inspector --method tools/call --tool-name imap_list_accounts)
printf '%s\n' "$LIST_ACCOUNTS_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and ((($data.accounts // []) | map(.id)) | index("default") != null)
' >/dev/null

echo "Checking imap_verify_account"
VERIFY_JSON=$(run_inspector --method tools/call --tool-name imap_verify_account --tool-arg account_id=default)
printf '%s\n' "$VERIFY_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and ($data.account_id == "default")
' >/dev/null

echo "Checking imap_list_mailboxes"
MAILBOXES_JSON=$(run_inspector --method tools/call --tool-name imap_list_mailboxes --tool-arg account_id=default)
printf '%s\n' "$MAILBOXES_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and ((($data.mailboxes // []) | map(.name)) | index("INBOX") != null)
' >/dev/null

echo "Checking imap_search_messages"
SEARCH_JSON=$(run_inspector \
  --method tools/call \
  --tool-name imap_search_messages \
  --tool-arg account_id=default \
  --tool-arg mailbox=INBOX \
  --tool-arg limit=5)
printf '%s\n' "$SEARCH_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and (($data.messages | length) > 0)
' >/dev/null

MESSAGE_ID=$(printf '%s\n' "$SEARCH_JSON" | jq -r '(.structuredContent.data // .data).messages[0].message_id // empty')
if [[ -z "$MESSAGE_ID" ]]; then
  echo "No message_id returned from imap_search_messages" >&2
  exit 1
fi

echo "Checking imap_get_message"
GET_JSON=$(run_inspector \
  --method tools/call \
  --tool-name imap_get_message \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}")
printf '%s\n' "$GET_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and ($data.message_id != null)
    and ($data.subject != null)
' >/dev/null

echo "Checking imap_get_message_raw"
RAW_JSON=$(run_inspector \
  --method tools/call \
  --tool-name imap_get_message_raw \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}" \
  --tool-arg max_bytes=200000)
printf '%s\n' "$RAW_JSON" | jq -e '
  (.structuredContent.data // .data) as $data
  | (.isError != true)
    and ($data.status == "ok")
    and (($data.size_bytes // 0) > 0)
    and (($data.raw_source_base64 // "") | length > 0)
' >/dev/null

echo "Checking write-path policy enforcement over MCP"
export MAIL_IMAP_WRITE_ENABLED="false"

expect_failure_with_text "write tools are disabled; set MAIL_IMAP_WRITE_ENABLED=true" \
  --method tools/call \
  --tool-name imap_update_message_flags \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}" \
  --tool-arg add_flags='["\\Seen"]'

expect_failure_with_text "write tools are disabled; set MAIL_IMAP_WRITE_ENABLED=true" \
  --method tools/call \
  --tool-name imap_copy_message \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}" \
  --tool-arg destination_mailbox=INBOX

expect_failure_with_text "write tools are disabled; set MAIL_IMAP_WRITE_ENABLED=true" \
  --method tools/call \
  --tool-name imap_move_message \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}" \
  --tool-arg destination_mailbox=INBOX

expect_failure_with_text "write tools are disabled; set MAIL_IMAP_WRITE_ENABLED=true" \
  --method tools/call \
  --tool-name imap_delete_message \
  --tool-arg account_id=default \
  --tool-arg "message_id=${MESSAGE_ID}" \
  --tool-arg confirm=true

echo "MCP inspector GreenMail integration checks passed"
