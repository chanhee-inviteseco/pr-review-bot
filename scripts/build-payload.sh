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
  def quote: split("\n") | map("> " + .) | join("\n");
  $in[0] as $r
  | ($r.findings // []) as $f
  | ($f | map(select(.severity=="bug"))  | length) as $nb
  | ($f | map(select(.severity=="rule")) | length) as $nr
  | ($f | map(select(.severity=="note")) | length) as $nn
  # 인라인 코멘트는 GitHub 알림 블록으로 낸다 — 심각도가 색과 아이콘으로 구분된다(bug 빨강 · rule 보라 · note 파랑).
  # 알림 블록의 제목은 영어로 고정이라 한글 라벨을 본문 첫머리에 굵게 둔다. 본문이 여러 줄이어도 모든 줄을 인용으로 묶는다.
  | {bug:"CAUTION", rule:"IMPORTANT", note:"NOTE"} as $alert
  | {bug:"버그", rule:"규칙 위반", note:"참고"} as $label
  | ($promotion=="true") as $promo
  | ($big=="true" and ($promo|not)) as $isbig
  # 승인 규칙: 확실한 오류(bug)가 없으면 승인한다. 지적이 하나도 없는데 verdict=check 는 "리뷰 못 함" 이므로 승인하지 않는다.
  # 승격 PR 과 대형 PR 도 승인하되, 전부 본 게 아니므로 머리 아래 알림 블록으로 "사람 확인 필요" 를 적는다.
  # 본문은 "머리 한 줄 → 주의 블록 → 요약 → 구획별 목록" 순서다. 한 문단에 다 넣지 않고 구획마다 빈 줄로 끊는다.
  # 머리는 "**승인**" 으로 시작해야 한다 — review-one.sh 가 본인 PR 일 때 그 접두를 치환한다.
  | (($f|length)==0 and $r.verdict!="ok") as $unreviewed
  | ($nb==0 and ($unreviewed|not)) as $approve
  # 건수는 0 이 아닌 것만 적는다
  | ([["버그",$nb],["규칙 위반",$nr],["참고",$nn]] | map(select(.[1]>0) | "\(.[0]) \(.[1])") | join(" · ")) as $counts
  | (if $unreviewed then "**확인 권장** · 리뷰하지 못함"
     elif ($f|length)==0 then "**승인** · 지적 없음"
     elif $approve then "**승인** · " + $counts
     else "**확인 권장** · " + $counts end) as $head
  | (if $promo then "> [!NOTE]\n> 승격 PR 이라 포함 내역만 요약함. 머지 전 사람 확인 필요함."
     elif $isbig then "> [!NOTE]\n> 변경이 커서 큰 틀만 봄. 나눠 올리면 더 자세히 볼 수 있음. 머지 전 사람 확인 필요함."
     else "" end) as $caveat
  # 승격 PR 의 요약은 "첫 줄 = 건수, 그 뒤 = 포함 PR 목록" 이다. 목록이 길면(6줄 이상) 접어서 본문이 한눈에 들어오게 한다.
  | ($r.summary | split("\n")) as $sl
  | ($sl[1:] | map(select(test("\\S")))) as $rest
  | (if $promo and ($rest|length) > 5
     then $sl[0] + "\n\n<details>\n<summary>포함 내역 \($rest|length)줄</summary>\n\n" + ($rest|join("\n")) + "\n\n</details>"
     else $r.summary end) as $summary
  # 선택 필드(reviewed·not_reviewed)는 제목 + 불릿 목록으로 낸다. 모델이 "- " 를 붙여 와도 한 번만 붙게 떼고 붙인다.
  | def section($title; $items):
      (($items // []) | map(select(type=="string" and test("\\S")) | sub("^\\s*[-*]\\s+"; ""))) as $i
      | if ($i|length)==0 then "" else "**\($title)**\n" + ($i | map("- " + .) | join("\n")) end;
  (if $mode=="--no-inline" and ($f|length)>0
     then "**지적**\n" + ($f | map("- **\($label[.severity])** `\(.path):\(.line)`\n  " + (.body | split("\n") | join("\n  "))) | join("\n"))
     else "" end) as $list
  | {
      commit_id: $sha,
      event: (if $approve then "APPROVE" else "COMMENT" end),
      body: ([$head, $caveat, $summary,
              section("확인한 것"; $r.reviewed),
              section("확인하지 않은 것"; $r.not_reviewed),
              $list] | map(select(. != "")) | join("\n\n")),
      comments: (if $mode=="--no-inline" then []
                 else ($f | map({path, line, side:"RIGHT", body: ("> [!\($alert[.severity])]\n" + ("**\($label[.severity])** " + .body | quote))})) end)
    }'
