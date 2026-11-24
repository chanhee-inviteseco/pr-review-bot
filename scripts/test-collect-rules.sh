#!/usr/bin/env bash
# collect-rules.sh 단위 테스트. 임시 git 레포를 만들어 base 에서 무엇이 모이는지 본다.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; [ -f "$tmp/out.md" ] && cat "$tmp/out.md"; exit 1; }
has()  { grep -qF -- "$1" "$tmp/out.md"; }

repo="$tmp/repo"; mkdir -p "$repo"; cd "$repo"
git init -q; git config user.email t@t; git config user.name t
mkdir -p .claude/rules docs apps/web/src apps/web/.claude/rules apps/admin deploy .agents/skills/x node_modules/pkg linked
printf '@AGENTS.md\n\nClaude 전용 메모 ROOT-CLAUDE\n'              > CLAUDE.md
printf 'ROOT-AGENTS-BASE\n자세한 것은 @docs/conv.md 를 본다. @someone 에게 문의, @types/node 사용.\n' > AGENTS.md
printf 'DOCS-CONV\n@../CLAUDE.md\n'                                 > docs/conv.md        # 순환 import
printf -- '---\npaths: ["apps/web/**"]\n---\nRULE-JPA\n'            > .claude/rules/jpa.md
printf 'WEB-CLAUDE\n'                                               > apps/web/CLAUDE.md
printf 'WEB-AGENTS\n'                                               > apps/web/AGENTS.md
printf 'WEB-RULE\n'                                                 > apps/web/.claude/rules/ui.md
printf 'ADMIN-CLAUDE\n'                                             > apps/admin/CLAUDE.md
printf 'DEPLOY-UPPER\n'                                             > deploy/CLAUDE.MD
printf 'VENDORED-SKILL\n'                                           > .agents/skills/x/AGENTS.md
printf 'VENDORED-NM\n'                                              > node_modules/pkg/CLAUDE.md
printf 'LINK-TARGET\n'                                              > linked/REAL.md
ln -s REAL.md linked/CLAUDE.md
echo x > apps/web/src/a.ts; echo x > deploy/d.yml; echo x > linked/f.txt; echo x > node_modules/pkg/i.js
git add -A; git commit -q -m base; git branch -q -M develop
git checkout -q -b pr
printf 'ROOT-AGENTS-HEAD\n' > AGENTS.md          # PR 이 규칙을 고친다
printf 'NEW-IN-PR\n' > apps/web/src/CLAUDE.md     # PR 이 새 규칙 파일을 넣는다
echo y > apps/web/src/a.ts
git add -A; git commit -q -m pr

run() { bash "$ROOT/scripts/collect-rules.sh" develop "$tmp/files.txt" "$tmp/out.md"; }

# 1. apps/web 만 바꾼 PR: 루트 + apps/web 계열만, base 내용으로, import 는 따라가고, 무관한 앱·vendored 는 뺀다
git diff --name-status develop...pr > "$tmp/files.txt"
out=$(run) || fail "1 exit"
[ "$out" = "7 1" ] || fail "1 count/touched: $out"
for s in ROOT-CLAUDE ROOT-AGENTS-BASE DOCS-CONV RULE-JPA WEB-CLAUDE WEB-AGENTS WEB-RULE; do has "$s" || fail "1 missing $s"; done
has 'paths: ["apps/web/**"]' || fail "1 frontmatter dropped"
for s in ROOT-AGENTS-HEAD NEW-IN-PR ADMIN-CLAUDE DEPLOY-UPPER VENDORED-SKILL VENDORED-NM LINK-TARGET; do has "$s" && fail "1 should not contain $s"; done
[ "$(grep -c '<rule-file path="CLAUDE.md">' "$tmp/out.md")" = "1" ] || fail "1 circular import duplicated the root file"
head -1 "$tmp/out.md" | grep -qx '<repo-rules>' || fail "1 open tag"
tail -1 "$tmp/out.md" | grep -qx '</repo-rules>' || fail "1 close tag"
# 얕은 것부터: 루트 CLAUDE.md 가 apps/web/CLAUDE.md 보다 먼저
[ "$(grep -n 'ROOT-CLAUDE' "$tmp/out.md" | cut -d: -f1)" -lt "$(grep -n 'WEB-CLAUDE' "$tmp/out.md" | cut -d: -f1)" ] || fail "1 order"

# 2. 대문자 확장자(CLAUDE.MD), 규칙 파일을 안 건드린 PR → touched 0
printf 'M\tdeploy/d.yml\n' > "$tmp/files.txt"
out=$(run) || fail "2 exit"
[ "${out#* }" = "0" ] || fail "2 touched: $out"
has DEPLOY-UPPER || fail "2 uppercase .MD not collected"
has WEB-CLAUDE && fail "2 unrelated app collected"

# 3. 심볼릭 링크 CLAUDE.md → 대상 파일 내용. rename 줄의 새 경로도 상위 디렉터리로 친다
printf 'R100\told/f.txt\tlinked/f.txt\n' > "$tmp/files.txt"
run >/dev/null || fail "3 exit"
has LINK-TARGET || fail "3 symlink target not collected"
has '<rule-file path="linked/REAL.md">' || fail "3 symlink path"

# 4. vendored 디렉터리 안의 변경이어도 그 규칙은 넣지 않는다
printf 'M\tnode_modules/pkg/i.js\n' > "$tmp/files.txt"
run >/dev/null || fail "4 exit"
has VENDORED-NM && fail "4 node_modules rule collected"

# 5. 용량 상한을 넘는 파일은 본문 대신 경로만 적는다
git diff --name-status develop...pr > "$tmp/files.txt"
out=$(RULES_MAX_BYTES=60 run) || fail "5 exit"
[ "${out% *}" -lt 7 ] || fail "5 cap ignored: $out"
grep -q '<omitted' "$tmp/out.md" || fail "5 omitted list missing"

# 6. 규칙 문서가 없는 레포 → 0, 블록은 "없다" 로 채운다
empty="$tmp/empty"; mkdir -p "$empty"; cd "$empty"
git init -q; git config user.email t@t; git config user.name t
echo x > a.txt; git add -A; git commit -q -m base; git branch -q -M develop
printf 'M\ta.txt\n' > "$tmp/files.txt"
out=$(run) || fail "6 exit"
[ "$out" = "0 0" ] || fail "6 count: $out"
has "규칙 문서가 없다" || fail "6 empty marker"

# 7. base 를 못 읽으면 실패한다(규칙 없이 조용히 리뷰하지 않도록)
bash "$ROOT/scripts/collect-rules.sh" no-such-ref "$tmp/files.txt" "$tmp/out.md" >/dev/null 2>&1 && fail "7 should fail"

echo "PASS"
