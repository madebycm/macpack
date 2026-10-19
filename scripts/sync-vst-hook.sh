#!/bin/zsh

set -euo pipefail
export COPYFILE_DISABLE=1

script_dir=${0:A:h}
repo_dir=${script_dir:h}
source_dir=${1:-${repo_dir:h}/scripts/vstcleaner}
target_dir="$repo_dir/Resources/PostHooks/VSTCleanup"

files=(
    vst_cleaner.py
    specifics/__init__.py
    specifics/ableton_dedup.py
    specifics/broken.py
    specifics/fabfilter.py
    specifics/m4l.py
    specifics/revoice.py
    specifics/usage.py
)

for relative_path in $files; do
    if [[ ! -f "$source_dir/$relative_path" ]]; then
        print -u2 "missing canonical cleaner file: $source_dir/$relative_path"
        exit 66
    fi
done

/bin/mkdir -p "$target_dir/specifics"
for relative_path in $files; do
    /bin/cp -X "$source_dir/$relative_path" "$target_dir/$relative_path"
done

(
    cd "$target_dir"
    /usr/bin/shasum -a 256 $files > SNAPSHOT.sha256
)

print "Synced the canonical VST cleaner from $source_dir"
