#!/bin/bash
# usage: bash send.sh <target> "<message>"
#   target: diver | operator
# エージェント（diverまたはoperator）が使う。ユーザーは使わない。
# tmux / cmux 両対応: 環境変数で自動判定。

TARGET="$1"
MESSAGE="$2"

case "$TARGET" in
  diver)    FROM="[from: operator]" ;;
  operator) FROM="[from: diver]" ;;
  *) echo "target: diver or operator" >&2; exit 1 ;;
esac

MESSAGE="${FROM} ${MESSAGE}"

# --- 送信先の特定 ---

if [ -n "$CMUX_WORKSPACE_ID" ]; then
  # cmux モード: tree から surface 一覧を取得し、自分でない方が相手
  SURFACES=$(cmux tree --workspace "$CMUX_WORKSPACE_ID" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -2)
  FIRST_SURFACE=$(echo "$SURFACES" | head -1)
  SECOND_SURFACE=$(echo "$SURFACES" | tail -1)

  # diver=1番目(FIRST), operator=2番目(SECOND)
  case "$TARGET" in
    diver)    TARGET_SURFACE="$FIRST_SURFACE" ;;
    operator) TARGET_SURFACE="$SECOND_SURFACE" ;;
  esac

  if [ -z "$TARGET_SURFACE" ]; then
    echo "Error: Could not detect target surface for $TARGET" >&2; exit 1
  fi

  # 送信
  if [ ${#MESSAGE} -le 500 ]; then
    cmux send --workspace "$CMUX_WORKSPACE_ID" --surface "$TARGET_SURFACE" "$MESSAGE"
    sleep 0.5
    cmux send-key --workspace "$CMUX_WORKSPACE_ID" --surface "$TARGET_SURFACE" enter
  else
    TMPFILE="/tmp/two-man-dev-msg-$$.md"
    echo "$MESSAGE" > "$TMPFILE"
    cmux send --workspace "$CMUX_WORKSPACE_ID" --surface "$TARGET_SURFACE" "${FROM} $TMPFILE を読め"
    sleep 0.5
    cmux send-key --workspace "$CMUX_WORKSPACE_ID" --surface "$TARGET_SURFACE" enter
  fi

elif command -v tmux >/dev/null 2>&1; then
  # tmux モード（従来互換）
  SESSION="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
  if [ -z "$SESSION" ]; then
    echo "tmux session not found" >&2; exit 1
  fi

  case "$TARGET" in
    diver)    PANE="${SESSION}:0.0" ;;
    operator) PANE="${SESSION}:0.1" ;;
  esac

  if [ ${#MESSAGE} -le 500 ]; then
    tmux send-keys -t "$PANE" "$MESSAGE"
    sleep 0.5
    tmux send-keys -t "$PANE" Enter
  else
    TMPFILE="/tmp/two-man-dev-msg-$$.md"
    echo "$MESSAGE" > "$TMPFILE"
    tmux send-keys -t "$PANE" "${FROM} $TMPFILE を読め"
    sleep 0.5
    tmux send-keys -t "$PANE" Enter
  fi

else
  echo "Error: Neither cmux nor tmux environment detected" >&2; exit 1
fi
