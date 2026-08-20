#!/bin/zsh

set -euo pipefail
export COPYFILE_DISABLE=1

script_dir=${0:A:h}
repo_dir=${script_dir:h}
cd "$repo_dir"

if [[ "${1:-}" != "--skip-build" ]]; then
    "$script_dir/build-app.sh" --production
fi

app="$repo_dir/build/MacPack.app"
if [[ ! -d "$app" ]]; then
    print -u2 "MacPack.app is missing; run scripts/build-app.sh first"
    exit 66
fi

stage_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macpack-pkg.XXXXXX")
cleanup() {
    if [[ -n "${stage_root:-}" && -d "$stage_root" && "$stage_root" == *"/macpack-pkg."* ]]; then
        /bin/rm -rf -- "$stage_root"
    fi
}
trap cleanup EXIT

payload="$stage_root/payload"
/bin/mkdir -p \
    "$payload/Applications" \
    "$payload/Library/PrivilegedHelperTools" \
    "$payload/Library/LaunchDaemons" \
    "$payload/Library/Application Support/MacPack"

/usr/bin/ditto --norsrc --noextattr "$app" "$payload/Applications/MacPack.app"
/bin/cp -X "$app/Contents/Library/HelperTools/MacPackInstaller" \
    "$payload/Library/PrivilegedHelperTools/com.macpack.installer"
/bin/cp -X "$repo_dir/Resources/com.macpack.installer.legacy.plist" \
    "$payload/Library/LaunchDaemons/com.macpack.installer.plist"
/bin/cp -X "$app/Contents/Resources/ClientRequirement.txt" \
    "$payload/Library/Application Support/MacPack/client.requirement"
/bin/chmod 0755 "$payload/Library/PrivilegedHelperTools/com.macpack.installer"
/bin/chmod 0644 \
    "$payload/Library/LaunchDaemons/com.macpack.installer.plist" \
    "$payload/Library/Application Support/MacPack/client.requirement"
/usr/bin/xattr -cr "$payload"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app/Contents/Info.plist")
dist_dir="$repo_dir/dist"
output="$dist_dir/MacPack-$version.pkg"
/bin/mkdir -p "$dist_dir"
if [[ -L "$dist_dir" || -L "$output" || "$output" != "$repo_dir"/dist/* ]]; then
    print -u2 "refusing unsafe package target: $output"
    exit 70
fi

unsigned="$stage_root/MacPack-unsigned.pkg"
/usr/bin/pkgbuild \
    --root "$payload" \
    --scripts "$repo_dir/Packaging/Scripts" \
    --component-plist "$repo_dir/Packaging/component.plist" \
    --identifier com.macpack.pkg \
    --version "$version" \
    --ownership recommended \
    "$unsigned"

if [[ -n "${INSTALLER_SIGNING_IDENTITY:-}" ]]; then
    /usr/bin/productsign --sign "$INSTALLER_SIGNING_IDENTITY" "$unsigned" "$stage_root/MacPack.pkg"
else
    /bin/mv "$unsigned" "$stage_root/MacPack.pkg"
fi

if [[ -e "$output" ]]; then
    /bin/rm -f -- "$output"
fi
/bin/mv "$stage_root/MacPack.pkg" "$output"
/usr/sbin/pkgutil --check-signature "$output" || true
print "Built $output"
