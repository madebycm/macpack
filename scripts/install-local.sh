#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_dir=${script_dir:h}
cd "$repo_dir"

if [[ "${1:-}" != "--skip-build" ]]; then
    "$script_dir/build-pkg.sh"
fi

pkg=$(/usr/bin/find "$repo_dir/dist" -maxdepth 1 -name 'MacPack-*.pkg' \
    -type f -print | /usr/bin/sort | /usr/bin/tail -n 1)
if [[ -z "$pkg" || ! -f "$pkg" || "$pkg" != "$repo_dir"/dist/* ]]; then
    print -u2 "No MacPack package was found in $repo_dir/dist"
    exit 66
fi

print "macOS will ask once for administrator approval to install MacPack."
/usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" with administrator privileges' \
    -e 'end run' \
    "$pkg"

/usr/bin/codesign --verify --deep --strict --verbose=2 /Applications/MacPack.app
/bin/launchctl print system/com.macpack.installer >/dev/null
/usr/bin/open -g /Applications/MacPack.app --args --first-run --background
print "Installed /Applications/MacPack.app and enabled the on-demand installer service."
