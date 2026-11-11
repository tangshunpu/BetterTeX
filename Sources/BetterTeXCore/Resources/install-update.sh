#!/bin/sh
# Arguments, never shell interpolation, carry all installation paths.
set -u
umask 077
parent_pid="$1"
target="$2"
replacement="$3"
staging="$4"
result="$5"
opener="$6"
backup="$staging/previous.app"

# A cancelled or stalled quit must never replace an application that is still running.
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 1500 ]; then exit 1; fi
    /bin/sleep 0.2
done

# Recover the old app on every failed filesystem operation. Keep a backup if rollback itself fails.
fail() {
    printf 'failed\n' > "$result"
    if [ -d "$backup" ] && [ ! -e "$target" ]; then /bin/mv "$backup" "$target" || exit 1; fi
    if [ -d "$target" ]; then "$opener" -n "$target"; fi
    exit 1
}
[ -d "$target" ] && [ -d "$replacement" ] || fail
/bin/mv "$target" "$backup" || fail
[ ! -e "$target" ] || fail
/bin/mv "$replacement" "$target" || fail
printf 'installed\n' > "$result"
if ! "$opener" -n "$target"; then
    /bin/mv "$target" "$replacement" || fail
    fail
fi
/bin/rm -rf "$staging"
