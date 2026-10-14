#!/usr/bin/env bash
# review.json + head sha + big(true|false) [--no-inline] → GitHub 리뷰 API payload(JSON) 를 stdout 으로.
# 네트워크 없음. 인라인 코멘트가 422 로 거부되면 --no-inline 으로 다시 만들어 본문 목록으로 내린다.
set -eu
review="$1"; head_sha="$2"; big="$3"; mode="${4:-inline}"

jq -n --slurpfile in "$review" --arg sha "$head_sha" --arg big "$big" --arg mode "$mode" '
  $in[0] as $r
  | ($r.findings // []) as $f
  | ($f | map(select(.severity=="bug"))  | length) as $nb
  | ($f | map(select(.severity=="rule")) | length) as $nr
  | ($f | map(select(.severity=="note")) | length) as $nn
  | {bug:"[버그]", rule:"[규칙 위반]", note:"[참고]"} as $tag
  # 승인 규칙: 확실한 오류(bug)가 없으면 승인한다. 지적이 하나도 없는데 verdict=check 는 "리뷰 못 함" 이므로 승인하지 않는다.
  | (($f|length)==0 and $r.verdict!="ok") as $unreviewed
  | ($nb==0 and ($unreviewed|not)) as $approve
  | (if $unreviewed then "확인 권장 (요약 참고)"
     elif ($f|length)==0 then "문제 없음. 승인합니다."
     elif $approve then "승인합니다. 참고 \($f|length)건 (규칙 위반 \($nr) · 참고 \($nn))"
     else "확인 권장 \($f|length)건 (버그 \($nb) · 규칙 위반 \($nr) · 참고 \($nn))" end) as $head
  | (if $mode=="--no-inline" and ($f|length)>0
     then "\n\n" + ($f | map("- `\(.path):\(.line)` \($tag[.severity]) \(.body)") | join("\n"))
     else "" end) as $list
  | (if $big=="true" then "\n\n변경이 커서 핵심 경로 위주로 봤습니다." else "" end) as $bignote
  | {
      commit_id: $sha,
      event: (if $approve then "APPROVE" else "COMMENT" end),
      body: ($head + "\n\n" + $r.summary + $list + $bignote),
      comments: (if $mode=="--no-inline" then []
                 else ($f | map({path, line, side:"RIGHT", body: ($tag[.severity] + " " + .body)})) end)
    }'
