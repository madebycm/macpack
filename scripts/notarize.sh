#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "usage: $0 /path/to/MacPack.pkg NOTARYTOOL_KEYCHAIN_PROFILE"
    exit 64
fi

pkg=${1:A}
profile=$2
if [[ ! -f "$pkg" || "$pkg" != *.pkg ]]; then
    print -u2 "not a package: $pkg"
    exit 66
fi
if ! /usr/bin/pkgutil --check-signature "$pkg" 2>&1 | /usr/bin/grep -q 'Developer ID Installer'; then
    print -u2 "the package must be signed with Developer ID Installer before notarization"
    exit 65
fi

/usr/bin/xcrun notarytool submit "$pkg" --keychain-profile "$profile" --wait
/usr/bin/xcrun stapler staple "$pkg"
/usr/bin/xcrun stapler validate "$pkg"
print "Notarized and stapled $pkg"
