#!/usr/bin/env bash
# 리뷰 대상 레포의 규칙 문서를 base 브랜치에서 모아 한 파일로 만든다. cwd 는 대상 레포.
# 모델이 규칙 문서를 찾아 읽기를 기대하지 않고, 여기서 확정적으로 모아 시스템 프롬프트로 넣는다.
#
# 사용: collect-rules.sh <base-ref> <files.txt(git diff --name-status)> <out>
# stdout: "<넣은 파일 수> <PR 이 규칙 파일을 건드렸으면 1, 아니면 0>" — 숫자만 낸다(퍼블릭 로그).
#
# 모으는 것(파일명은 대소문자 무시 — CLAUDE.MD 로 둔 레포가 있다):
#   **/CLAUDE.md  **/AGENTS.md  **/.claude/CLAUDE.md  **/.claude/rules/**/*.md
#   단, 레포 루트의 것과 "변경 파일의 상위 디렉터리"에 있는 것만. 모노레포에서 무관한 앱의 규칙은 넣지 않는다.
#   위 문서가 @경로.md 로 불러오는 문서(재귀), 심볼릭 링크면 그 대상.
# base 에서 읽는 이유: PR 이 규칙 문서를 고쳐 자기 자신을 통과시키지 못하게 한다.
set -u
ref="$1"; files="$2"; out="$3"
max="${RULES_MAX_BYTES:-120000}"   # 규칙 본문 합계 상한. 넘는 파일은 경로만 적는다
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

git -c core.quotepath=off ls-tree -r "$ref" > "$tmp/ls" 2>/dev/null || exit 1
cut -f2- "$tmp/ls" > "$tmp/tree"
awk -F'\t' '$1 ~ /^120000 /{print $2}' "$tmp/ls" > "$tmp/links"
# name-status 는 "M<TAB>경로" 또는 "R100<TAB>옛경로<TAB>새경로"
cut -f2- "$files" 2>/dev/null | tr '\t' '\n' | sed '/^$/d' > "$tmp/changed"

# a/./b/../c → a/c. 레포 밖으로 나가면 빈 문자열
norm() {
  awk -v p="$1" 'BEGIN{
    n=split(p,a,"/"); m=0
    for(i=1;i<=n;i++){
      if(a[i]==""||a[i]==".") continue
      if(a[i]==".."){ if(m>0) m--; else { print ""; exit } continue }
      b[++m]=a[i]
    }
    s=""; for(i=1;i<=m;i++) s=(i==1?b[i]:s"/"b[i]); print s
  }'
}

# 후보 선정: 규칙 파일이 "속한 디렉터리"가 루트이거나 변경 파일의 상위 디렉터리일 때만. 얕은 것부터
awk -F/ '
  FILENAME==ARGV[1] { p=""; for(i=1;i<NF;i++){ p=(p==""?$i:p"/"$i); d[p]=1 } next }
  {
    path=$0; low=tolower(path)
    if (low ~ /(^|\/)(node_modules|vendor|\.agents)\//) next      # 들여온 남의 규칙
    if (low ~ /(^|\/)\.claude\/rules\/.*\.md$/)      { owner=substr(path,1,index(low,".claude/rules/")-1) }
    else if (low ~ /(^|\/)\.claude\/claude\.md$/)    { owner=substr(path,1,length(path)-length(".claude/claude.md")) }
    else if (low ~ /(^|\/)(claude|agents)\.md$/)     { owner=path; sub(/[^\/]*$/,"",owner) }
    else next
    sub(/\/$/,"",owner)
    if (owner=="" || (owner in d)) { n=(owner==""?0:split(owner,x,"/")); printf "%d\t%s\n", n, path }
  }' "$tmp/changed" "$tmp/tree" | sort -t"$(printf '\t')" -k1,1n -k2,2 | cut -f2- > "$tmp/queue"

touched=0
grep -iqE '(^|/)(claude|agents)\.md$|(^|/)\.claude/rules/.*\.md$' "$tmp/changed" && touched=1

echo '<repo-rules>' > "$out"
: > "$tmp/seen"; : > "$tmp/skipped"; n=0; size=0; i=1
while :; do
  p=$(sed -n "${i}p" "$tmp/queue"); [ -z "$p" ] && break; i=$((i+1))
  grep -Fxq -- "$p" "$tmp/seen" && continue; echo "$p" >> "$tmp/seen"
  dir=""; case "$p" in */*) dir="${p%/*}" ;; esac

  # 심볼릭 링크(CLAUDE.md → AGENTS.md 등)는 대상 파일을 대신 넣는다
  if grep -Fxq -- "$p" "$tmp/links"; then
    q=$(norm "${dir:+$dir/}$(git show "$ref:$p" 2>/dev/null)")
    [ -n "$q" ] && grep -Fxq -- "$q" "$tmp/tree" && echo "$q" >> "$tmp/queue"
    continue
  fi

  git show "$ref:$p" > "$tmp/body" 2>/dev/null || continue
  bytes=$(wc -c < "$tmp/body" | tr -d ' ')
  if [ $((size + bytes)) -gt "$max" ]; then echo "$p" >> "$tmp/skipped"; continue; fi
  size=$((size + bytes)); n=$((n + 1))
  { printf '\n<rule-file path="%s">\n' "$p"; cat "$tmp/body"; printf '\n</rule-file>\n'; } >> "$out"

  # @경로.md import. 실제로 base 에 있는 파일만 따라간다(@멘션·@scope/pkg 는 여기서 걸러진다)
  grep -oE '(^|[[:space:]])@[A-Za-z0-9_./-]+\.[mM][dD]' "$tmp/body" 2>/dev/null | sed 's/^[[:space:]]*@//' | while read -r t; do
    for c in "${dir:+$dir/}$t" "$t"; do
      q=$(norm "$c")
      if [ -n "$q" ] && grep -Fxq -- "$q" "$tmp/tree"; then echo "$q" >> "$tmp/queue"; break; fi
    done
  done
done

{
  [ "$n" -eq 0 ] && printf '\n(이 레포에는 규칙 문서가 없다.)\n'
  if [ -s "$tmp/skipped" ]; then
    printf '\n<omitted reason="용량 상한">\n'; cat "$tmp/skipped"; printf '</omitted>\n'
  fi
  echo '</repo-rules>'
} >> "$out"

echo "$n $touched"
