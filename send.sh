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

# --- workspace逆引き（CMUX_WORKSPACE_ID未設定時のフォールバック） ---
# 自分のtty(ttysNNN)を取得し、`cmux tree --all` の出力と突き合わせて
# 自分が所属するworkspaceを逆引きする。operatorのシェルに
# CMUX_WORKSPACE_ID が無くtmuxフォールバックに落ちて通信不達になる事故
# （2026-07-07, workspace:65）の再発防止。
resolve_workspace_from_tty() {
  local my_tty
  my_tty="$(tty 2>/dev/null)"
  my_tty="${my_tty#/dev/}"
  if [ -z "$my_tty" ] || [ "$my_tty" = "not a tty" ]; then
    my_tty="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
  fi
  if [ -z "$my_tty" ] || [ "$my_tty" = "?" ] || [ "$my_tty" = "??" ]; then
    return 1
  fi

  local found_ws
  found_ws=$(cmux tree --all 2>/dev/null | awk -v want="$my_tty" '
    {
      if (match($0, /workspace:[0-9]+/)) {
        cur_ws = substr($0, RSTART, RLENGTH)
      }
      if (match($0, /tty=[a-zA-Z0-9]+/)) {
        t = substr($0, RSTART + 4, RLENGTH - 4)
        if (t == want) {
          print cur_ws
          exit
        }
      }
    }
  ')

  if [ -z "$found_ws" ]; then
    return 1
  fi
  echo "$found_ws"
  return 0
}

if [ -z "$CMUX_WORKSPACE_ID" ] && command -v cmux >/dev/null 2>&1; then
  RESOLVED_WS="$(resolve_workspace_from_tty)"
  if [ -n "$RESOLVED_WS" ]; then
    CMUX_WORKSPACE_ID="$RESOLVED_WS"
  fi
fi

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

elif command -v tmux >/dev/null 2>&1 && [ -n "$(tmux display-message -p '#{session_name}' 2>/dev/null)" ]; then
  # tmux モード（従来互換）
  SESSION="$(tmux display-message -p '#{session_name}' 2>/dev/null)"

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
  echo "Error: 送信先workspaceを特定できませんでした（tty逆引き失敗・tmuxセッションも検出不可）。" >&2
  echo "CMUX_WORKSPACE_ID=workspace:NN を付けて再実行してください（NNは 'cmux tree --all' で確認できる自分のworkspace番号）。" >&2
  echo "例: CMUX_WORKSPACE_ID=workspace:12 bash send.sh $TARGET \"...\"" >&2
  exit 1
fi
