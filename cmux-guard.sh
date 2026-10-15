#!/bin/bash
# cmux-guard.sh — cmux ワークスペース起動の「確かめて、不明なら止まる」汎用ガード
# source して使う（単体実行はしない）。bash 3.2（macOS標準）で動く書き方。依存: cmux, jq, perl（macOS標準＋jq）
#
# 原則（2026-10-14 の外から4本発射での詰まりを受けた最小案・v5 は 10/15 の実機段階試験を反映）:
#   - 作成は1回だけ。「OK」の文字では成功としない。実体（JSONの返却ref/UUID・title完全一致・指定window）を見て判定する
#   - cmux 0.65.1 では、send が cold（tty 未付与）な端末の起動を促す（10/15 実機で queued 応答と起動を確認）。よって前段の tty 待ちは不要で、作成・分割の成功条件に tty は使わない
#     （「表示か send まで必ず起動しない」という一般仕様は断定しない。通常の background 起動で tty が即付くこともある）
#     （tty を待ってから送ると、誰も開かない限り止まる）。新規の未使用 surface への最初の shell 1行を「起動の要求」とし、
#     その後 cg_wait_agent_ready の deadline で ready を確認する。send の応答が queued でも「受付」として扱うが、起動成功ではない
#   - 取得失敗・終了コード異常・受付不明・ready 未確認は、作り直さず非0で止まる（呼び出し側は先へ進まない）
#   - ready 未確認は「失敗」ではなく「キューが後から動く可能性あり」として報告する（cg_report_stop）。再送・再作成しない
#   - 送る前に「その surface が指定 workspace に属する」ことを tree で確かめる（引数の取り違えで別の surface・文字列を宛先にしない）
#   - 信頼確認らしき画面は自動承認しない（止めて画面を見せる）。focus/select 操作は一切しない
#   - 待ち時間は「呼び出しの所要時間を含む deadline（秒）」で制限する
#
# 関数の引数順は、送信系はすべて (workspace, surface, text)。呼び出し側のラッパーも同じ順に揃えること（v4 はここが食い違って止まった）
# 戻り値の約束（関数ごとに下記）。0=確認できた／それ以外=止まる

cg_log() { echo "[cmux-guard] $*" >&2; }

# コマンドを秒数で打ち切る。perl の alarm で exec するので、PATH 上のコマンドだけ使える
cg_run() {
  local cap="$1"; shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$cap" "$@"
}

# deadline（epoch秒）までの残りを cap で頭打ちにした、各呼び出し用の秒数（最小1）
cg_cap() {
  local deadline="$1" cap="$2" rem
  rem=$(( deadline - $(date +%s) ))
  [ "$rem" -lt 1 ] && rem=1
  [ "$rem" -gt "$cap" ] && rem="$cap"
  echo "$rem"
}

# cmux を呼び、stdout と stderr を分けて受ける（v5.2）。結果: CG_OUT=stdout / CG_ERR=stderr / 戻り値=終了コード
#   - 受付などの判定は stdout だけで行う。stderr（cmux 0.65.1 の注意行など）は判定に混ぜず、捨てずにログへ残す（cg_log。CG_STDERR_LOG があればそのファイルにも追記）
#   - CMUX_QUIET=1 を付けて注意行を抑える。ただし、これで stderr が消える保証とは扱わない（出ても判定は変わらない）
#   - **stderr 用の一時ファイルを作れないときは、cmux を呼ばずに（未実行のまま）終了コード97で止まる**（v5.3。記録保証のため。stderr を捨てて続行しない）。
#     tree・作成・分割・送信・画面読み取りのすべての呼び出しで同じ。このとき CG_CAPTURE_UNSENT=1 を立て、理由を cg_log に出す（再試行はしない）。
#     ※ `$( … )` の中で呼ばれた場合は変数が親に戻らないので、呼び出し側は戻り値（97）でも判断すること
#   - tree・read-screen はポーリングで何度も呼ばれるため、stderr は CG_STDERR_LOG への追記と、失敗時（終了コード非0）のコンソール表示だけにする
#   usage: cg_cmux_capture <ラベル> <timeout秒> <cmux のサブコマンドと引数…>
CG_CAPTURE_UNSENT=0
cg_cmux_capture() {
  local label="$1" cap="$2" errf="" rc=0 poll=0; shift 2
  CG_OUT=""; CG_ERR=""; CG_CAPTURE_UNSENT=0
  case "$label" in tree|read-screen) poll=1 ;; esac
  if ! errf="$(mktemp "${TMPDIR:-/tmp}/cg-stderr.XXXXXX" 2>/dev/null)" || [ -z "$errf" ]; then
    CG_CAPTURE_UNSENT=1
    cg_log "Error: stderr の記録用の一時ファイルを作れないため、cmux（${label}）を呼ばずに停止します（未実行。stderr を捨てて続行はしません・再試行もしません）"
    return 97
  fi
  CG_OUT="$(CMUX_QUIET=1 cg_run "$cap" cmux "$@" 2>"$errf")" || rc=$?
  CG_ERR="$(cat "$errf" 2>/dev/null || true)"
  rm -f "$errf"
  if [ -n "$CG_ERR" ]; then
    if [ "$poll" -eq 0 ] || [ "$rc" -ne 0 ]; then
      cg_log "cmux stderr（${label}・判定には使いません）: ${CG_ERR}"
    fi
    [ -n "${CG_STDERR_LOG:-}" ] && printf '[%s] %s\n' "$label" "$CG_ERR" >> "$CG_STDERR_LOG" 2>/dev/null
  fi
  return "$rc"
}

# --- 実体の読み取り（JSON） ---
# 一覧取得に失敗（無応答・JSONでない）したら非0。空一覧に読み替えない
cg_tree_json() {
  local deadline="${1:-$(( $(date +%s) + 10 ))}" out rc=0
  cg_cmux_capture "tree" "$(cg_cap "$deadline" 10)" tree --all --json || rc=$?
  [ "$rc" -eq 0 ] || return 1
  out="$CG_OUT"
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -e '.windows' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# 名前（title）が完全一致するワークスペースの ref を出す。 0=あり / 1=なし / 2=一覧取得失敗
cg_find_ws_by_title() {
  local name="$1" deadline="${2:-}" json refs
  json="$(cg_tree_json ${deadline:+"$deadline"})" || return 2
  refs="$(printf '%s' "$json" | jq -r --arg n "$name" '.windows[]?.workspaces[]? | select(.title == $n) | .ref')" || return 2
  [ -n "$refs" ] || return 1
  printf '%s\n' "$refs"
  return 0
}

# ワークスペース（ref か UUID）の surface（ref）を tree 順に出す（重複は除く）。tty の有無は問わない（cold な端末は send が起動を促すため）。取得失敗は非0
cg_ws_surfaces() {
  local ws="$1" deadline="${2:-}" json
  json="$(cg_tree_json ${deadline:+"$deadline"})" || return 1
  printf '%s' "$json" | jq -r --arg w "$ws" \
    '.windows[]?.workspaces[]? | select(.ref == $w or .id == $w) | .panes[]?.surfaces[]? | .ref // empty' \
    | awk 'NF && !seen[$0]++'
}

# surface（ref か UUID）が workspace（ref か UUID）に属するか。 0=属する / 1=属さない（空・別 workspace・存在しない） / 2=一覧取得失敗
cg_surface_in_ws() {
  local ws="$1" surface="$2" deadline="${3:-}" json n
  [ -n "$ws" ] && [ -n "$surface" ] || return 1
  json="$(cg_tree_json ${deadline:+"$deadline"})" || return 2
  n="$(printf '%s' "$json" | jq -r --arg w "$ws" --arg s "$surface" \
    '[.windows[]?.workspaces[]? | select(.ref == $w or .id == $w) | .panes[]?.surfaces[]? | select(.ref == $s or (.id // "") == $s)] | length')" || return 2
  [ "$n" -ge 1 ] 2>/dev/null
}

# ワークスペースの UUID（記録・照合用）。ref でも UUID でも引ける
cg_ws_uuid() {
  local ws="$1" json
  json="$(cg_tree_json)" || return 1
  printf '%s' "$json" | jq -r --arg w "$ws" '.windows[]?.workspaces[]? | select(.ref == $w or .id == $w) | .id' | head -1
}

# surface が <want> 個（異なるもの）以上揃うまで待つ（tty は見ない）。揃えば出力して 0。deadline 内に揃わなければ 1
cg_wait_surfaces() {
  local ws="$1" want="$2" secs="${3:-60}" deadline list n
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    list="$(cg_ws_surfaces "$ws" "$deadline" || true)"
    n="$(printf '%s\n' "$list" | awk 'NF' | wc -l | tr -d ' ')"
    if [ "$n" -ge "$want" ]; then
      printf '%s\n' "$list"
      return 0
    fi
    sleep 1
  done
  return 1
}

# 明示 window（ref / index / id）を、tree の JSON の .windows[] と突き合わせて ref に解決する。 0=解決（ref を出力） / 1=解決できない（不明） / 2=一覧取得失敗
# 実機（cmux 0.65.1）の JSON は .windows[] に ref（例 window:1000030000）と index（例 0）があり、id は無い（Codex が read-only で確認）。
# ref 一致を優先し、index（数字）か id が与えられた場合は対応表で ref へ解決する。引けなければ「不明」として呼び出し側が止まる（照合を省かない）
cg_resolve_window() {
  local window="$1" deadline="${2:-}" json ref
  json="$(cg_tree_json ${deadline:+"$deadline"})" || return 2
  ref="$(printf '%s' "$json" | jq -r --arg w "$window" \
    '[.windows[]? | select(.ref == $w or ((.index // null) != null and (.index | tostring) == $w) or (.id // "") == $w) | .ref // empty] | .[0] // empty')" || return 2
  [ -n "$ref" ] || return 1
  printf '%s\n' "$ref"
}

# 返却された workspace（ref か UUID）が、title 完全一致（window 指定時はその window 所属）で tree に載っているか。 0=一致
# <window> は cg_resolve_window で解決済みの ref（空なら window は照合対象外）
cg_ws_confirm() {
  local ws="$1" name="$2" window="$3" deadline="$4" json n
  json="$(cg_tree_json "$deadline")" || return 1
  n="$(printf '%s' "$json" | jq -r --arg w "$ws" --arg n "$name" --arg win "$window" \
    '[.windows[]? | select($win == "" or .ref == $win) | .workspaces[]? | select((.ref == $w or .id == $w) and .title == $n)] | length')" || return 1
  [ "$n" -ge 1 ] 2>/dev/null
}

# --- 作成（1回だけ） ---
# cg_create_workspace <名前> <cwd> [window] [待ち秒=60]
#   0=作成され、返却 ref／UUID と title 完全一致（window 指定時は所属 window も一致）を確認（返却された ref／UUID を標準出力）。tty は待たない
#   2=同名の確認（または window の解決）で一覧取得に失敗 / 3=同名が既にある / 4=作成の終了コード異常・受付不明（ref／UUID なし）
#   5=作成は受け付けられたが、deadline 内に「返却IDと名前・window の一致」を確認できず（壊れたと断定しない）
#   6=明示 window を tree の JSON から ref に解決できない（不明）。作成する前に止まる（window の照合を省いて作らない）
#   7=stderr の記録用の一時ファイルを作れず、new-workspace を呼ばずに停止（未作成。cmux は呼んでいない）
# どの失敗でも作り直さない。後片付けは人が実体を確認してから。
cg_create_workspace() {
  local name="$1" cwd="$2" window="${3:-}" secs="${4:-${CG_CREATE_WAIT:-60}}" rc out ws deadline window_ref
  rc=0; cg_find_ws_by_title "$name" >/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then
    cg_log "Error: ワークスペース一覧を取得できないため、同名確認ができません。作成しません"
    return 2
  elif [ "$rc" -eq 0 ]; then
    cg_log "Error: 同名のワークスペース「${name}」が既にあります。重複を避けるため作成しません"
    return 3
  fi

  # 明示 window は作成の前に ref へ解決する。解決できなければ「不明」として作らず止まる（window 指定なしのときだけ照合対象外）
  window_ref=""
  if [ -n "$window" ]; then
    rc=0; window_ref="$(cg_resolve_window "$window")" || rc=$?
    if [ "$rc" -eq 2 ]; then
      cg_log "Error: 一覧を取得できず、指定 window「${window}」を解決できません。作成しません"
      return 2
    elif [ "$rc" -ne 0 ]; then
      cg_log "Error: 指定 window「${window}」を tree の JSON（.windows[] の ref / index）から特定できません（不明）。window の照合を省いて作ることはせず、作成しません"
      return 6
    fi
  fi

  # 返却 ref／UUID は stdout だけから拾う（stderr の注意行や警告を ref の候補にしない。stderr は cg_cmux_capture がログへ残す）
  if [ -n "$window" ]; then
    rc=0; cg_cmux_capture "new-workspace" 30 new-workspace --cwd "$cwd" --name "$name" --window "$window" || rc=$?
  else
    rc=0; cg_cmux_capture "new-workspace" 30 new-workspace --cwd "$cwd" --name "$name" || rc=$?
  fi
  if [ "$CG_CAPTURE_UNSENT" = 1 ]; then
    cg_log "Error: 「${name}」の作成は未実行です（new-workspace を呼んでいません）。原因を直してから、人が状態を確認して再開してください"
    return 7
  fi
  out="$CG_OUT"
  ws="$(printf '%s\n' "$out" | grep -oE 'workspace:[0-9]+' | head -1 || true)"
  if [ -z "$ws" ]; then
    ws="$(printf '%s\n' "$out" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -1 || true)"
  fi
  if [ "$rc" -ne 0 ] || [ -z "$ws" ]; then
    cg_log "Error: 作成の結果が不明です（終了コード=${rc}）。受付後に遅れて現れる場合があるため再作成しません: ${out}"
    cg_log "  確認: cmux tree --all で「${name}」の有無を見る"
    return 4
  fi

  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if cg_ws_confirm "$ws" "$name" "$window_ref" "$deadline"; then
      printf '%s\n' "$ws"
      return 0
    fi
    sleep 1
  done
  cg_log "Error: ${ws} は受け付けられましたが、${secs}秒以内に「返却IDと名前（${name}）の一致${window_ref:+・window ${window_ref} への所属}」を確認できませんでした。作り直さず止まります"
  cg_log "  確認: cmux tree --all で ${ws} の title と所属 window を見る"
  return 5
}

# --- 分割（two-man 用） ---
# cg_split_two <ws> [待ち秒=60]  0=同じ workspace に属する異なる2つの surface を「diver operator」の順に出力 / 1=分割失敗 / 2=2つ揃わず / 3=stderr の記録用の一時ファイルを作れず、new-split を呼ばずに停止（未実行）
# tty は待たない（cold な端末は最初の send が起動を促す）
cg_split_two() {
  local ws="$1" secs="${2:-${CG_SPLIT_WAIT:-60}}" list a b
  if ! cg_cmux_capture "new-split" 20 new-split right --workspace "$ws" >/dev/null; then
    if [ "$CG_CAPTURE_UNSENT" = 1 ]; then
      cg_log "Error: ${ws} の分割は未実行です（new-split を呼んでいません）。起動・送信はしません"
      return 3
    fi
    cg_log "Error: ${ws} の new-split が失敗しました。起動・送信はしません"
    return 1
  fi
  list="$(cg_wait_surfaces "$ws" 2 "$secs")" || {
    cg_log "Error: ${ws} に異なる2つの surface が揃いませんでした。起動・送信はしません"
    return 2
  }
  a="$(printf '%s\n' "$list" | sed -n 1p)"
  b="$(printf '%s\n' "$list" | sed -n 2p)"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" = "$b" ]; then
    cg_log "Error: diver/operator の surface が確定しません（${a} / ${b}）"
    return 2
  fi
  printf '%s %s\n' "$a" "$b"
}

# --- 停止時の報告 ---
# cg_report_stop <ws> <名前> <停止段階> [surface] [pending|unknown]
#   UUID・名前・停止段階を出す。5番目が
#     pending : ready 未確認。「起動未確認・キューが後から動く可能性あり」を添える
#     unknown : 送信の timeout・応答が不明・Enter 失敗。「受付不明・本文は受付済みの可能性あり」を添える
#     unsent  : cmux を呼ぶ前に止まった（stderr の記録用の一時ファイルを作れない等）。「未送信・受付不明ではない」を添える（受付不明と混ぜない）
#   どちらも、再送・再作成はせず、直ちに取り消さない（人が表示して対象を確認してから扱う。表示した瞬間に遅れて実行されることがある）
cg_report_stop() {
  local ws="$1" name="$2" stage="$3" surface="${4:-}" kind="${5:-}" uuid
  uuid="$(cg_ws_uuid "$ws" 2>/dev/null || true)"
  cg_log "停止: 名前=「${name}」 workspace=${ws} UUID=${uuid:-不明（一覧を取得できず）}${surface:+ surface=${surface}} 停止段階=${stage}"
  if [ "$kind" = "pending" ]; then
    cg_log "  起動コマンドは「受付」までで、起動の成功は確認できていません。『失敗して何も届いていない』とは限らず、キューが後から実行される可能性があります（人が表示した瞬間に遅れて動くことがあります）"
  elif [ "$kind" = "unknown" ]; then
    cg_log "  送信の結果が不明です（受付不明）。本文は受付済みの可能性があり、端末のキューや入力欄に残っている場合もあります。『何も届いていない』とは限りません。直ちに取り消しもしません"
  fi
  if [ "$kind" = "unsent" ]; then
    cg_log "  この停止は「未送信」です（cmux の send を呼んでいません）。受付不明ではなく、本文は送られていません。原因（一時ファイルを作れない状態）を直してから、人が状態を確認して再開してください（スクリプトは自動で再試行しません）"
  fi
  cg_log "  同じ workspace への再送・再作成はしません。表示して cmux tree --all と画面を確認し、この UUID がどの段階まで進んだかを見て、対象を確認してから扱ってください"
}

# --- 画面の読み取り・状態判定 ---
# 見えている画面だけを読む（--lines は scrollback を含み、過去の履歴に反応するため使わない）
cg_read_screen() {
  local ws="$1" surface="$2" deadline="${3:-$(( $(date +%s) + 10 ))}" rc=0
  cg_cmux_capture "read-screen" "$(cg_cap "$deadline" 10)" read-screen --workspace "$ws" --surface "$surface" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$CG_OUT"
}

# 停止時に出す「最後の画面」用: 空行・空白だけの行を除いた末尾 N 行（v5.4。実機の画面は下が空行ばかりで、確認文が抜粋に入らなかった）。複製が cmux-send.sh の screen_tail にある
#   usage: cg_screen_tail <画面> [N=15]
cg_screen_tail() {
  printf '%s\n' "$1" | awk 'NF' | tail -n "${2:-15}"
}

CG_TRUST_RE='trust this folder|trust the files in this folder|Do you trust|Yes, I trust|trust the contents of this directory|Quick safety check'
# 空プロンプトの周辺に出る「入力待ち」の証拠（フッターのヘルプ・罫線）。これ単体では ready の証拠にしない
CG_FOOTER_RE='\? for shortcuts|shift\+tab to cycle|(─|━){10,}'
# Codex の空の入力欄に薄字で出るプレースホルダ（Codex 0.159.0 の実機標本）と、Codex のアイドル状態行
CG_PLACEHOLDER='Ask Codex to do anything'
CG_CODEX_IDLE_RE='Context [0-9]+% left'
# 処理中の表示
CG_BUSY_RE='esc to interrupt|ctrl\+c to interrupt|Working|Thinking'

# 画面の状態を1語で返す（見えている画面の末尾20行（末尾の空行を除く）だけを見る）
#   trust   : 信頼確認らしき画面
#   draft   : 入力欄に文字がある（本人の入力途中・未送信の依頼文・選択画面の行・サジェスト候補を含む）
#   busy    : 入力欄は空で、処理中の表示がある（受理済みの証拠にはなるが、新たな依頼はまだ送らない）
#   ready   : 入力欄が空で、処理中でなく、フッター/罫線の証拠がある
#   unknown : 空画面・入力欄を特定できない画面・どれにも当たらない画面（成功の証拠にしない）
# 入力欄 = 末尾20行のうち一番下にある、行頭ちょうどの `❯` `›`（`>` やインデント付きは入力欄としない）。フッターの文言だけでは ready にしない。
cg_screen_state() {
  local screen="$1" win prompt
  if [ -z "$(printf '%s' "$screen" | tr -d '[:space:]')" ]; then echo unknown; return 0; fi
  if grep -qiE "$CG_TRUST_RE" <<<"$screen"; then echo trust; return 0; fi
  # 末尾20行（空行は保つ）。末尾の空行は落とす
  win="$(printf '%s\n' "$screen" | awk '{l[NR]=$0} END{n=NR; while(n>0 && l[n] ~ /^[[:space:]]*$/) n--; for(i=(n>20?n-19:1);i<=n;i++)print l[i]}')"
  prompt="$(printf '%s\n' "$win" | awk -v ph="$CG_PLACEHOLDER" '
    function isrule(s) { return s ~ /^[[:space:]]*(─|━){10,}/ }
    function blank(s) { return s ~ /^[[:space:]]*$/ }
    { l[NR] = $0 }
    END {
      m = 0
      for (i = NR; i >= 1; i--) if (l[i] ~ /^(❯|›)([[:space:]]|$)/) { m = i; break }
      if (m == 0) { print "NOPROMPT"; exit }
      c = l[m]; sub(/^(❯|›)/, "", c); gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
      below = (m < NR) ? l[m+1] : ""
      above = (m > 1) ? l[m-1] : ""
      if (c != "") {
        if (c == ph) { r = "PLACEHOLDER" } else { print "TEXT"; exit }
      } else r = "EMPTY"
      # 入力欄の直下/直上に空行でも罫線でもない行が続く = 複数行入力の続き・境界不明
      if (m < NR && !blank(below) && !isrule(below)) { print "BELOWADJ"; exit }
      if (m > 1 && !blank(above) && !isrule(above)) { print "ABOVEADJ"; exit }
      print r
    }')"
  case "$prompt" in
    TEXT|BELOWADJ) echo draft ;;
    ABOVEADJ|NOPROMPT) echo unknown ;;
    PLACEHOLDER)
      # プレースホルダ文言と同じ字面の「本人の入力」とは字面だけでは区別できない。Codex の状態行（`Context N% left`）が
      # 見えるときだけ空扱い（処理中なら busy、`? for shortcuts` があれば ready）。揃わなければ draft（止まる）
      if grep -qE "$CG_CODEX_IDLE_RE" <<<"$win"; then
        if grep -qE "$CG_BUSY_RE" <<<"$win"; then echo busy
        elif grep -qE '\? for shortcuts' <<<"$win"; then echo ready
        else echo draft; fi
      else echo draft; fi ;;
    EMPTY)
      if grep -qE "$CG_BUSY_RE" <<<"$win"; then echo busy
      elif grep -qE "$CG_FOOTER_RE" <<<"$win"; then echo ready
      else echo unknown; fi ;;
    *) echo unknown ;;
  esac
}


# --- エージェントの ready 待ち ---
# cg_wait_agent_ready <ws> <surface> [待ち秒=${CG_AGENT_READY_WAIT:-40}]
#   0=ready を確認 / 3=信頼確認らしき画面（承認せず止まる） / 4=deadline 内に確認できず（空・読めない・picker・起動中・キュー待ちを含む）
#   4 は「失敗」ではなく「起動未確認」。起動行が受付（queued）されたまま、後から動く可能性がある。呼び出し側は cg_report_stop ... pending で報告する
cg_wait_agent_ready() {
  local ws="$1" surface="$2" secs="${3:-${CG_AGENT_READY_WAIT:-40}}" deadline screen st=unknown
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    screen="$(cg_read_screen "$ws" "$surface" "$deadline" 2>/dev/null || true)"
    st="$(cg_screen_state "$screen")"
    case "$st" in
      ready) return 0 ;;
      trust)
        cg_log "Error: ${ws} ${surface} に信頼確認らしき画面が出ています。自動承認せず止まります。対象パスと画面を確認してください:"
        cg_screen_tail "$screen" 15 | sed 's/^/  /' >&2
        return 3 ;;
    esac
    sleep 2
  done
  cg_log "Error: ${ws} ${surface} の ready を ${secs}秒以内に確認できませんでした（空画面・起動中・選択画面・不明のいずれか。起動行が受付だけされ、後から動く可能性もあります）。最後の画面:"
  cg_screen_tail "${screen:-<取得できず>}" 15 | sed 's/^/  /' >&2
  return 4
}

# --- 送信 ---
# 受付と見なす応答は、既知の2つの原文だけ（2026-10-15 の実機応答）。判定は **stdout だけ**で行い、終了コード 0 のときだけ受付にしうる。
# 「拒否語が無い」ことは受付の証拠にしない。未知の行を削って OK を拾うこともしない（stdout が複数行・注意行つきなら未知）。
#   OK     : `OK surface:N workspace:M`
#   queued : `OK surface:N workspace:M queued (terminal starting; input will be sent when its PTY is ready)`
# stderr は判定に混ぜない（cmux 0.65.1 の注意行など）。cg_cmux_capture がログへ残す。
# send-key の応答も同じ2形式を既知とする（send-key の実機応答の原文は未確認の想定。違えば受付不明で止まる＝安全側）
CG_RESP_OK_RE='^OK surface:[^[:space:]]+ workspace:[^[:space:]]+$'
CG_RESP_QUEUED_RE='^OK surface:[^[:space:]]+ workspace:[^[:space:]]+ queued \(terminal starting; input will be sent when its PTY is ready\)$'
# 明示的な拒否と読める文面（行頭の Error: か、既知の拒否の言い回し）。Warning 行の語（invalid 等）単体では拒否にしない
CG_RESP_REJECT_RE='(^|[[:space:]])Error:|queue full|surface not found|workspace not found|surface unavailable|no such surface'

# stdout の分類: ok / queued / unknown（空・未知・複数行・注意行つき）。stdout だけを見る
cg_classify_resp() {
  local out="$1"
  out="${out%"${out##*[![:space:]]}"}"   # 末尾の空白・改行を除く
  if [ -z "$out" ]; then echo unknown; return 0; fi
  if [[ "$out" =~ $CG_RESP_QUEUED_RE ]]; then echo queued; return 0; fi
  if [[ "$out" =~ $CG_RESP_OK_RE ]]; then echo ok; return 0; fi
  echo unknown
}

# 明示的な拒否か（stdout か stderr に、拒否と読める文面がある）。 0=明示的な拒否
cg_is_explicit_reject() {
  printf '%s\n%s' "$1" "$2" | grep -qiE "$CG_RESP_REJECT_RE"
}

# テキストを送り、Enter を1回だけ送る。どの失敗でも再送・追送しない。
# cg_cmux_send <ws> <surface> <text>
#   0=受付（終了コード0 かつ stdout が ok / queued）
#   1=明示的な拒否（stdout/stderr に拒否と読める文面があり、受付の形ではない）。終了コードが非0でも、拒否と確認できたときだけ
#   2=受付不明（それ以外の失敗: timeout・終了コード非0で拒否と確認できない・stdout が空/未知/注意行つき）。**非0でも本文は受付済みの可能性がある**
#      （cmux 内部の timeout・切断は外側の alarm の rc142 とは限らない）。Enter には進まない
#   3=本文は受付済みだが Enter が未達・不明（失敗・timeout・空・未知。stderr の記録不能で send-key を呼べなかった場合を含む）。入力欄に本文が残っている可能性あり
#   4=未送信の停止（stderr の記録用の一時ファイルを作れず、send を呼ばずに止まった）。受付不明ではない（cmux を呼んでいない）
cg_cmux_send() {
  local ws="$1" surface="$2" text="$3" rc cls
  rc=0; cg_cmux_capture "send" 15 send --workspace "$ws" --surface "$surface" -- "$text" || rc=$?
  if [ "$CG_CAPTURE_UNSENT" = 1 ]; then
    cg_log "Error: 未送信で停止しました（send を呼んでいません・受付不明ではありません）（${ws} ${surface}）"
    return 4
  fi
  cls="$(cg_classify_resp "$CG_OUT")"
  if [ "$rc" -eq 0 ] && { [ "$cls" = ok ] || [ "$cls" = queued ]; }; then
    [ "$cls" = queued ] && cg_log "send は受付（キュー: 端末の起動待ち）でした: ${surface}。受付であって、起動成功ではありません"
  elif cg_is_explicit_reject "$CG_OUT" "$CG_ERR"; then
    cg_log "Error: cmux send は明示的に拒否されました（rc=${rc} ${ws} ${surface}）: ${CG_OUT:-}${CG_ERR:+ / stderr: ${CG_ERR}}"
    return 1
  else
    cg_log "Error: cmux send の結果が確認できません（受付不明・rc=${rc}・stdout=${CG_OUT:-<空>}）。本文は受付済みの可能性があります。Enter には進まず、再送もしません（${ws} ${surface}）"
    return 2
  fi
  sleep 0.3
  rc=0; cg_cmux_capture "send-key" 15 send-key --workspace "$ws" --surface "$surface" enter || rc=$?
  if [ "$CG_CAPTURE_UNSENT" = 1 ]; then
    cg_log "Error: send-key enter は未送信です（呼んでいません）。本文は受付済みの可能性があります（追送しません）（${ws} ${surface}）"
    return 3
  fi
  cls="$(cg_classify_resp "$CG_OUT")"
  if [ "$rc" -eq 0 ] && { [ "$cls" = ok ] || [ "$cls" = queued ]; }; then
    return 0
  fi
  cg_log "Error: send-key enter の結果が確認できません（rc=${rc}・stdout=${CG_OUT:-<空>}）。本文は受付済みの可能性があります（追送しません）（${ws} ${surface}）"
  return 3
}

# 送る前に surface が workspace に属することを確かめる。 0=属する / 1=属さない・不明（送らない）
cg_check_target() {
  local ws="$1" surface="$2" rc=0
  cg_surface_in_ws "$ws" "$surface" || rc=$?
  if [ "$rc" -eq 1 ]; then
    cg_log "Error: surface「${surface}」は workspace「${ws}」に属していません（引数の取り違えの可能性）。送信しません"
    return 1
  elif [ "$rc" -ne 0 ]; then
    cg_log "Error: 一覧を取得できず、surface「${surface}」が workspace「${ws}」に属するか確認できません。送信しません"
    return 1
  fi
  return 0
}

# シェルへの1行（cd … && claude 等）: 新規の未使用 surface への初回起動に使う。端末が未起動（tty なし）でも送る（send が起動を促す）。
# 応答が queued でも「受付」として成功にする（起動成功ではない）。受理の確認は、後段の cg_wait_agent_ready が行う
# cg_send_shell <ws> <surface> <text>   0=受付 / 1=明示的な拒否・宛先が workspace に属さない（送っていない or 拒否と確認できた） / 2=受付不明 / 3=本文は受付済み・Enter 未達 / 4=未送信の停止（cg_cmux_send と同じ）
cg_send_shell() {
  local ws="$1" surface="$2" text="$3"
  cg_check_target "$ws" "$surface" || return 1
  cg_cmux_send "$ws" "$surface" "$text"
}

# エージェントへの依頼文: 先に ready を確認する（待つ）→送信→Enter（1回だけ・追送しない）→画面で受理を確認
# 長文（1000バイト超）・複数行は、依頼文ファイルに書き「読んで」と送る。ファイルが非空であることを送る前に確認する
# cg_send_agent <ws> <surface> <text>
#   0=送信済みを確認 / 1=明示的な拒否・ファイル作成失敗・宛先が workspace に属さない / 3=送る前に ready でない（信頼確認画面を含む） / 5=送信後に受理を確認できず
#   4=未送信の停止（stderr の記録用の一時ファイルを作れず、send を呼ばなかった。受付不明ではない）
#   6=受付不明（send の timeout・未知の応答・Enter 未達。本文は受付済みの可能性あり。追送しない）
cg_send_agent() {
  local ws="$1" surface="$2" text="$3" send_text="$3" bytes tmpfile deadline screen st rc
  cg_check_target "$ws" "$surface" || return 1
  rc=0; cg_wait_agent_ready "$ws" "$surface" "${CG_SEND_READY_WAIT:-15}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cg_log "Error: 送る前に ${ws} ${surface} が ready と確認できないため送信しません（rc=${rc}）"
    return 3
  fi
  bytes="$(printf '%s' "$text" | wc -c | tr -d ' ')"
  if [ "$bytes" -gt 1000 ] || [[ "$text" == *$'\n'* ]]; then
    tmpfile="/tmp/cmux-guard-send-$$-$(date +%s)-${RANDOM}.md"
    printf '%s' "$text" > "$tmpfile" 2>/dev/null
    if [ ! -s "$tmpfile" ]; then
      cg_log "Error: 依頼文ファイル ${tmpfile} を作成できません。送信しません"
      return 1
    fi
    send_text="${tmpfile} を読んで、その内容に従ってください。"
  fi
  rc=0; cg_cmux_send "$ws" "$surface" "$send_text" || rc=$?
  if [ "$rc" -eq 1 ]; then return 1; elif [ "$rc" -eq 4 ]; then return 4; elif [ "$rc" -ne 0 ]; then return 6; fi
  # 受理の証拠 = 入力欄が空になっていること（ready または busy）。入力欄に文字が残る(draft)・信頼確認・空/不明な画面は受理の証拠にしない。
  # 末尾に送信文が「見えない」ことは証拠にしない（未送信の本文が下のステータス行の上に残る画面を取り違えないため）
  deadline=$(( $(date +%s) + 8 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
    screen="$(cg_read_screen "$ws" "$surface" "$deadline" 2>/dev/null || true)"
    st="$(cg_screen_state "$screen")"
    case "$st" in
      ready|busy) return 0 ;;
      trust) break ;;
    esac
  done
  cg_log "Error: 送信後の受理を確認できません（入力欄に残っているか、画面が空・不明・信頼確認のいずれか）。Enter の追送はしません。最後の画面:"
  cg_screen_tail "${screen:-<取得できず>}" 10 | sed 's/^/  /' >&2
  return 5
}
