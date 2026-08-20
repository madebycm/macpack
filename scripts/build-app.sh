#!/bin/zsh

set -euo pipefail
export COPYFILE_DISABLE=1

script_dir=${0:A:h}
repo_dir=${script_dir:h}
mode="production"

case "${1:-}" in
    ""|--production) mode="production" ;;
    --dev) mode="dev" ;;
    *) print -u2 "usage: $0 [--production|--dev]"; exit 64 ;;
esac

configuration="release"
[[ "$mode" == "dev" ]] && configuration="debug"

cd "$repo_dir"
/usr/bin/swift build -c "$configuration"
bin_dir=$(/usr/bin/swift build -c "$configuration" --show-bin-path)

stage_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macpack-app.XXXXXX")
cleanup() {
    if [[ -n "${stage_root:-}" && -d "$stage_root" && "$stage_root" == *"/macpack-app."* ]]; then
        /bin/rm -rf -- "$stage_root"
    fi
}
trap cleanup EXIT

app="$stage_root/MacPack.app"
contents="$app/Contents"
/bin/mkdir -p \
    "$contents/MacOS" \
    "$contents/Resources" \
    "$contents/Library/HelperTools" \
    "$contents/Library/LaunchDaemons"

/bin/cp -X "$bin_dir/MacPack" "$contents/MacOS/MacPack"
/bin/cp -X "$bin_dir/MacPackInstaller" "$contents/Library/HelperTools/MacPackInstaller"
/bin/cp -X "$repo_dir/Resources/Info.plist" "$contents/Info.plist"
/bin/cp -X "$repo_dir/Resources/com.macpack.installer.plist" \
    "$contents/Library/LaunchDaemons/com.macpack.installer.plist"
/bin/cp -X "$repo_dir/Resources/ClientRequirement.txt" \
    "$contents/Resources/ClientRequirement.txt"
/bin/chmod 0755 "$contents/MacOS/MacPack" "$contents/Library/HelperTools/MacPackInstaller"

version=${MACPACK_VERSION:-0.1.0}
bundle_version=${MACPACK_BUILD_NUMBER:-1}
dev_build=""
[[ "$mode" == "dev" ]] && dev_build=$(/bin/cat "$repo_dir/.CM_DEV_BUILD")
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$bundle_version" "$contents/Info.plist"
/usr/bin/plutil -replace MacPackDevBuild -string "$dev_build" "$contents/Info.plist"

icon_work="$stage_root/icon-work"
iconset="$icon_work/AppIcon.iconset"
/bin/mkdir -p "$iconset"
if /usr/bin/qlmanage -t -s 1024 -o "$icon_work" "$repo_dir/Assets/AppIcon.svg" >/dev/null 2>&1; then
    source_png=$(/usr/bin/find "$icon_work" -maxdepth 1 -name '*.png' -print -quit)
    if [[ -n "$source_png" ]]; then
        for size in 16 32 128 256 512; do
            /usr/bin/sips -z "$size" "$size" "$source_png" \
                --out "$iconset/icon_${size}x${size}.png" >/dev/null
            doubled=$((size * 2))
            /usr/bin/sips -z "$doubled" "$doubled" "$source_png" \
                --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
        done
        /usr/bin/iconutil -c icns "$iconset" -o "$contents/Resources/AppIcon.icns"
    fi
fi

sign_identity=${CODESIGN_IDENTITY:-}
if [[ -z "$sign_identity" ]]; then
    sign_identity=$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -F '"' 'NF >= 2 { print $2; exit }')
fi
if [[ -z "$sign_identity" ]]; then
    sign_identity="-"
    print -u2 "warning: no signing identity found; using an ad-hoc development signature"
fi

timestamp_option="--timestamp=none"
[[ "$sign_identity" == Developer\ ID\ Application:* ]] && timestamp_option="--timestamp"

/usr/bin/codesign --force --sign "$sign_identity" --identifier com.macpack.installer \
    --options runtime "$timestamp_option" \
    "$contents/Library/HelperTools/MacPackInstaller"
/usr/bin/codesign --force --deep --sign "$sign_identity" --identifier com.macpack.app \
    --options runtime "$timestamp_option" "$app"

raw_requirement=$(/usr/bin/codesign -d -r- "$app" 2>&1)
client_requirement=${raw_requirement##*designated => }
if [[ -z "$client_requirement" || "$client_requirement" == *"cdhash"* ]]; then
    client_requirement='identifier "com.macpack.app"'
fi
print -r -- "$client_requirement" > "$contents/Resources/ClientRequirement.txt"

/usr/bin/codesign --force --deep --sign "$sign_identity" --identifier com.macpack.app \
    --options runtime "$timestamp_option" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/plutil -lint "$contents/Info.plist" \
    "$contents/Library/LaunchDaemons/com.macpack.installer.plist"

build_dir="$repo_dir/build"
target_app="$build_dir/MacPack.app"
/bin/mkdir -p "$build_dir"
if [[ -L "$build_dir" || -L "$target_app" || "$target_app" != "$repo_dir"/build/* ]]; then
    print -u2 "refusing unsafe build target: $target_app"
    exit 70
fi
if [[ -e "$target_app" ]]; then
    /bin/rm -rf -- "$target_app"
fi
/bin/mv "$app" "$target_app"

print "Built $target_app"
