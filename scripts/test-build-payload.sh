#!/usr/bin/env bash
# build-payload.sh 의 변환을 샘플 입력으로 검증한다. 네트워크 없음.
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

cat > "$tmp/ok.json" <<'EOF'
{"summary":"설정 파일 경로만 바꿈.","verdict":"ok","findings":[]}
EOF
cat > "$tmp/two.json" <<'EOF'
{"summary":"결제 어댑터 추가.","verdict":"check","findings":[
 {"path":"src/A.kt","line":12,"severity":"bug","body":"null 이면 NPE."},
 {"path":"docs/x.md","line":3,"severity":"rule","body":"열린 것 표에 기록 안 됨."}]}
EOF
cat > "$tmp/check-empty.json" <<'EOF'
{"summary":"큰 변경.","verdict":"check","findings":[]}
EOF

# 1. 지적 없음 → APPROVE, 본문 머리, 인라인 없음
out=$(bash scripts/build-payload.sh "$tmp/ok.json" abc123 false)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "1 event"
[ "$(jq -r .commit_id <<<"$out")" = "abc123" ] || fail "1 sha"
jq -e '.body | startswith("문제 없음. 승인합니다.")' <<<"$out" >/dev/null || fail "1 head"
jq -e '.body | contains("설정 파일 경로만 바꿈.")' <<<"$out" >/dev/null || fail "1 summary"
[ "$(jq '.comments | length' <<<"$out")" = "0" ] || fail "1 comments"

# 2. 지적 2건 → COMMENT, 건수 집계, 인라인 2개에 접두
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false)
[ "$(jq -r .event <<<"$out")" = "COMMENT" ] || fail "2 event"
jq -e '.body | startswith("확인 권장 2건 (버그 1 · 규칙 위반 1 · 참고 0)")' <<<"$out" >/dev/null || fail "2 head"
[ "$(jq '.comments | length' <<<"$out")" = "2" ] || fail "2 comments"
[ "$(jq -r '.comments[0].body' <<<"$out")" = "[버그] null 이면 NPE." ] || fail "2 prefix"
[ "$(jq -r '.comments[0].side' <<<"$out")" = "RIGHT" ] || fail "2 side"
[ "$(jq -r '.comments[1].line' <<<"$out")" = "3" ] || fail "2 line"

# 3. --no-inline → 인라인 비우고 본문 목록으로
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false --no-inline)
[ "$(jq '.comments | length' <<<"$out")" = "0" ] || fail "3 comments"
jq -e '.body | contains("- `src/A.kt:12` [버그] null 이면 NPE.")' <<<"$out" >/dev/null || fail "3 list"
jq -e '.body | contains("- `docs/x.md:3` [규칙 위반] 열린 것 표에 기록 안 됨.")' <<<"$out" >/dev/null || fail "3 list2"

# 4. 대형 PR: bug 가 없으면 승인하되, 핵심 경로만 봤으니 사람이 확인하라고 머리에 적는다. 끝 문구는 중복하지 않는다
out=$(bash scripts/build-payload.sh "$tmp/ok.json" abc123 true)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "4 event"
jq -e '.body | startswith("승인합니다. 변경이 커서 핵심 경로만 봤습니다. 머지 전에 사람이 확인하세요.")' <<<"$out" >/dev/null || fail "4 head"
jq -e '.body | contains("설정 파일 경로만 바꿈.")' <<<"$out" >/dev/null || fail "4 summary"
jq -e '.body | endswith("변경이 커서 핵심 경로 위주로 봤습니다.")' <<<"$out" >/dev/null && fail "4 duplicate big note"
# 4b. 대형 PR 에 rule/note 만 → 역시 APPROVE, 건수는 머리에, 인라인은 그대로
cat > "$tmp/soft.json" <<'EOF'
{"summary":"설정 정리.","verdict":"check","findings":[
 {"path":"src/A.kt","line":12,"severity":"rule","body":"네이밍 규칙과 다름."},
 {"path":"src/B.kt","line":3,"severity":"note","body":"확인해보세요."}]}
EOF
out=$(bash scripts/build-payload.sh "$tmp/soft.json" abc123 true)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "4b event"
jq -e '.body | startswith("승인합니다. 변경이 커서 핵심 경로만 봤습니다. 머지 전에 사람이 확인하세요. 참고 2건 (규칙 위반 1 · 참고 1)")' <<<"$out" >/dev/null || fail "4b head"
[ "$(jq '.comments | length' <<<"$out")" = "2" ] || fail "4b comments"
# 4c. 대형 PR 에 bug → 기존 "확인 권장" 머리 + 끝에 대형 문구
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 true)
[ "$(jq -r .event <<<"$out")" = "COMMENT" ] || fail "4c event"
jq -e '.body | startswith("확인 권장 2건")' <<<"$out" >/dev/null || fail "4c head"
jq -e '.body | endswith("변경이 커서 핵심 경로 위주로 봤습니다.")' <<<"$out" >/dev/null || fail "4c big note"

# 5. findings 없는데 verdict=check(리뷰 못 함) → COMMENT (승인하지 않는다)
out=$(bash scripts/build-payload.sh "$tmp/check-empty.json" abc123 false)
[ "$(jq -r .event <<<"$out")" = "COMMENT" ] || fail "5 event"
jq -e '.body | startswith("확인 권장")' <<<"$out" >/dev/null || fail "5 head"

# 6. bug 가 없는 지적(rule·note)만 있으면 → 인라인은 달되 APPROVE ("확실한 오류 아니면 승인")
cat > "$tmp/soft.json" <<'EOF'
{"summary":"설정 정리.","verdict":"check","findings":[
 {"path":"src/A.kt","line":12,"severity":"rule","body":"네이밍 규칙과 다름."},
 {"path":"src/B.kt","line":3,"severity":"note","body":"확인해보세요."}]}
EOF
out=$(bash scripts/build-payload.sh "$tmp/soft.json" abc123 false)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "6 event"
jq -e '.body | startswith("승인합니다. 참고 2건 (규칙 위반 1 · 참고 1)")' <<<"$out" >/dev/null || fail "6 head"
[ "$(jq '.comments | length' <<<"$out")" = "2" ] || fail "6 comments"

# 7. bug 가 하나라도 있으면 → COMMENT
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false)
[ "$(jq -r .event <<<"$out")" = "COMMENT" ] || fail "7 event"

# 8. 승격 PR(--promotion): 코드 리뷰가 아니라 포함 내역 요약. bug 가 없으면 승인하되 사람이 확인하라고 머리에 적는다
out=$(bash scripts/build-payload.sh "$tmp/ok.json" abc123 false --promotion)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "8 event"
jq -e '.body | startswith("승인합니다. 승격 PR 이라 포함 내역만 요약했습니다. 머지 전에 사람이 확인하세요.")' <<<"$out" >/dev/null || fail "8 head"
jq -e '.body | contains("설정 파일 경로만 바꿈.")' <<<"$out" >/dev/null || fail "8 summary"
# 8b. 승격 PR 은 줄 수가 커도 대형 문구를 붙이지 않는다(승격 프롬프트가 따로 범위를 정한다)
out=$(bash scripts/build-payload.sh "$tmp/soft.json" abc123 true --promotion)
[ "$(jq -r .event <<<"$out")" = "APPROVE" ] || fail "8b event"
jq -e '.body | startswith("승인합니다. 승격 PR 이라 포함 내역만 요약했습니다. 머지 전에 사람이 확인하세요. 참고 2건 (규칙 위반 1 · 참고 1)")' <<<"$out" >/dev/null || fail "8b head"
jq -e '.body | contains("변경이 커서")' <<<"$out" >/dev/null && fail "8b big note on promotion"
[ "$(jq '.comments | length' <<<"$out")" = "2" ] || fail "8b comments"
# 8c. 승격 PR 에 bug → 기존 "확인 권장" 머리, 끝에 승격 문구
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false --promotion)
[ "$(jq -r .event <<<"$out")" = "COMMENT" ] || fail "8c event"
jq -e '.body | startswith("확인 권장 2건")' <<<"$out" >/dev/null || fail "8c head"
jq -e '.body | endswith("승격 PR 이라 포함 내역만 요약했습니다.")' <<<"$out" >/dev/null || fail "8c note"
# 8d. --promotion 과 --no-inline 은 같이 쓸 수 있다(422 재시도 경로), 순서 무관
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false --promotion --no-inline)
[ "$(jq '.comments | length' <<<"$out")" = "0" ] || fail "8d comments"
jq -e '.body | contains("- `src/A.kt:12` [버그] null 이면 NPE.")' <<<"$out" >/dev/null || fail "8d list"
out=$(bash scripts/build-payload.sh "$tmp/two.json" abc123 false --no-inline --promotion)
[ "$(jq '.comments | length' <<<"$out")" = "0" ] || fail "8d order"

echo "PASS"
