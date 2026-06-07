#!/bin/bash
# two-man-dev セッションの resume 起動
#
# 通常モード:
#   diver / operator 両方を claude --resume "<display name>" で復帰させる。
#
# --operator-codex モード（2026-05-11追加、2026-06-07 UUID解決を呼び出し側に移譲）:
#   diver は claude --resume "<display name>"。
#   operator は codex --resume <UUID> で復帰。
#
#   --codex-uuid で解決済みUUIDを渡す。未指定時は codex resume（picker）にフォールバック
#
# tmuxセッションは start.sh と同じ命名規則 (two-man-<name>) で作成。
# 命名規則 `${name} diver` / `${name} operator` に依存しているため、変更時は要検討。

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
      # オプションでなければ位置引数(PROJECT)として残す
      if [[ "$1" != -* ]]; then
        break
      fi
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

PROJECT="${1:-.}"

if [ -z "$SESSION_NAME" ] || [ -z "$DIVER_NAME" ] || [ -z "$OPERATOR_NAME" ]; then
  echo "Error: -n, -d, -o are all required" >&2
  echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [--codex-uuid <UUID>] [project_dir]" >&2
  exit 1
fi

TMUX_SESSION_NAME="two-man-${SESSION_NAME}"

# cmux内で起動された場合、CMUX環境変数をtmuxに引き継ぐ
CMUX_ENV_OPTS=()
if [ -n "$CMUX_WORKSPACE_ID" ]; then
  CMUX_ENV_OPTS+=(-e "CMUX_WORKSPACE_ID=$CMUX_WORKSPACE_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_SURFACE_ID=$CMUX_SURFACE_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_PANEL_ID=$CMUX_PANEL_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH")
  CMUX_ENV_OPTS+=(-e "CMUX_PORT=$CMUX_PORT")
fi

# operator codex の場合の UUID 解決
resolve_codex_uuid() {
  local target="$1"
  # UUID形式判定（8-4-4-4-12の hex）
  if [[ "$target" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "$target"
    return 0
  fi
  # セッション名から要約ファイル経由でUUID探索
  # SESSION_NAME 部分一致で要約ファイルを探す
  if [ -d "$SESSIONS_DIR" ]; then
    local found_uuid
    # SESSION_NAME から issue番号を抽出してファイル名検索
    local issue_num
    issue_num=$(echo "$SESSION_NAME" | grep -oE "[0-9]+" | head -1)
    local search_pattern="${issue_num:-${SESSION_NAME}}"

    found_uuid=$(grep -l "codex_operator_uuid" "$SESSIONS_DIR"/*"${search_pattern}"*.md 2>/dev/null | \
      sort -r | head -1 | \
      xargs -I{} grep -m1 "^codex_operator_uuid:" {} 2>/dev/null | \
      sed 's/^codex_operator_uuid:\s*//' | tr -d ' ')
    if [ -n "$found_uuid" ]; then
      echo "$found_uuid"
      return 0
    fi
  fi
  return 1
}

tmux new-session -d -s "$TMUX_SESSION_NAME" -x 220 -y 50 "${CMUX_ENV_OPTS[@]}"
tmux split-window -h -t "$TMUX_SESSION_NAME:0"

# diver: 通常通り claude --resume
tmux send-keys -t "$TMUX_SESSION_NAME:0.0" "cd $PROJECT && claude --resume \"$DIVER_NAME\"" Enter

# operator: codex の場合は UUID 解決、claude の場合は通常 resume
if $OPERATOR_CODEX; then
  if [ -n "$CODEX_UUID" ]; then
    echo "Using codex UUID: $CODEX_UUID" >&2
    tmux send-keys -t "$TMUX_SESSION_NAME:0.1" "cd $PROJECT && codex resume --sandbox danger-full-access $CODEX_UUID" Enter
  else
    echo "Warning: No codex UUID provided. Falling back to picker." >&2
    tmux send-keys -t "$TMUX_SESSION_NAME:0.1" "cd $PROJECT && codex resume --sandbox danger-full-access" Enter
  fi
else
  tmux send-keys -t "$TMUX_SESSION_NAME:0.1" "cd $PROJECT && claude --resume \"$OPERATOR_NAME\"" Enter
fi

tmux attach -t "$TMUX_SESSION_NAME"
