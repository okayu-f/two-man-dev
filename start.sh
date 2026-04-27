#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# オプション解析
SESSION_NAME=""
while getopts "n:" opt; do
  case $opt in
    n) SESSION_NAME="$OPTARG" ;;
    *) echo "usage: $0 [-n session_name] [project_dir]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

PROJECT="${1:-.}"

# セッション名: 指定なしならプロジェクト名から自動生成
if [ -z "$SESSION_NAME" ]; then
  SESSION_NAME="two-man-$(basename "$(cd "$PROJECT" && pwd)")"
else
  SESSION_NAME="two-man-${SESSION_NAME}"
fi

ROLE_MSG_DIVER="あなたはdiverです。${SCRIPT_DIR}/diver.md を読んで理解してください。
operatorに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

ROLE_MSG_OPERATOR="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

# cmux内で起動された場合、CMUX環境変数をtmuxに引き継ぐ
CMUX_ENV_OPTS=()
if [ -n "$CMUX_WORKSPACE_ID" ]; then
  CMUX_ENV_OPTS+=(-e "CMUX_WORKSPACE_ID=$CMUX_WORKSPACE_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_SURFACE_ID=$CMUX_SURFACE_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_PANEL_ID=$CMUX_PANEL_ID")
  CMUX_ENV_OPTS+=(-e "CMUX_SOCKET_PATH=$CMUX_SOCKET_PATH")
  CMUX_ENV_OPTS+=(-e "CMUX_PORT=$CMUX_PORT")
fi

tmux new-session -d -s "$SESSION_NAME" -x 220 -y 50 "${CMUX_ENV_OPTS[@]}"
tmux split-window -h -t "$SESSION_NAME:0"

tmux send-keys -t "$SESSION_NAME:0.0" "cd $PROJECT && claude \"$ROLE_MSG_DIVER\"" Enter
tmux send-keys -t "$SESSION_NAME:0.1" "cd $PROJECT && claude \"$ROLE_MSG_OPERATOR\"" Enter

tmux attach -t "$SESSION_NAME"
