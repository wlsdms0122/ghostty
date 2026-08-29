#!/bin/bash
# Build, install and distribute the fork.
#
# Usage:
#   .jsilver/build.sh build [--debug]     build Ghostty.app
#   .jsilver/build.sh install [--debug]   build, then replace /Applications/Ghostty.app
#   .jsilver/build.sh dist <profile>      sign, notarize and zip a release build
#
# `dist` needs the owner's Developer ID certificate in the login keychain and a
# notarytool keychain profile; the other two need only mise and Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="Developer ID Application: Jin Eun Jeong (6VSLC69397)"

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | cut -c 3-
    exit "${1:-1}"
}

# Zig comes from mise so every machine builds with the pinned version. A fresh
# clone's mise.toml is untrusted until it is named explicitly.
zig() {
    command -v mise >/dev/null || {
        echo "mise not found: https://mise.jdx.dev" >&2
        exit 1
    }
    mise trust --quiet "$ROOT/mise.toml"
    (cd "$ROOT" && mise x -- zig "$@")
}

# The app is two builds: the Zig core as an xcframework, then the Xcode target
# that embeds it. ReleaseLocal is upstream's release configuration without the
# CI-only signing.
build() {
    local configuration="$1" optimize="$2"

    zig build "-Doptimize=$optimize" -Demit-macos-app=false
    (cd "$ROOT/macos" && xcodebuild -target Ghostty -configuration "$configuration")
}

app_path() {
    echo "$ROOT/macos/build/$1/Ghostty.app"
}

# Distribution signing, mirroring upstream's release-tag.yml minus the CI
# keychain dance and the DMG. Order is inside-out: a signature over a bundle
# whose contents change afterwards is void.
dist() {
    local profile="$1"
    local app zip version sparkle
    app="$(app_path ReleaseLocal)"

    [ -d "$app" ] || {
        echo "no release build at $app — run: $0 build" >&2
        exit 1
    }

    version="$("$app/Contents/MacOS/ghostty" --version | head -1 | awk '{print $2}')"
    zip="$ROOT/Ghostty-${version}-macos-universal.zip"
    sparkle="$app/Contents/Frameworks/Sparkle.framework"

    # The XPC services are unused (Ghostty is not sandboxed) but ship in the
    # bundle, so they are signed too.
    local target
    for target in \
        "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/B/Autoupdate" \
        "$sparkle/Versions/B/Updater.app" \
        "$sparkle" \
        "$app/Contents/PlugIns/DockTilePlugin.plugin"
    do
        /usr/bin/codesign --verbose -f -s "$IDENTITY" -o runtime "$target"
    done

    /usr/bin/codesign --verbose -f -s "$IDENTITY" -o runtime \
        --entitlements "$ROOT/macos/Ghostty.entitlements" "$app"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

    # Notarization takes a zip, but the staple lands on the bundle, so the
    # shipping archive is the one built after stapling.
    rm -f "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"

    rm -f "$zip"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

    spctl -a -vvv -t install "$app"
    echo "ready: $zip"
}

command="${1:-}"
[ $# -gt 0 ] && shift

case "$command" in
    build|install)
        configuration=ReleaseLocal
        optimize=ReleaseFast
        if [ "${1:-}" = "--debug" ]; then
            configuration=Debug
            optimize=Debug
            shift
        fi
        [ $# -eq 0 ] || usage

        build "$configuration" "$optimize"
        app="$(app_path "$configuration")"

        if [ "$command" = install ]; then
            # Replaced rather than merged: leftovers from an older bundle would
            # be signed for nothing and shipped forever.
            rm -rf /Applications/Ghostty.app
            ditto "$app" /Applications/Ghostty.app
            app=/Applications/Ghostty.app
        fi

        echo "ready: $app"
        ;;
    dist)
        [ $# -eq 1 ] || usage
        dist "$1"
        ;;
    -h|--help|help)
        usage 0
        ;;
    *)
        usage
        ;;
esac
