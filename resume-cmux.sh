#!/bin/bash
# cmux ネイティブ版の two-man-dev セッション resume
#
# 使い方:
#   bash resume-cmux.sh -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [--codex-uuid <UUID>] [project_dir]
#
# --codex-uuid: operator が codex の場合、解決済みの UUID を渡す。
#   指定なしの場合は codex のピッカー（対話式選択）にフォールバック。
#
# 前提: cmux が起動していること。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SESSION_NAME=""
DIVER_NAME=""
OPERATOR_NAME=""
OPERATOR_CODEX=false
CODEX_UUID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -n) SESSION_NAME="$2"; shift 2 ;;
    -d) DIVER_NAME="$2"; shift 2 ;;
    -o) OPERATOR_NAME="$2"; shift 2 ;;
    --operator-codex) OPERATOR_CODEX=true; shift ;;
    --codex-uuid) CODEX_UUID="$2"; shift 2 ;;
    *)
      if [[ "$1" != -* ]]; then
        break
      fi
      echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

PROJECT="${1:-.}"
PROJECT="$(cd "$PROJECT" && pwd)"

if [ -z "$SESSION_NAME" ] || [ -z "$DIVER_NAME" ] || [ -z "$OPERATOR_NAME" ]; then
  echo "Error: -n, -d, -o are all required" >&2
  echo "usage: $0 -n <session_name> -d <diver_display_name> -o <operator_display_name> [--operator-codex] [--codex-uuid <UUID>] [project_dir]" >&2
  exit 1
fi

# --- 確かめて、不明なら止まるガード（同梱の cmux-guard.sh・base 非依存）---
# 2026-10-14: 作成は1回だけ／実体（返却ID・title完全一致・指定window）で成功判定／分割は同じ workspace の異なる2surface確認／ready未確認・信頼確認は止まる。
# 2026-10-15 (v5): cmux 0.65.1 では、send が cold（tty 未付与）な端末の起動を促す（10/15 実機で queued 応答と起動を確認）ため、前段の tty 待ちは不要。作成・分割では tty を待たない。
#   最初の shell 1行（queued 応答も受付）で起動を促し、ready は deadline 付きで確認する。未確認は「キューが後から動く可能性あり」として
#   UUID・名前・停止段階つきで報告し、再送・再作成しない。失敗時は非0で終了し、「started」とは報告しない。
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cmux-guard.sh" || { echo "Error: $SCRIPT_DIR/cmux-guard.sh を読み込めません" >&2; exit 1; }

STAGE="作成前"

# ラッパーの引数順は guard と同じ (workspace, surface, text)。v4 はここを (ws, text, surface) で呼んで取り違えた。名前つきで受けて渡す
send_shell() {  # シェルへの1行（cd … && claude）。受付（queued 含む）まで。起動の成功は後段の ready 確認で見る
  local ws="$1" surface="$2" text="$3" rc=0 kind=""
  cg_send_shell "$ws" "$surface" "$text" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Error: 送信に失敗しました。以降の起動・送信を止めます" >&2
    # rc 1=明示的な拒否（拒否と確認できたときだけ）。2・3=受付不明（非0でも本文は受付済みの可能性あり）
    # rc 4=未送信の停止（stderr の記録用の一時ファイルを作れず、send を呼んでいない。受付不明ではない）
    if [ "$rc" -eq 4 ]; then kind="unsent"; elif [ "$rc" -ge 2 ]; then kind="unknown"; fi
    cg_report_stop "$ws" "$SESSION_NAME" "${STAGE}→起動行の送信で停止（rc=${rc}）" "$surface" "$kind"
    exit 3
  fi
  STAGE="起動行を送信済み（${surface}・受付まで。起動は未確認）"
}
send_agent() {  # エージェントへの依頼文（ready確認→送信→受理確認）
  local ws="$1" surface="$2" text="$3" rc=0 kind=""
  cg_send_agent "$ws" "$surface" "$text" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Error: 送信を確認できませんでした。以降の起動・送信を止めます" >&2
    # rc 5=送信後に受理を確認できず、6=受付不明。本文は受付済みの可能性あり
    if [ "$rc" -eq 4 ]; then kind="unsent"; elif [ "$rc" -ge 5 ]; then kind="unknown"; fi
    cg_report_stop "$ws" "$SESSION_NAME" "ready 確認後の依頼文の送信・受理で停止（rc=${rc}・直前の段階: ${STAGE}）" "$surface" "$kind"
    exit 3
  fi
}
# ready を確認する。信頼確認・未確認は止まる（自動承認しない・再送しない・作り直さない）
agent_ready_or_stop() {  # <label> <surface>
  local label="$1" surface="$2" rc=0
  cg_wait_agent_ready "$WORKSPACE_ID" "$surface" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 3 ]; then
      cg_report_stop "$WORKSPACE_ID" "$SESSION_NAME" "${label} が信頼確認画面で停止" "$surface"
    else
      cg_report_stop "$WORKSPACE_ID" "$SESSION_NAME" "${label} の起動行は受付済み・ready 未確認" "$surface" pending
    fi
    echo "Error: ${label} が ready と確認できません（${WORKSPACE_ID}）。以降の送信は止めます" >&2
    exit 4
  fi
}

# --- ワークスペース作成（1回だけ。受付不明・同名あり・一覧取得失敗・名前/window の不一致は止まる。作り直さない。tty は待たない）---
# CMUX_TARGET_WINDOW が設定されていればそのウィンドウに作成（未設定なら呼び出し元ウィンドウ）
WORKSPACE_ID=$(cg_create_workspace "$SESSION_NAME" "$PROJECT" "${CMUX_TARGET_WINDOW:-}") || {
  echo "Error: ワークスペースを確実に作成できませんでした（再作成はしません）: $SESSION_NAME" >&2
  exit 1
}
STAGE="作成済み（分割前）"

# ペイン分割：成功と、同じ workspace に属する異なる2つの surface が確定するまで起動・送信しない（tty は待たない）
SURFACES=$(cg_split_two "$WORKSPACE_ID") || {
  cg_report_stop "$WORKSPACE_ID" "$SESSION_NAME" "分割（surface 確認）で停止"
  exit 1
}
DIVER_SURFACE=$(echo "$SURFACES" | awk '{print $1}')
OPERATOR_SURFACE=$(echo "$SURFACES" | awk '{print $2}')
STAGE="分割済み（起動行の送信前）"

# diver: claude --resume（新規の未使用 surface への最初の shell 1行。tty は待たず、send が起動を促す）
send_shell "$WORKSPACE_ID" "$DIVER_SURFACE" "cd \"$PROJECT\" && claude --resume \"$DIVER_NAME\""

# operator: codex or claude --resume
if $OPERATOR_CODEX; then
  if [ -n "$CODEX_UUID" ]; then
    echo "Using codex UUID: $CODEX_UUID" >&2
    send_shell "$WORKSPACE_ID" "$OPERATOR_SURFACE" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access $CODEX_UUID"
  else
    echo "Warning: No codex UUID provided. Falling back to picker." >&2
    send_shell "$WORKSPACE_ID" "$OPERATOR_SURFACE" "cd \"$PROJECT\" && codex resume --sandbox danger-full-access"
  fi
else
  send_shell "$WORKSPACE_ID" "$OPERATOR_SURFACE" "cd \"$PROJECT\" && claude --resume \"$OPERATOR_NAME\""
fi

# resume 後の ready を確認する（picker 待ちは ready ではない）。codex を UUID なしで起動した場合は選択画面が出るので確認を省く
agent_ready_or_stop "diver" "$DIVER_SURFACE"
OPERATOR_STATE="ready"
if ! $OPERATOR_CODEX || [ -n "$CODEX_UUID" ]; then
  agent_ready_or_stop "operator" "$OPERATOR_SURFACE"
else
  OPERATOR_STATE="picker_waiting"   # UUID なしの codex resume は選択画面で本人の選択待ち（再開は未確認）
fi

if [ "$OPERATOR_STATE" = "picker_waiting" ]; then
  # 実画面を確認した結果ではなく、「人の選択待ち」として保留した状態。resume 完了とは表示しない
  echo "two-man-dev workspace created (resume 未完了・operator は選択待ち): $WORKSPACE_ID ($SESSION_NAME)"
else
  echo "two-man-dev resumed: $WORKSPACE_ID ($SESSION_NAME)"
fi
echo "  diver:    $DIVER_SURFACE"
echo "  operator: $OPERATOR_SURFACE"
echo "  operator_state: $OPERATOR_STATE"
