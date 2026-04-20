#!/bin/bash
# two-man-dev セッションの resume 起動
#
# diver / operator 両方を claude --resume "<display name>" で復帰させる。
# tmuxセッションは start.sh と同じ命名規則 (two-man-<name>) で作成。
# 命名規則 `${name} diver` / `${name} operator` に依存しているため、変更時は要検討。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_NAME=""
DIVER_NAME=""
OPERATOR_NAME=""
while getopts "n:d:o:" opt; do
  case $opt in
    n) SESSION_NAME="$OPTARG" ;;
    d) DIVER_NAME="$OPTARG" ;;
    o) OPERATOR_NAME="$OPTARG" ;;
    *) echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [project_dir]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROJECT="${1:-.}"

if [ -z "$SESSION_NAME" ] || [ -z "$DIVER_NAME" ] || [ -z "$OPERATOR_NAME" ]; then
  echo "Error: -n, -d, -o are all required" >&2
  echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [project_dir]" >&2
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

tmux new-session -d -s "$TMUX_SESSION_NAME" -x 220 -y 50 "${CMUX_ENV_OPTS[@]}"
tmux split-window -h -t "$TMUX_SESSION_NAME:0"

# resume時はロール再伝達不要（コンテキストに既に含まれる）
tmux send-keys -t "$TMUX_SESSION_NAME:0.0" "cd $PROJECT && claude --resume \"$DIVER_NAME\"" Enter
tmux send-keys -t "$TMUX_SESSION_NAME:0.1" "cd $PROJECT && claude --resume \"$OPERATOR_NAME\"" Enter

tmux attach -t "$TMUX_SESSION_NAME"
