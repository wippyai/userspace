#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
    echo 'usage: publish-module.sh DIRECTORY VERSION dry-run|publish' >&2
    exit 1
fi
directory="$1"
module_version="$2"
mode="$3"

# Accept one package, never the aggregate src tree or a nested test workspace.
if [[ ! "$directory" =~ ^(docker(-client)?|src/[a-z][a-z0-9-]*)$ ]] \
    || [[ ! -f "$directory/wippy.yaml" ]] || [[ -z "$module_version" ]]; then
    echo 'select an existing package directory and an explicit version' >&2
    exit 1
fi

args=(publish --config "$directory" --version "$module_version")
case "$mode" in
    dry-run) args+=(--dry-run) ;;
    publish)
        if [[ "${GITHUB_REF:-}" != refs/heads/master ]] \
            || [[ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ]] \
            || [[ -z "${WIPPY_TOKEN:-}" ]]; then
            echo 'publication requires an explicit master dispatch and WIPPY_TOKEN' >&2
            exit 1
        fi
        ;;
    *) echo 'mode must be dry-run or publish' >&2; exit 1 ;;
esac

"${WIPPY:-wippy}" "${args[@]}"
