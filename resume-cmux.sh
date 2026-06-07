#!/bin/bash
# cmux ネイティブ版の two-man-dev セッション resume
#
# 使い方:
#   bash resume-cmux.sh -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [project_dir]
#
# 前提: cmux が起動していること。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSIONS_DIR="$HOME/base/daily/sessions"

SESSION_NAME=""
DIVER_NAME=""
OPERATOR_NAME=""
OPERATOR_CODEX=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) SESSION_NAME="$2"; shift 2 ;;
    -d) DIVER_NAME="$2"; shift 2 ;;
    -o) OPERATOR_NAME="$2"; shift 2 ;;
    --operator-codex) OPERATOR_CODEX=true; shift ;;
    *)
      if [[ "$1" != -* ]]; then
        break
      fi
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

PROJECT="${1:-.}"
PROJECT="$(cd "$PROJECT" && pwd)"

if [ -z "$SESSION_NAME" ] || [ -z "$DIVER_NAME" ] || [ -z "$OPERATOR_NAME" ]; then
  echo "Error: -n, -d, -o are all required" >&2
  echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [project_dir]" >&2
  exit 1
fi

# codex resume 用 UUID 解決
resolve_codex_uuid() {
  local target="$1"
  if [[ "$target" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "$target"
    return 0
  fi
  if [ -d "$SESSIONS_DIR" ]; then
    local found_uuid
    found_uuid=$(grep -l "codex_operator_uuid" "$SESSIONS_DIR"/*"${SESSION_NAME}"*.md 2>/dev/null | \
      head -1 | \
      xargs -I{} grep -m1 "^codex_operator_uuid:" {} 2>/dev/null | \
      sed 's/^codex_operator_uuid:\s*//' | tr -d ' ')
    if [ -n "$found_uuid" ]; then
      echo "$found_uuid"
      return 0
    fi
  fi
  return 1
}

cmux_send_enter() {
  local workspace="$1"
  local text="$2"
  local surface="$3"
  cmux send --workspace "$workspace" --surface "$surface" "$text"
  sleep 0.3
  cmux send-key --workspace "$workspace" --surface "$surface" enter
}

# --- ワークスペース作成 ---
WORKSPACE_RESULT=$(cmux new-workspace --cwd "$PROJECT" --name "$SESSION_NAME" 2>&1)
WORKSPACE_ID=$(echo "$WORKSPACE_RESULT" | grep -oE 'workspace:[0-9]+')

if [ -z "$WORKSPACE_ID" ]; then
  echo "Error: Failed to create cmux workspace: $WORKSPACE_RESULT" >&2
  exit 1
fi

# ペイン分割
cmux new-split right --workspace "$WORKSPACE_ID" >/dev/null 2>&1
sleep 1

SURFACES=$(cmux tree --workspace "$WORKSPACE_ID" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -2)
DIVER_SURFACE=$(echo "$SURFACES" | head -1)
OPERATOR_SURFACE=$(echo "$SURFACES" | tail -1)

# diver: claude --resume
cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && claude --resume \"$DIVER_NAME\"" "$DIVER_SURFACE"

# operator: codex or claude --resume
if $OPERATOR_CODEX; then
  if codex_uuid=$(resolve_codex_uuid "$OPERATOR_NAME"); then
    echo "Resolved codex UUID: $codex_uuid" >&2
    cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access $codex_uuid" "$OPERATOR_SURFACE"
  else
    echo "Warning: codex UUID could not be resolved. Falling back to picker." >&2
    cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access" "$OPERATOR_SURFACE"
  fi
else
  cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && claude --resume \"$OPERATOR_NAME\"" "$OPERATOR_SURFACE"
fi

echo "two-man-dev resumed: $WORKSPACE_ID ($SESSION_NAME)"
echo "  diver:    $DIVER_SURFACE"
echo "  operator: $OPERATOR_SURFACE"
