#!/bin/zsh

set -euo pipefail

repo_dir=${0:A:h}
cd "$repo_dir"

current=$(/bin/cat "$repo_dir/.CM_DEV_BUILD")
next=$(print -r -- "$current" | /usr/bin/awk 'BEGIN { FS=OFS="." } { $NF += 1; print }')
print -r -- "$next" > "$repo_dir/.CM_DEV_BUILD"

/usr/bin/pkill -x MacPack >/dev/null 2>&1 || true
"$repo_dir/scripts/build-app.sh" --dev
/usr/bin/open -n "$repo_dir/build/MacPack.app"

print "MacPack dev build $next is running. Streaming logs; press Ctrl-C to stop."
exec /usr/bin/log stream --style compact \
    --predicate 'process == "MacPack" OR process == "MacPackInstaller"'
