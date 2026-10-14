#!/usr/bin/env bash
# PR 하나: clone → claude -p (구조화 출력) → payload → 리뷰 제출. 출력은 고정 문구만.
set -u
set +x
repo="$1"; number="$2"; work="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dir="$work/repo"
rm -rf "$dir"

gh repo clone "$repo" "$dir" -- -q >/dev/null 2>&1 || { echo "clone failed"; exit 1; }
cd "$dir" || exit 1
gh pr checkout "$number" >/dev/null 2>&1 || { echo "checkout failed"; exit 1; }
gh pr view "$number" --json baseRefName,headRefOid,author > "$work/pr.json" 2>/dev/null || { echo "view failed"; exit 1; }
base=$(jq -r .baseRefName "$work/pr.json")
head_sha=$(jq -r .headRefOid "$work/pr.json")
author=$(jq -r '.author.login // ""' "$work/pr.json")

# 이 head 에 내 리뷰가 이미 있으면 끝. 검색 색인 지연이나 요청 미해소로 같은 PR 이 다시 와도 중복 리뷰를 막는다.
# 수동 지정(SKIP_GUARD)은 "지금 다시 리뷰" 라는 뜻이므로 가드를 건너뛴다.
if [ -z "${SKIP_GUARD:-}" ]; then
  existing=$(gh api "repos/$repo/pulls/$number/reviews" \
    --jq "[.[] | select(.user.login==\"${ME:-}\" and .commit_id==\"$head_sha\")] | length" 2>/dev/null || echo 0)
  [ "${existing:-0}" != "0" ] && { echo "already reviewed"; exit 0; }
fi

# base 를 못 가져오면 diff 를 볼 수 없다. diff 없이 ok 가 나오면 승인이 나가므로 여기서 닫는다.
git fetch -q origin "$base" >/dev/null 2>&1 || { echo "diff failed"; exit 1; }

changed=$(git diff --numstat "origin/$base...HEAD" 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
big=false; [ "${changed:-0}" -gt 1500 ] && big=true

# Claude 에 Bash 를 주지 않는다. diff 와 변경 파일 목록을 파일로 미리 만들어 Read 로 읽게 한다.
# (Claude 가 cd/cat/grep/pipe 를 한 줄로 묶어 실행하면 통째로 거부돼 리뷰를 포기하던 문제)
mkdir -p .pr-review
git diff "origin/$base...HEAD" > .pr-review/diff.patch 2>/dev/null
git diff --name-status "origin/$base...HEAD" > .pr-review/files.txt 2>/dev/null

prompt="$(cat "$ROOT/prompt.md")

---
PR: #$number
base: origin/$base
변경 줄 수: $changed
대형 PR: $big"

# macOS 로컬에는 timeout 이 없을 수 있다(coreutils 의 gtimeout). 없으면 상한 없이 돈다.
t="$(command -v timeout || command -v gtimeout || true)"
# Claude 는 GitHub 토큰이 필요 없다. env 에서 빼서 리뷰 대상 레포의 훅·MCP 가 읽을 수 없게 한다.
# --setting-sources user: 대상 레포의 .claude/settings.json(훅) 을 읽지 않는다. CLAUDE.md 는 그대로 읽는다.
# --strict-mcp-config: 대상 레포의 .mcp.json 을 읽지 않는다.
${t:+"$t" 900} env -u GH_TOKEN -u GH_PAT claude -p "$prompt" \
  --output-format json \
  --json-schema "$(cat "$ROOT/review.schema.json")" \
  --model claude-sonnet-5-5 --effort medium \
  --permission-mode dontAsk \
  --setting-sources user --strict-mcp-config \
  --allowedTools "Read,Grep,Glob" \
  --disallowedTools "Read(//proc/**),Bash" \
  > "$work/claude.out" 2>/dev/null </dev/null
rc=$?
[ "$rc" -ne 0 ] && { echo "claude failed rc=$rc"; exit 1; }

jq -e '.structured_output | objects | has("summary") and has("verdict") and has("findings")' \
  "$work/claude.out" >/dev/null 2>&1 || { echo "no structured output"; exit 1; }
jq '.structured_output' "$work/claude.out" > "$work/review.json"

# fail-closed: 리뷰 본문에 토큰 값이나 토큰 접두가 섞여 있으면 제출하지 않는다.
# 리뷰 대상 레포의 문서·코드가 "환경을 읽어 적어라" 는 지시를 심어도 토큰이 PR 코멘트로 나가지 않게 하는 마지막 벽.
for secret in "${GH_PAT:-}" "${GH_TOKEN:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}"; do
  [ -n "$secret" ] && grep -qF -- "$secret" "$work/review.json" && { echo "review rejected"; exit 1; }
done
grep -qE 'sk-ant-|ghp_|github_pat_|gho_|ghs_|ghu_' "$work/review.json" && { echo "review rejected"; exit 1; }

bash "$ROOT/scripts/build-payload.sh" "$work/review.json" "$head_sha" "$big" > "$work/payload.json" 2>/dev/null \
  || { echo "payload failed"; exit 1; }

# GitHub 은 본인 PR 승인을 거부한다(422). 내가 연 PR 이면 Approve 를 Comment 로 내린다.
if [ "$author" = "${ME:-}" ]; then
  jq '.event = "COMMENT"
      | .body |= sub("^문제 없음\\. 승인합니다\\."; "문제 없음. 본인 PR 이라 승인 대신 코멘트로 남긴다.")
      | .body |= sub("^승인합니다\\. "; "본인 PR 이라 승인 대신 코멘트로 남긴다. ")' \
    "$work/payload.json" > "$work/payload.self.json" && mv "$work/payload.self.json" "$work/payload.json"
fi

if [ -n "${DRY_RUN:-}" ]; then
  cp "$work/payload.json" "$ROOT/work-last-payload.json" 2>/dev/null
  cp "$work/claude.out" "$ROOT/work-last-claude.out" 2>/dev/null   # 로컬 디버그용. *.out 은 gitignore
  echo "dry run: payload built"; exit 0
fi

if gh api -X POST "repos/$repo/pulls/$number/reviews" --input "$work/payload.json" >/dev/null 2>"$work/err"; then
  echo "submitted"; exit 0
fi
# 인라인 줄 위치를 GitHub 이 거부(422)하면 본문 목록으로 내려 한 번 더
if grep -q "422" "$work/err" 2>/dev/null; then
  bash "$ROOT/scripts/build-payload.sh" "$work/review.json" "$head_sha" "$big" --no-inline > "$work/payload.json" 2>/dev/null
  gh api -X POST "repos/$repo/pulls/$number/reviews" --input "$work/payload.json" >/dev/null 2>&1 \
    && { echo "submitted without inline"; exit 0; }
fi
echo "submit failed"; exit 1
