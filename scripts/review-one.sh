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
gh pr view "$number" --json baseRefName,headRefOid > "$work/pr.json" 2>/dev/null || { echo "view failed"; exit 1; }
base=$(jq -r .baseRefName "$work/pr.json")
head_sha=$(jq -r .headRefOid "$work/pr.json")
git fetch -q origin "$base" >/dev/null 2>&1

changed=$(git diff --numstat "origin/$base...HEAD" 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
big=false; [ "${changed:-0}" -gt 1500 ] && big=true

prompt="$(cat "$ROOT/prompt.md")

---
PR: #$number
base: origin/$base
변경 줄 수: $changed
대형 PR: $big"

# macOS 로컬에는 timeout 이 없을 수 있다(coreutils 의 gtimeout). 없으면 상한 없이 돈다.
t="$(command -v timeout || command -v gtimeout || true)"
${t:+"$t" 900} claude -p "$prompt" \
  --output-format json \
  --json-schema "$(cat "$ROOT/review.schema.json")" \
  --model claude-sonnet-5-5 --effort medium \
  --permission-mode dontAsk \
  --allowedTools "Read,Grep,Glob,Bash(git diff *),Bash(git log *)" \
  > "$work/claude.out" 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && { echo "claude failed rc=$rc"; exit 1; }

jq -e '.structured_output | objects | has("summary") and has("verdict") and has("findings")' \
  "$work/claude.out" >/dev/null 2>&1 || { echo "no structured output"; exit 1; }
jq '.structured_output' "$work/claude.out" > "$work/review.json"

bash "$ROOT/scripts/build-payload.sh" "$work/review.json" "$head_sha" "$big" > "$work/payload.json" 2>/dev/null \
  || { echo "payload failed"; exit 1; }

if [ -n "${DRY_RUN:-}" ]; then
  cp "$work/payload.json" "$ROOT/work-last-payload.json" 2>/dev/null
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
