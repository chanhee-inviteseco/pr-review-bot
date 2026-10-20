#!/usr/bin/env bash
# review.json + head sha + big(true|false) [--no-inline] [--promotion] → GitHub 리뷰 API payload(JSON) 를 stdout 으로.
# 네트워크 없음. 인라인 코멘트가 422 로 거부되면 --no-inline 으로 다시 만들어 본문 목록으로 내린다.
# --promotion: 승격 PR(base 가 main/release 등). 코드 리뷰가 아니라 포함 내역 요약이므로 승인하되 사람이 확인하라고 적는다.
set -eu
review="$1"; head_sha="$2"; big="$3"; shift 3
mode=inline; promotion=false
for a in "$@"; do
  case "$a" in
    --no-inline) mode=--no-inline ;;
    --promotion) promotion=true ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

jq -n --slurpfile in "$review" --arg sha "$head_sha" --arg big "$big" --arg mode "$mode" --arg promotion "$promotion" '
  $in[0] as $r
  | ($r.findings // []) as $f
  | ($f | map(select(.severity=="bug"))  | length) as $nb
  | ($f | map(select(.severity=="rule")) | length) as $nr
  | ($f | map(select(.severity=="note")) | length) as $nn
  | {bug:"[버그]", rule:"[규칙 위반]", note:"[참고]"} as $tag
  | ($promotion=="true") as $promo
  | ($big=="true" and ($promo|not)) as $isbig
  # 승인 규칙: 확실한 오류(bug)가 없으면 승인한다. 지적이 하나도 없는데 verdict=check 는 "리뷰 못 함" 이므로 승인하지 않는다.
  # 승격 PR 과 대형 PR 도 승인하되, 전부 본 게 아니므로 머리에 "사람이 확인하세요" 를 적는다.
  # 머리는 "승인합니다. " 로 시작해야 한다 — review-one.sh 가 본인 PR 일 때 그 접두를 치환한다.
  | (($f|length)==0 and $r.verdict!="ok") as $unreviewed
  | ($nb==0 and ($unreviewed|not)) as $approve
  | (if ($f|length)==0 then "" else " 참고 \($f|length)건 (규칙 위반 \($nr) · 참고 \($nn))" end) as $soft
  | (if $unreviewed then "확인 권장 (요약 참고)"
     elif $approve and $promo then "승인합니다. 승격 PR 이라 포함 내역만 요약했습니다. 머지 전에 사람이 확인하세요." + $soft
     elif $approve and $isbig then "승인합니다. 변경이 커서 핵심 경로만 봤습니다. 머지 전에 사람이 확인하세요." + $soft
     elif ($f|length)==0 then "문제 없음. 승인합니다."
     elif $approve then "승인합니다." + $soft
     else "확인 권장 \($f|length)건 (버그 \($nb) · 규칙 위반 \($nr) · 참고 \($nn))" end) as $head
  | (if $mode=="--no-inline" and ($f|length)>0
     then "\n\n" + ($f | map("- `\(.path):\(.line)` \($tag[.severity]) \(.body)") | join("\n"))
     else "" end) as $list
  # 머리가 이미 이유를 말했으면(approve) 끝 문구를 반복하지 않는다
  | (if $approve then ""
     elif $promo then "\n\n승격 PR 이라 포함 내역만 요약했습니다."
     elif $isbig then "\n\n변경이 커서 핵심 경로 위주로 봤습니다."
     else "" end) as $note
  | {
      commit_id: $sha,
      event: (if $approve then "APPROVE" else "COMMENT" end),
      body: ($head + "\n\n" + $r.summary + $list + $note),
      comments: (if $mode=="--no-inline" then []
                 else ($f | map({path, line, side:"RIGHT", body: ($tag[.severity] + " " + .body)})) end)
    }'
