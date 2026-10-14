#!/usr/bin/env bash
# 60일간 커밋이 없으면 GitHub 이 schedule 워크플로를 끈다. 50일이 지났으면 빈 커밋을 올린다.
set -eu
last=$(git log -1 --format=%ct)
now=$(date +%s)
days=$(( (now - last) / 86400 ))
if [ "$days" -ge 50 ]; then
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git commit --allow-empty -q -m "chore: keepalive"
  # checkout 이 자격증명을 남기지 않으므로 이 스텝의 GH_TOKEN 으로 푸시한다. 브랜치는 명시한다
  gh auth setup-git >/dev/null 2>&1
  git push -q origin "HEAD:${GITHUB_REF_NAME:-main}"
  echo "keepalive pushed"
else
  echo "keepalive not needed"
fi
