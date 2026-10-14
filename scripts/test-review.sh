#!/usr/bin/env bash
# review.sh / review-one.sh 의 흐름을 가짜 gh·claude 로 검증한다. 네트워크·실제 Claude 없음.
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; echo "--- fake calls ---"; cat "${FAKE_LOG:-/dev/null}" 2>/dev/null; exit 1; }
mkdir -p "$tmp/bin"

# 가짜 gh: 호출을 기록하고 시나리오 파일대로 응답한다
write_fake_gh() {
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "search prs") cat "$FAKE_SEARCH" ;;
  "auth setup-git") ;;
  "repo clone")
    # 자기 자신을 origin 으로 둬서 git fetch origin develop 이 성공한다. FAKE_NO_ORIGIN=1 이면 fetch 가 실패한다
    mkdir -p "$4" && (cd "$4" && git init -q && git commit -q --allow-empty -m init && git branch -q -M develop \
      && git checkout -q -b pr && git commit -q --allow-empty -m pr \
      && { [ "${FAKE_NO_ORIGIN:-}" = "1" ] || git remote add origin "$4"; }) ;;
  "pr checkout") ;;
  "pr view") echo "{\"baseRefName\":\"develop\",\"headRefOid\":\"deadbeef\",\"author\":{\"login\":\"${FAKE_AUTHOR:-other}\"}}" ;;
  "api "*)
    case "$*" in *"-X POST"*) ;; *) echo "${FAKE_EXISTING_REVIEWS:-0}"; exit 0 ;; esac   # GET: 이 head 에 내 리뷰 수
    cp "$6" "$FAKE_PAYLOAD" 2>/dev/null
    if [ "${FAKE_API_422_FIRST:-}" = "1" ] && [ "$(grep -c '^gh api -X POST' "$FAKE_LOG")" -eq 1 ]; then
      echo "gh: Unprocessable Entity (HTTP 422)" >&2; exit 1
    fi
    echo '{}' ;;
  *) ;;
esac
EOF
chmod +x "$tmp/bin/gh"
}
# 가짜 claude: 실패 주입 또는 시나리오 출력. FAKE_CLAUDE_TEXT_FIRST=1 이면 첫 호출만 구조화 출력 없음
write_fake_claude() {
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$FAKE_LOG"
echo "claude-env GH_TOKEN=${GH_TOKEN:-unset} GH_PAT=${GH_PAT:-unset}" >> "$FAKE_LOG"
cat >/dev/null   # 실제 claude -p 는 stdin 이 TTY 가 아니면 끝까지 읽는다. 루프의 남은 대상을 삼키는 버그 재현용
[ "${FAKE_CLAUDE_FAIL:-}" = "1" ] && exit 1
if [ "${FAKE_CLAUDE_TEXT_FIRST:-}" = "1" ] && [ "$(grep -c '^claude -p' "$FAKE_LOG")" -eq 1 ]; then
  echo '{"result":"텍스트만"}'; exit 0
fi
cat "$FAKE_CLAUDE_OUT"
EOF
chmod +x "$tmp/bin/claude"
}
write_fake_gh; write_fake_claude
export PATH="$tmp/bin:$PATH"
export FAKE_LOG="$tmp/calls.log" FAKE_SEARCH="$tmp/search.json" FAKE_CLAUDE_OUT="$tmp/claude.json" FAKE_PAYLOAD="$tmp/payload.json"
export ORG=acme ME=someone
unset GH_PAT FAKE_API_422_FIRST FAKE_CLAUDE_FAIL FAKE_CLAUDE_TEXT_FIRST DRY_RUN FORCE_REPO FORCE_PR

echo '{"structured_output":{"summary":"요약","verdict":"ok","findings":[]}}' > "$FAKE_CLAUDE_OUT"

# 1. 대상 0건 → clone 없이 exit 0, 출력은 "targets: 0" 만
echo '[]' > "$FAKE_SEARCH"; : > "$FAKE_LOG"
out=$(bash scripts/review.sh 2>&1) || fail "1 exit"
[ "$out" = "targets: 0" ] || fail "1 output: $out"
grep -q "repo clone" "$FAKE_LOG" && fail "1 cloned"

# 2. 대상 1건 → clone·claude·api 호출, exit 0, 출력에 레포명 없음(마스킹 줄 제외)
echo '[{"number":7,"repository":{"nameWithOwner":"acme/secret-repo"}}]' > "$FAKE_SEARCH"; : > "$FAKE_LOG"
out=$(bash scripts/review.sh 2>&1) || fail "2 exit"
grep -q "repo clone acme/secret-repo" "$FAKE_LOG" || fail "2 clone"
grep -q "claude -p" "$FAKE_LOG" || fail "2 claude"
grep -q "api -X POST repos/acme/secret-repo/pulls/7/reviews" "$FAKE_LOG" || fail "2 api"
grep -v "::add-mask::" <<<"$out" | grep -q "secret-repo" && fail "2 leaked repo name: $out"
grep -q "::add-mask::acme/secret-repo" <<<"$out" || fail "2 mask"

# 3. claude 실패 → 그 PR 건너뜀, api 호출 없음, exit 1
: > "$FAKE_LOG"
out=$(FAKE_CLAUDE_FAIL=1 bash scripts/review.sh 2>&1) && fail "3 exit should be 1"
grep -q "api -X POST" "$FAKE_LOG" && fail "3 api called"
grep -v "::add-mask::" <<<"$out" | grep -q "secret-repo" && fail "3 leaked: $out"

# 4. 2건 중 첫 건이 구조화 출력 없음 → 두 번째만 제출, exit 1
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}},{"number":9,"repository":{"nameWithOwner":"acme/b"}}]' > "$FAKE_SEARCH"
: > "$FAKE_LOG"
FAKE_CLAUDE_TEXT_FIRST=1 bash scripts/review.sh >/dev/null 2>&1 && fail "4 exit should be 1"
[ "$(grep -c 'api -X POST' "$FAKE_LOG")" = "1" ] || fail "4 one submit"
grep -q "pulls/9/reviews" "$FAKE_LOG" || fail "4 second submitted"

# 5. 첫 제출 422 → --no-inline 으로 재제출(두 번째 api 호출), exit 0
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}}]' > "$FAKE_SEARCH"; : > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약","verdict":"check","findings":[{"path":"x","line":1,"severity":"bug","body":"b"}]}}' > "$FAKE_CLAUDE_OUT"
FAKE_API_422_FIRST=1 bash scripts/review.sh >/dev/null 2>&1 || fail "5 exit"
[ "$(grep -c 'api -X POST' "$FAKE_LOG")" = "2" ] || fail "5 retry"

# 6. DRY_RUN → api 호출 없음, exit 0
: > "$FAKE_LOG"
DRY_RUN=1 bash scripts/review.sh >/dev/null 2>&1 || fail "6 exit"
grep -q "api -X POST" "$FAKE_LOG" && fail "6 api called in dry run"

# 7. FORCE_REPO/FORCE_PR → 검색 없이 그 PR
: > "$FAKE_LOG"
DRY_RUN=1 FORCE_REPO=acme/z FORCE_PR=42 bash scripts/review.sh >/dev/null 2>&1 || fail "7 exit"
grep -q "search prs" "$FAKE_LOG" && fail "7 searched"
grep -q "repo clone acme/z" "$FAKE_LOG" || fail "7 forced clone"

# 8. 내가 연 PR(author == ME) 에 verdict ok → GitHub 은 본인 승인을 거부하므로 COMMENT 로 제출
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}}]' > "$FAKE_SEARCH"; : > "$FAKE_LOG"; rm -f "$FAKE_PAYLOAD"
echo '{"structured_output":{"summary":"요약","verdict":"ok","findings":[]}}' > "$FAKE_CLAUDE_OUT"
FAKE_AUTHOR=someone bash scripts/review.sh >/dev/null 2>&1 || fail "8 exit"
[ "$(jq -r .event "$FAKE_PAYLOAD")" = "COMMENT" ] || fail "8 event: $(jq -r .event "$FAKE_PAYLOAD")"
jq -e '.body | startswith("문제 없음. 본인 PR 이라 승인 대신 코멘트로 남긴다.")' "$FAKE_PAYLOAD" >/dev/null || fail "8 head"

# 9. 남의 PR 에 verdict ok → APPROVE 그대로
: > "$FAKE_LOG"; rm -f "$FAKE_PAYLOAD"
FAKE_AUTHOR=other bash scripts/review.sh >/dev/null 2>&1 || fail "9 exit"
[ "$(jq -r .event "$FAKE_PAYLOAD")" = "APPROVE" ] || fail "9 event"

# 10. workflow_dispatch 입력은 env 가 아니라 이벤트 파일에서 읽는다(env 는 러너가 로그에 찍는다)
: > "$FAKE_LOG"
echo '{"inputs":{"repo":"acme/evt","pr":"5","dry_run":"true"}}' > "$tmp/event.json"
GITHUB_EVENT_PATH="$tmp/event.json" bash scripts/review.sh >/dev/null 2>&1 || fail "10 exit"
grep -q "search prs" "$FAKE_LOG" && fail "10 searched"
grep -q "repo clone acme/evt" "$FAKE_LOG" || fail "10 event clone"
grep -q "api -X POST" "$FAKE_LOG" && fail "10 dry_run input ignored"

# 11. 이벤트 파일에 inputs 가 없으면(schedule) 검색으로 간다
: > "$FAKE_LOG"; echo '{"schedule":"*/5 * * * *"}' > "$tmp/event.json"; echo '[]' > "$FAKE_SEARCH"
GITHUB_EVENT_PATH="$tmp/event.json" bash scripts/review.sh >/dev/null 2>&1 || fail "11 exit"
grep -q "search prs" "$FAKE_LOG" || fail "11 no search"

# 12. Claude 에는 GitHub 토큰을 넘기지 않고, 대상 레포의 settings 훅·.mcp.json 을 읽지 않는다
#     (리뷰 대상 레포가 훅으로 env 를 빼내는 경로 차단)
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}}]' > "$FAKE_SEARCH"; : > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약","verdict":"ok","findings":[]}}' > "$FAKE_CLAUDE_OUT"
GH_PAT=dummy-pat bash scripts/review.sh >/dev/null 2>&1 || fail "12 exit"
grep -q "^claude-env GH_TOKEN=unset GH_PAT=unset$" "$FAKE_LOG" || fail "12 github token reached claude"
grep -q -- "--setting-sources user" "$FAKE_LOG" || fail "12 project settings not excluded"
grep -q -- "--strict-mcp-config" "$FAKE_LOG" || fail "12 project mcp not excluded"
grep -q -- "--disallowedTools Read(//proc/\*\*),Bash(git diff --no-index\*)" "$FAKE_LOG" || fail "12 /proc and --no-index not denied"

# 13. 리뷰 JSON 에 토큰(값 또는 접두)이 섞이면 제출하지 않는다 — 프롬프트 인젝션으로 토큰이 본문에 실리는 경로 차단
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}}]' > "$FAKE_SEARCH"
: > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약 ghp_abcdef0123456789","verdict":"ok","findings":[]}}' > "$FAKE_CLAUDE_OUT"
out=$(bash scripts/review.sh 2>&1) && fail "13a exit should be 1"
grep -q "api -X POST" "$FAKE_LOG" && fail "13a submitted a review containing a token prefix"
grep -q "review rejected" <<<"$out" || fail "13a message: $out"
: > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약","verdict":"check","findings":[{"path":"x","line":1,"severity":"note","body":"dummy-pat 가 보임"}]}}' > "$FAKE_CLAUDE_OUT"
GH_PAT=dummy-pat bash scripts/review.sh >/dev/null 2>&1 && fail "13b exit should be 1"
grep -q "api -X POST" "$FAKE_LOG" && fail "13b submitted a review containing the PAT value"
: > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약","verdict":"check","findings":[{"path":"x","line":1,"severity":"note","body":"tok-value 가 보임"}]}}' > "$FAKE_CLAUDE_OUT"
CLAUDE_CODE_OAUTH_TOKEN=tok-value bash scripts/review.sh >/dev/null 2>&1 && fail "13c exit should be 1"
grep -q "api -X POST" "$FAKE_LOG" && fail "13c submitted a review containing the oauth token"

# 14. 이 head 에 내 리뷰가 이미 있으면(검색 색인 지연·요청 미해소) 다시 리뷰하지 않는다
: > "$FAKE_LOG"
echo '{"structured_output":{"summary":"요약","verdict":"ok","findings":[]}}' > "$FAKE_CLAUDE_OUT"
out=$(FAKE_EXISTING_REVIEWS=1 bash scripts/review.sh 2>&1) || fail "14 exit"
grep -q "claude -p" "$FAKE_LOG" && fail "14 claude ran for an already reviewed head"
grep -q "already reviewed" <<<"$out" || fail "14 message: $out"

# 15. 수동 실행 입력이 반쯤이거나 번호가 아니면 실패로 끝낸다(조용히 검색으로 빠지지 않는다)
: > "$FAKE_LOG"; echo '[]' > "$FAKE_SEARCH"
echo '{"inputs":{"repo":"acme/evt","pr":""}}' > "$tmp/event.json"
out=$(GITHUB_EVENT_PATH="$tmp/event.json" bash scripts/review.sh 2>&1) && fail "15a exit should be 1"
grep -q "search prs" "$FAKE_LOG" && fail "15a fell through to search"
grep -q "bad inputs" <<<"$out" || fail "15a message: $out"
echo '{"inputs":{"repo":"acme/evt","pr":"#322"}}' > "$tmp/event.json"
GITHUB_EVENT_PATH="$tmp/event.json" bash scripts/review.sh >/dev/null 2>&1 && fail "15b exit should be 1"

# 16. base 를 못 가져오면(diff 불가) 리뷰하지 않는다 — diff 없이 ok 를 내면 승인이 나가기 때문
: > "$FAKE_LOG"
echo '[{"number":7,"repository":{"nameWithOwner":"acme/a"}}]' > "$FAKE_SEARCH"
out=$(FAKE_NO_ORIGIN=1 bash scripts/review.sh 2>&1) && fail "16 exit should be 1"
grep -q "claude -p" "$FAKE_LOG" && fail "16 claude ran without a diff"
grep -q "diff failed" <<<"$out" || fail "16 message: $out"

rm -f work-last-payload.json
echo "PASS"
