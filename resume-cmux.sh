#!/bin/bash
# cmux ネイティブ版の two-man-dev セッション resume
#
# 使い方:
#   bash resume-cmux.sh -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [--codex-uuid <UUID>] [project_dir]
#
# --codex-uuid: operator が codex の場合、解決済みの UUID を渡す。
#   指定なしの場合は codex のピッカー（対話式選択）にフォールバック。
#
# 前提: cmux が起動していること。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_NAME=""
DIVER_NAME=""
OPERATOR_NAME=""
OPERATOR_CODEX=false
CODEX_UUID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) SESSION_NAME="$2"; shift 2 ;;
    -d) DIVER_NAME="$2"; shift 2 ;;
    -o) OPERATOR_NAME="$2"; shift 2 ;;
    --operator-codex) OPERATOR_CODEX=true; shift ;;
    --codex-uuid) CODEX_UUID="$2"; shift 2 ;;
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
  echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [--codex-uuid <UUID>] [project_dir]" >&2
  exit 1
fi

cmux_send_enter() {
  local workspace="$1"
  local text="$2"
  local surface="$3"
  cmux send --workspace "$workspace" --surface "$surface" "$text"
  sleep 0.3
  cmux send-key --workspace "$workspace" --surface "$surface" enter
}

# --- ワークスペース作成 ---
# CMUX_TARGET_WINDOW が設定されていればそのウィンドウに作成（未設定なら呼び出し元ウィンドウ）
WINDOW_ARGS=()
if [ -n "${CMUX_TARGET_WINDOW:-}" ]; then
  WINDOW_ARGS=(--window "$CMUX_TARGET_WINDOW")
fi
WORKSPACE_RESULT=$(cmux new-workspace --cwd "$PROJECT" --name "$SESSION_NAME" "${WINDOW_ARGS[@]}" 2>&1)
WORKSPACE_ID=$(echo "$WORKSPACE_RESULT" | grep -oE 'workspace:[0-9]+')

if [ -z "$WORKSPACE_ID" ] && [ ${#WINDOW_ARGS[@]} -gt 0 ]; then
  # 指定ウィンドウが存在しない場合のフォールバック
  WORKSPACE_RESULT=$(cmux new-workspace --cwd "$PROJECT" --name "$SESSION_NAME" 2>&1)
  WORKSPACE_ID=$(echo "$WORKSPACE_RESULT" | grep -oE 'workspace:[0-9]+')
fi

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
  if [ -n "$CODEX_UUID" ]; then
    echo "Using codex UUID: $CODEX_UUID" >&2
    cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access $CODEX_UUID" "$OPERATOR_SURFACE"
  else
    echo "Warning: No codex UUID provided. Falling back to picker." >&2
    cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access" "$OPERATOR_SURFACE"
  fi
else
  cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && claude --resume \"$OPERATOR_NAME\"" "$OPERATOR_SURFACE"
fi

echo "two-man-dev resumed: $WORKSPACE_ID ($SESSION_NAME)"
echo "  diver:    $DIVER_SURFACE"
echo "  operator: $OPERATOR_SURFACE"
