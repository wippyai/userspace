#!/bin/sh
set -eu

test "$(id -u)" = 1000
test "$(id -g)" = 1000
grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status
grep -Eq '^Seccomp:[[:space:]]+2$' /proc/self/status
grep -Eq '^CapEff:[[:space:]]+0+$' /proc/self/status
grep -q 'docker-default (enforce)' /proc/self/attr/current
awk '$2 == "/" && $4 ~ /^ro(,|$)/ {found=1} END {exit !found}' /proc/mounts
test "$(cat /sys/fs/cgroup/memory.max)" = 134217728
test "$(cat /sys/fs/cgroup/pids.max)" = 64
test ! -e /sys/class/net/eth0
IFS= read -r line
test "$line" = 'pty-input'
if test -t 0; then
    printf 'PTY_MODE true\n'
else
    printf 'PTY_MODE false\n'
fi
printf 'PTY_INPUT_OK\n'
printf 'PTY_STDERR_OK\n' >&2
