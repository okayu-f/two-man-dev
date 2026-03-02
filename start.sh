#!/bin/bash
PROJECT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ROLE_MSG_DIVER="あなたはdiverです。${SCRIPT_DIR}/diver.md を読んで理解してください。
operatorに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

ROLE_MSG_OPERATOR="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

tmux new-session -d -s two-man-dev -x 220 -y 50
tmux split-window -h -t two-man-dev:0

tmux send-keys -t two-man-dev:0.0 "cd $PROJECT && claude \"$ROLE_MSG_DIVER\"" Enter
tmux send-keys -t two-man-dev:0.1 "cd $PROJECT && claude \"$ROLE_MSG_OPERATOR\"" Enter

tmux attach -t two-man-dev
