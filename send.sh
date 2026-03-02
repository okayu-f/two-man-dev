#!/bin/bash
# usage: bash send.sh <target> "<message>"
#   target: diver | operator
# エージェント（diverまたはoperator）が使う。ユーザーは使わない。

TARGET="$1"
MESSAGE="$2"

case "$TARGET" in
  diver)    PANE="two-man-dev:0.0"; FROM="[from: operator]" ;;
  operator) PANE="two-man-dev:0.1"; FROM="[from: diver]" ;;
  *) echo "target: diver or operator" >&2; exit 1 ;;
esac

MESSAGE="${FROM} ${MESSAGE}"

TMPFILE="/tmp/two-man-dev-msg-$$.md"
mkdir -p /tmp

if [ ${#MESSAGE} -le 500 ]; then
  tmux send-keys -t "$PANE" "$MESSAGE"
  tmux send-keys -t "$PANE" Enter
else
  echo "$MESSAGE" > "$TMPFILE"
  tmux send-keys -t "$PANE" "$TMPFILE を読め"
  tmux send-keys -t "$PANE" Enter
fi
