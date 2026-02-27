#!/bin/bash
# usage: bash send.sh <target> "<message>"
#   target: impl | advisor
# エージェント（implまたはadvisor）が使う。ユーザーは使わない。

TARGET="$1"
MESSAGE="$2"

case "$TARGET" in
  impl)    PANE="pair-dev:0.0" ;;
  advisor) PANE="pair-dev:0.1" ;;
  *) echo "target: impl or advisor" >&2; exit 1 ;;
esac

TMPFILE="/tmp/pair-dev-msg-$$.md"
mkdir -p /tmp

if [ ${#MESSAGE} -le 500 ]; then
  tmux send-keys -t "$PANE" "$MESSAGE"
  tmux send-keys -t "$PANE" Enter
else
  echo "$MESSAGE" > "$TMPFILE"
  tmux send-keys -t "$PANE" "$TMPFILE を読め"
  tmux send-keys -t "$PANE" Enter
fi
