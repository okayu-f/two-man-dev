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

# tmux send-keys の本文送信→Enter の間に sleep を挟む
# Codex CLI は長文ペースト処理に時間がかかるため、即Enter送信だと無視される（2026-04-30 検証）
# Claude Code は0でも動くが、Codex 互換のため0.5sでロバスト化
if [ ${#MESSAGE} -le 500 ]; then
  tmux send-keys -t "$PANE" "$MESSAGE"
  sleep 0.5
  tmux send-keys -t "$PANE" Enter
else
  echo "$MESSAGE" > "$TMPFILE"
  tmux send-keys -t "$PANE" "${FROM} $TMPFILE を読め"
  sleep 0.5
  tmux send-keys -t "$PANE" Enter
fi
