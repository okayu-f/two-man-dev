#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# オプション解析
SESSION_NAME=""
OPERATOR_CODEX=false
# getopts は long-option 非対応なので while で先に長いオプションを抜き出す
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator-codex) OPERATOR_CODEX=true; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

while getopts "n:" opt; do
  case $opt in
    n) SESSION_NAME="$OPTARG" ;;
    *) echo "usage: $0 [-n session_name] [--operator-codex] [project_dir]" >&2; exit 1 ;;
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

ROLE_MSG_OPERATOR_CLAUDE="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

# codex operator 用: 自分のセッションUUIDを取得して diver に伝える初動タスクを追加
# (codex には起動時の名前指定機能がないため、resume 時の識別子として UUID が必要)
ROLE_MSG_OPERATOR_CODEX="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。

【最初にやること: 自分のセッションUUIDを diver に伝える】
codex には起動時の名前指定機能がないため、後で resume するには UUID が必要です。
あなた自身のセッションUUIDを以下の手順で取得し、diverに送ってください:

1. ls -t ~/.codex/sessions/\$(date +%Y/%m/%d)/rollout-*.jsonl | head -3 で最新のjsonlを確認
2. head -1 <該当jsonl> で session_meta を確認し、cwd が現在の作業ディレクトリと一致するものを特定
3. その jsonl のファイル名から末尾の UUID 部分を抽出 (例: rollout-2026-05-11T13-53-13-019e1561-d3c1-7b31-9b1b-4aea3cdd793b.jsonl の 019e1561-d3c1-7b31-9b1b-4aea3cdd793b)
4. bash ${SCRIPT_DIR}/send.sh diver \"私のセッションUUIDは <UUID> です。後で resume するときに使ってください。\" でdiverに通知

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

# diver/operator を素のコマンドで起動 (改行を含むメッセージをシェルに渡すと
# zsh の cmdand dquote> プロンプトで詰まるため、起動後に send-keys で paste する)

# diver 起動
tmux send-keys -t "$SESSION_NAME:0.0" "cd $PROJECT && claude" Enter
# operator 起動 (claude or codex)
if $OPERATOR_CODEX; then
  tmux send-keys -t "$SESSION_NAME:0.1" "cd $PROJECT && codex --sandbox danger-full-access" Enter
else
  tmux send-keys -t "$SESSION_NAME:0.1" "cd $PROJECT && claude" Enter
fi

# claude/codex の起動を待つ
sleep 8

# role message を paste (改行は send-keys が解釈、最後に Enter で確定)
tmux send-keys -t "$SESSION_NAME:0.0" "$ROLE_MSG_DIVER"
sleep 0.3
tmux send-keys -t "$SESSION_NAME:0.0" Enter

if $OPERATOR_CODEX; then
  tmux send-keys -t "$SESSION_NAME:0.1" "$ROLE_MSG_OPERATOR_CODEX"
else
  tmux send-keys -t "$SESSION_NAME:0.1" "$ROLE_MSG_OPERATOR_CLAUDE"
fi
sleep 0.3
tmux send-keys -t "$SESSION_NAME:0.1" Enter

tmux attach -t "$SESSION_NAME"
