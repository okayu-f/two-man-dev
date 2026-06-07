#!/bin/bash
# cmux ネイティブ版の two-man-dev セッション起動
# tmux を使わず、cmux の workspace + split で diver/operator を起動する。
#
# 使い方:
#   bash start-cmux.sh [-n session_name] [--operator-codex] [project_dir]
#
# 前提: cmux が起動していること。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_NAME=""
OPERATOR_CODEX=false
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
PROJECT="$(cd "$PROJECT" && pwd)"

if [ -z "$SESSION_NAME" ]; then
  SESSION_NAME="two-man-$(basename "$PROJECT")"
fi

ROLE_MSG_DIVER="あなたはdiverです。${SCRIPT_DIR}/diver.md を読んで理解してください。
operatorに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

ROLE_MSG_OPERATOR_CLAUDE="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。
依頼はこの後送ります。"

ROLE_MSG_OPERATOR_CODEX="あなたはoperatorです。${SCRIPT_DIR}/operator.md を読んで理解してください。
diverに連絡したいときは、${SCRIPT_DIR}/send.sh を利用してもらえば連絡ができるはずです。

【最初にやること: 自分のセッションUUIDを diver に伝える】
codex には起動時の名前指定機能がないため、後で resume するには UUID が必要です。
あなた自身のセッションUUIDを以下の手順で取得し、diverに送ってください:

1. ls -t ~/.codex/sessions/\$(date +%Y/%m/%d)/rollout-*.jsonl | head -3 で最新のjsonlを確認
2. head -1 <該当jsonl> で session_meta を確認し、cwd が現在の作業ディレクトリと一致するものを特定
3. その jsonl のファイル名から末尾の UUID 部分を抽出
4. bash ${SCRIPT_DIR}/send.sh diver \"私のセッションUUIDは <UUID> です。後で resume するときに使ってください。\" でdiverに通知

依頼はこの後送ります。"

cmux_send_enter() {
  local workspace="$1"
  local text="$2"
  local surface="$3"
  cmux send --workspace "$workspace" --surface "$surface" "$text"
  sleep 0.3
  cmux send-key --workspace "$workspace" --surface "$surface" enter
}

# --- ワークスペース作成 ---
WORKSPACE_RESULT=$(cmux new-workspace --cwd "$PROJECT" --name "$SESSION_NAME" 2>&1)
WORKSPACE_ID=$(echo "$WORKSPACE_RESULT" | grep -oE 'workspace:[0-9]+')

if [ -z "$WORKSPACE_ID" ]; then
  echo "Error: Failed to create cmux workspace: $WORKSPACE_RESULT" >&2
  exit 1
fi

# ペイン分割
cmux new-split right --workspace "$WORKSPACE_ID" >/dev/null 2>&1
sleep 1

SURFACES=$(cmux tree --workspace "$WORKSPACE_ID" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -2)
DIVER_SURFACE=$(echo "$SURFACES" | head -1)
OPERATOR_SURFACE=$(echo "$SURFACES" | tail -1)

# diver 起動
cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && claude" "$DIVER_SURFACE"

# operator 起動
if $OPERATOR_CODEX; then
  cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && codex --sandbox danger-full-access" "$OPERATOR_SURFACE"
else
  cmux_send_enter "$WORKSPACE_ID" "cd \"$PROJECT\" && claude" "$OPERATOR_SURFACE"
fi

# claude/codex 起動を待つ
sleep 8

# ロールメッセージ送信
cmux_send_enter "$WORKSPACE_ID" "$ROLE_MSG_DIVER" "$DIVER_SURFACE"
if $OPERATOR_CODEX; then
  cmux_send_enter "$WORKSPACE_ID" "$ROLE_MSG_OPERATOR_CODEX" "$OPERATOR_SURFACE"
else
  cmux_send_enter "$WORKSPACE_ID" "$ROLE_MSG_OPERATOR_CLAUDE" "$OPERATOR_SURFACE"
fi

echo "two-man-dev started: $WORKSPACE_ID ($SESSION_NAME)"
echo "  diver:    $DIVER_SURFACE"
echo "  operator: $OPERATOR_SURFACE"
