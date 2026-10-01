#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export PUBLISH_TEST_LOG="$test_dir/calls"
export WIPPY="$PWD/.github/tests/wippy-publish-stub.sh"
export GITHUB_EVENT_NAME=workflow_dispatch
export GITHUB_REF=refs/heads/master
unset WIPPY_TOKEN

# A repository release tag must never cause Hub publication.
if grep -Eq '^[[:space:]]+push:' .github/workflows/publish.yml; then
    echo 'FAIL: module publication is still triggered by a push or tag' >&2
    exit 1
fi

check_call() {
    local directory="$1" mode="$2" expected
    : > "$PUBLISH_TEST_LOG"
    bash .github/scripts/publish-module.sh "$directory" 0.0.0-test "$mode"
    expected=$'publish\n--config\n'"$directory"$'\n--version\n0.0.0-test'
    if [[ "$mode" == dry-run ]]; then
        expected+=$'\n--dry-run'
    fi
    if [[ "$(<"$PUBLISH_TEST_LOG")" != "$expected" ]]; then
        echo "FAIL: incorrect or repeated Wippy call for $directory ($mode)" >&2
        exit 1
    fi
}

reject() {
    : > "$PUBLISH_TEST_LOG"
    if bash .github/scripts/publish-module.sh "$@" > "$test_dir/output" 2>&1; then
        echo "FAIL: unsafe publication accepted: $*" >&2
        exit 1
    fi
    if [[ -s "$PUBLISH_TEST_LOG" ]]; then
        echo "FAIL: rejected publication still invoked Wippy: $*" >&2
        exit 1
    fi
}

check_call docker dry-run
check_call src/user dry-run
check_call src/uploads dry-run

for directory in . src userspace ../docker docker/test src/uploads/test \
    /tmp/docker src/../docker src/missing '*'; do
    reject "$directory" 0.0.0-test dry-run
done
if [[ -f docker-client/wippy.yaml ]]; then
    check_call docker-client dry-run
else
    reject docker-client 0.0.0-test dry-run
fi
reject $'docker\n--create' 0.0.0-test dry-run
reject docker '' dry-run
reject docker 0.0.0-test unknown
reject docker 0.0.0-test
reject docker 0.0.0-test dry-run extra

# These calls use a stub, never a real publishing token or the real CLI.
export WIPPY_TOKEN=wpy_test_only
export GITHUB_REF=refs/heads/feature
reject docker 0.0.0-test publish
check_call docker dry-run
export GITHUB_REF=refs/tags/v0.6.0
reject docker 0.0.0-test publish
export GITHUB_REF=refs/heads/master
export GITHUB_EVENT_NAME=push
reject docker 0.0.0-test publish
export GITHUB_EVENT_NAME=workflow_dispatch
unset WIPPY_TOKEN
reject docker 0.0.0-test publish
export WIPPY_TOKEN=wpy_test_only
check_call docker publish
check_call src/user publish

echo 'PASS: explicit single-module selection, dry runs, and publication guards'
