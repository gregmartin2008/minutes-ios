#!/bin/bash
# Publishes a folder of build results to a branch of this repository, replacing what was there.
# usage: ci_publish.sh <folder> <branch>
set -euo pipefail
src="$1"; branch="$2"
work="$(mktemp -d)"
cp -R "$src"/. "$work"/
echo "run ${GITHUB_RUN_ID:-local} attempt ${GITHUB_RUN_ATTEMPT:-0} at $(date -u +%FT%TZ) for ${GITHUB_SHA:-unknown}" > "$work/RUN.txt"
cd "$work"
git init -q -b "$branch"
git config user.name "minutes-ci"
git config user.email "minutes-ci@users.noreply.github.com"
git add -A
git commit -q -m "results for ${GITHUB_SHA:-local}"
git push -q -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$branch:$branch"
echo "published $(git ls-files | wc -l | tr -d ' ') files to $branch"
