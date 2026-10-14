#!/usr/bin/env bash
# 내가 리뷰어로 걸린 열린 PR 을 찾아 하나씩 review-one.sh 로 넘긴다.
# 퍼블릭 레포 규율: 조직 레포에서 온 문자열은 stdout/stderr 에 찍지 않는다.
set -u
set +x
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

: "${ORG:?}" "${ME:?}"
[ -n "${GH_PAT:-}" ] && export GH_TOKEN="$GH_PAT"

if [ -n "${FORCE_REPO:-}" ] && [ -n "${FORCE_PR:-}" ]; then
  jq -n --arg r "$FORCE_REPO" --argjson n "$FORCE_PR" '[{number:$n, repository:{nameWithOwner:$r}}]' > "$WORK/prs.json"
else
  gh search prs --review-requested="$ME" --owner="$ORG" --state=open --draft=false \
    --limit 20 --json number,repository > "$WORK/prs.json" 2>/dev/null \
    || { echo "search failed"; exit 1; }
fi

count=$(jq 'length' "$WORK/prs.json" 2>/dev/null || echo 0)
echo "targets: $count"
[ "$count" -eq 0 ] && exit 0

[ -n "${GH_PAT:-}" ] && gh auth setup-git >/dev/null 2>&1

failed=0
while IFS=$'\t' read -r repo number; do
  echo "::add-mask::$repo"
  if bash "$ROOT/scripts/review-one.sh" "$repo" "$number" "$WORK"; then
    echo "reviewed"
  else
    echo "one failed"; failed=1
  fi
done < <(jq -r '.[] | [.repository.nameWithOwner, (.number|tostring)] | @tsv' "$WORK/prs.json")
exit $failed
