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
wait_attempts="${7:-1500}"
backup="$staging/previous.app"
old_moved=0
new_moved=0
printf '%s\n' "$$" > "$staging/installer.pid" || exit 1

# A cancelled or stalled quit must never replace an application that is still running.
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$wait_attempts" ]; then
        # No swap has started, so only the unused staged copy is being removed.
        if [ ! -e "$backup" ]; then /bin/rm -rf "$staging"; fi
        exit 1
    fi
    /bin/sleep 0.2
done

# A failed rollback must never reopen the new application or claim the old one was restored.
recovery_required() {
    printf 'recovery-required\n%s\n' "$backup" > "$result"
    exit 1
}
fail() {
    if [ "$old_moved" -eq 1 ]; then
        if [ -e "$target" ]; then
            [ "$new_moved" -eq 1 ] && [ ! -e "$replacement" ] || recovery_required
            /bin/mv "$target" "$replacement" || recovery_required
        fi
        /bin/mv "$backup" "$target" || recovery_required
    fi
    printf 'failed\n' > "$result"
    if [ -d "$target" ]; then "$opener" -n "$target"; fi
    exit 1
}
[ -d "$target" ] && [ -d "$replacement" ] || fail
/bin/mv "$target" "$backup" || fail
old_moved=1
[ ! -e "$target" ] || fail
/bin/mv "$replacement" "$target" || fail
new_moved=1
printf 'installed\n' > "$result"
"$opener" -n "$target" || fail
/bin/rm -rf "$staging"
