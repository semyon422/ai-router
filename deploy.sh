#!/bin/sh
# Deploy a commit on the machine where this repo is checked out:
# checkout, run the test suite, recreate the compose service, wait for health.
set -eu

commit="${1:?usage: ./deploy.sh <full-commit-sha>}"

cd "$(dirname "$0")"

exec 9>.deploy.lock
flock --wait 7200 9

test -z "$(git status --porcelain --untracked-files=no)"
git fetch --no-recurse-submodules --no-tags origin "$commit"
git cat-file -e "$commit^{commit}"
git checkout --detach "$commit"
git submodule update --init
test -z "$(git status --porcelain --untracked-files=no)"
test "$(git rev-parse HEAD)" = "$commit"

./test

export AIROUTER_UID="$(id -u)"
export AIROUTER_GID="$(id -g)"
docker compose -p ai-router -f compose.yaml up --detach --force-recreate --pull missing

attempts=0
until [ "$attempts" -ge 30 ]; do
	if docker compose -p ai-router -f compose.yaml ps --format json ai-router | grep -q '"Health":"healthy"'; then
		echo "ai-router $commit deployed and healthy"
		exit 0
	fi
	attempts=$((attempts + 1))
	sleep 2
done
echo "ai-router $commit failed health checks; no rollback performed" >&2
exit 1
