#!/bin/bash
# usage: bash send.sh <target> "<message>"
#   target: diver | operator
# エージェント（diverまたはoperator）が使う。ユーザーは使わない。

TARGET="$1"
MESSAGE="$2"

# 呼び出し元のtmuxセッション名を自動検出
SESSION="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
if [ -z "$SESSION" ]; then
  echo "tmux session not found" >&2; exit 1
fi

case "$TARGET" in
  diver)    PANE="${SESSION}:0.0"; FROM="[from: operator]" ;;
  operator) PANE="${SESSION}:0.1"; FROM="[from: diver]" ;;
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
  tmux send-keys -t "$PANE" "${FROM} $TMPFILE を読め"
  tmux send-keys -t "$PANE" Enter
fi
