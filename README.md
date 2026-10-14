# pr-review-bot

회사 조직의 PR 에서 내가 리뷰어로 지정되면 Claude 가 대신 1차 리뷰를 올린다. 5분마다 GitHub Actions 가 깨어나 검색하고, 대상이 있으면 리뷰한다. 리뷰는 내 계정 명의로 달리고, 문제가 없으면 승인한다.

## 동작

1. `gh search prs --review-requested=$ME --owner=$ORG --state=open --draft=false`
2. PR 마다 clone → `claude -p` (CLAUDE.md 와 diff 를 읽고 JSON 으로 리뷰) → 리뷰 API 한 번에 제출
3. 리뷰를 제출하면 GitHub 이 요청을 해소하므로 다음 tick 에 다시 잡히지 않는다. "리뷰 재요청" 을 누르면 다시 돈다.

## 시크릿 (Settings → Secrets → Actions)

| 이름 | 값 |
|---|---|
| `GH_PAT` | PAT. fine-grained 가 되면 조직 레포 대상 Contents 읽기 + Pull requests 읽기/쓰기, 만료 90일. 조직이 fine-grained 를 승인하지 않으면 classic `repo` 스코프 |
| `CLAUDE_CODE_OAUTH_TOKEN` | 로컬에서 `claude setup-token` |
| `ORG` | 조직 이름. 값이 로그에 찍혀도 자동 마스킹되도록 시크릿에 둔다. README·커밋에도 적지 않는다 |
| `ME` | 내 GitHub 계정명. 같은 이유로 시크릿에 둔다 |

| 토큰 | 발급일 | 만료일 | 갱신 |
|---|---|---|---|
| GH_PAT | 2026-10-14 | 2027-01-12 (90일. 실제 값은 github.com/settings/tokens 에서 확인) | 새 PAT 발급 → `gh secret set GH_PAT` |
| CLAUDE_CODE_OAUTH_TOKEN | 2026-10-14 | 2027-10-14 (`claude setup-token` 은 1년) | `claude setup-token` → `gh secret set CLAUDE_CODE_OAUTH_TOKEN` |

만료되면 워크플로가 실패로 끝나고 GitHub 이 실패 메일을 보낸다. 그게 갱신 신호다.

## 로그 규율 (퍼블릭 레포)

실행 로그는 누구나 본다. 스크립트는 조직 레포에서 온 어떤 문자열도 stdout/stderr 에 찍지 않는다. 모든 명령 출력은 파일 또는 `/dev/null` 로 간다. 새 명령을 추가할 때도 같은 규칙을 지킨다. `ACTIONS_STEP_DEBUG` 를 켜지 않는다. 레포 설정에서 Actions 로그 보관은 1일. collaborator 를 추가하지 않는다(워크플로를 고칠 수 있는 사람만 시크릿을 빼낼 수 있다).

## 깨우기 (외부 cron)

GitHub 의 `schedule` 트리거는 2026-08 말부터 새 레포에서 돌지 않는 사례가 많다(이 레포도 2시간 넘게 0건). 그래서 외부 cron 이 5분마다 `workflow_dispatch` API 를 호출해 깨운다. 워크플로의 `schedule` 은 GitHub 이 정상화되면 같이 돌도록 남겨 둔다. 두 트리거가 겹쳐도 `concurrency` 로 줄 서고, 같은 head 는 다시 리뷰하지 않는다.

- 토큰: fine-grained PAT, Resource owner = 본인 계정, 대상 레포 = 이 레포 하나, 권한 = Actions: Read and write. 조직 승인 불필요. 이 토큰은 이 레포의 워크플로를 깨우는 것만 할 수 있다.
- 외부 cron(예: cron-job.org) 설정:

| 항목 | 값 |
|---|---|
| Method | POST |
| URL | `https://api.github.com/repos/<계정>/pr-review-bot/actions/workflows/review.yml/dispatches` |
| Header | `Authorization: Bearer <토큰>` |
| Header | `Accept: application/vnd.github+json` |
| Body | `{"ref":"main"}` |
| 주기 | 5분 |

성공하면 GitHub 이 204 를 돌려주고 Actions 탭에 `workflow_dispatch` 실행이 생긴다.

| 토큰 | 발급일 | 만료일 |
|---|---|---|
| 외부 cron 용 PAT | | |

## 유지

GitHub 은 레포에 60일간 커밋이 없으면 schedule 워크플로를 자동으로 끈다. `scripts/keepalive.sh` 가 매 실행 끝에 마지막 커밋이 50일을 넘었는지 보고 빈 커밋을 올려 막는다. 그래도 꺼졌으면 Actions 탭에서 다시 켠다.

## 바꾸는 법

- 모델: `scripts/review-one.sh` 의 `--model`. 한도가 빠듯하면 `claude-haiku-5-5`.
- 간격: `.github/workflows/review.yml` 의 cron. 최소 5분.
- 트리거 계정: 시크릿 `ME` 만 바꾸면 다른 사람 계정용이 된다(그 사람의 PAT·토큰 필요).
- 수동 실행: Actions → Review → Run workflow. `repo`/`pr` 입력을 주면 검색 대신 그 PR 하나를 리뷰한다(내가 연 PR 에 쓰는 용도). `dry_run=true` 면 리뷰를 만들기만 하고 제출하지 않는다. 입력값은 env 가 아니라 이벤트 파일에서 읽으므로 로그에 찍히지 않는다.
- 내가 연 PR 은 GitHub 이 본인 승인을 거부하므로 Approve 대신 Comment 로 올린다.
- 봇은 리뷰 제출만 한다. 머지·커밋·푸시는 하지 않으며, Claude 에 허용된 도구도 파일 읽기와 `git diff`·`git log` 뿐이다.
- 회사 API 키로 전환: `CLAUDE_CODE_OAUTH_TOKEN` 대신 `ANTHROPIC_API_KEY` 시크릿을 넣고 워크플로 env 이름을 바꾼다.

## 로컬 테스트

```bash
bash scripts/test-build-payload.sh                                   # payload 변환 단위 테스트
bash scripts/test-review.sh                                          # 가짜 gh·claude 로 흐름 테스트
DRY_RUN=1 ORG=<조직> ME=<계정> bash scripts/review.sh              # 검색까지만, 제출 안 함
DRY_RUN=1 FORCE_REPO=<조직>/<레포> FORCE_PR=<번호> ORG=<조직> ME=<계정> bash scripts/review.sh   # 특정 PR 로 리뷰 생성까지, 제출 안 함
```
로컬에서는 `GH_PAT` 없이 로컬 `gh` 로그인, `CLAUDE_CODE_OAUTH_TOKEN` 없이 로컬 Claude 로그인을 쓴다. dry run 결과는 `work-last-payload.json` 에 남는다(커밋하지 않는다).
