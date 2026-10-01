#!/usr/bin/env bash
set -euo pipefail

: "${WIPPY:?path to the verified runtime is required}"
docker_security=$(docker info --format '{{json .SecurityOptions}}')
if ! grep -q 'name=apparmor' <<< "$docker_security" || ! grep -q 'name=seccomp' <<< "$docker_security" \
  || ! test -f /sys/fs/cgroup/cgroup.controllers; then
  echo 'Hardened PTY check requires a Linux Docker daemon with AppArmor, seccomp and cgroup v2' >&2
  exit 1
fi

test_root=$(mktemp -d /tmp/wippy-docker-pty.XXXXXX)
cleanup() {
  local status=$?
  local id
  if [[ "$status" != 0 ]]; then
    echo "PTY check failed; logs: $test_root" >&2
    for log in "$test_root/created.log" "$test_root/false.stdout" "$test_root/false.stderr" \
      "$test_root/true.stdout" "$test_root/true.stderr"; do
      if [[ -f "$log" ]]; then
        echo "$log" >&2
        cat "$log" >&2
      fi
    done
  fi
  while IFS= read -r id; do
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then
      if [[ "$status" != 0 ]]; then
        docker inspect --format '{{json .State}}' "$id" >&2 || true
        docker logs "$id" >&2 || true
      fi
      docker rm --force "$id" || status=1
    fi
  done < <(docker ps --all --quiet --no-trunc --filter "label=bee.attempt_id=$test_root")
  exit "$status"
}
trap cleanup EXIT
mkdir "$test_root/work" "$test_root/state" "$test_root/runtime"
chmod 0755 "$test_root" "$test_root/runtime"
chmod 0777 "$test_root/work" "$test_root/state"
cp pty_sandbox.sh "$test_root/runtime/check.sh"
docker pull alpine:3.22
WIPPY_DOCKER_PTY_IMAGE=$(docker image inspect alpine:3.22 --format '{{.Id}}')
export WIPPY_DOCKER_PTY_IMAGE
export WIPPY_DOCKER_PTY_ROOT="$test_root"
"$WIPPY" run docker-pty-contract 2>&1 | tee "$test_root/created.log"

containers=0
while read -r marker id tty; do
  if [[ "$marker" != PTY_CONTAINER ]]; then continue; fi
  [[ "$id" =~ ^[0-9a-f]{64}$ ]]
  [[ "$tty" == true || "$tty" == false ]]
  test "$(docker inspect --format '{{index .Config.Labels "bee.attempt_id"}}' "$id")" = "$test_root"
  # Keep stdin open until attachment completes. A short-lived pipe producer can
  # make Docker detach on EOF before it drains the container's final output.
  coproc PTY_ATTACH { timeout --kill-after=5s 30s docker attach --sig-proxy=false "$id" > "$test_root/$tty.stdout" 2> "$test_root/$tty.stderr"; }
  attach_pid=$PTY_ATTACH_PID
  printf 'pty-input\n' >& "${PTY_ATTACH[1]}"
  wait "$attach_pid"
  tr -d '\r' < "$test_root/$tty.stdout" > "$test_root/$tty.output"
  grep -Fxq "PTY_MODE $tty" "$test_root/$tty.output"
  grep -Fxq 'PTY_INPUT_OK' "$test_root/$tty.output"
  if [[ "$tty" == true ]]; then
    grep -Fxq 'PTY_STDERR_OK' "$test_root/$tty.output"
  else
    grep -Fxq 'PTY_STDERR_OK' "$test_root/$tty.stderr"
    if grep -Fxq 'PTY_STDERR_OK' "$test_root/$tty.output"; then exit 1; fi
  fi
  test "$(docker wait "$id")" = 0
  containers=$((containers + 1))
done < "$test_root/created.log"
test "$containers" = 2
echo 'PASS: real contract create, unchanged kernel sandbox, native attachment and stdin in both modes'
