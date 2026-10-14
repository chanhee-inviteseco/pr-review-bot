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

# 수동 실행(workflow_dispatch) 입력은 env 가 아니라 이벤트 파일에서 읽는다. env 값은 러너가 로그에 찍기 때문이다.
if [ -z "${FORCE_REPO:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  FORCE_REPO=$(jq -r '.inputs.repo // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)
  FORCE_PR=$(jq -r '.inputs.pr // empty' "$GITHUB_EVENT_PATH" 2>/dev/null)
  [ "$(jq -r '.inputs.dry_run // "false"' "$GITHUB_EVENT_PATH" 2>/dev/null)" = "true" ] && export DRY_RUN=1
fi

if [ -n "${FORCE_REPO:-}" ] || [ -n "${FORCE_PR:-}" ]; then
  # 수동 지정은 둘 다 있어야 하고 번호는 숫자여야 한다. 반쯤 온 입력으로 조용히 검색에 빠지지 않는다.
  if [ -z "${FORCE_REPO:-}" ] || [ -z "${FORCE_PR:-}" ] || ! [[ "$FORCE_PR" =~ ^[0-9]+$ ]]; then
    echo "bad inputs"; exit 1
  fi
  jq -n --arg r "$FORCE_REPO" --argjson n "$FORCE_PR" '[{number:$n, repository:{nameWithOwner:$r}}]' > "$WORK/prs.json"
  export SKIP_GUARD=1   # 수동 지정은 같은 head 에 내 리뷰가 있어도 다시 리뷰한다
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
  # </dev/null: 자식(특히 claude -p)이 루프의 stdin 을 읽어 남은 대상을 삼키지 못하게 한다
  if bash "$ROOT/scripts/review-one.sh" "$repo" "$number" "$WORK" </dev/null; then
    echo "reviewed"
  else
    echo "one failed"; failed=1
  fi
done < <(jq -r '.[] | [.repository.nameWithOwner, (.number|tostring)] | @tsv' "$WORK/prs.json")
exit $failed
