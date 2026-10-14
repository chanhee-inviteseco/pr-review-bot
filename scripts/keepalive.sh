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
  git push -q
  echo "keepalive pushed"
else
  echo "keepalive not needed"
fi
