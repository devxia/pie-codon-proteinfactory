#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'Usage: sh Scripts/build-app.sh [--configuration debug|release] [--universal]'
}

configuration=debug
universal=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
            configuration=$2
            shift 2
            ;;
        --universal) universal=true; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$configuration" in
    debug|release) ;;
    *) usage >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
repo_dir=$(pwd -P)
output_dir="$repo_dir/.build/app/$configuration"
app_info=App/Info.plist
app_name="$(plutil -extract CFBundleDisplayName raw "$app_info").app"
app="$output_dir/$app_name"
product=$(plutil -extract CFBundleExecutable raw "$app_info")
mkdir -p "$output_dir"

# Keep assembly and replacement of this configuration serialized.
exec 9>"$output_dir/.build-app.lock"
if ! lockf -t 60 /dev/fd/9; then
    printf '%s\n' "Could not acquire the lock for the $configuration bundle." >&2
    exit 1
fi

build_product() {
    arch=$1
    scratch="$repo_dir/.build/app-swift/$arch"
    set -- --configuration "$configuration" --arch "$arch" --scratch-path "$scratch" \
        --build-system native --only-use-versions-from-resolved-file
    xcrun swift build "$@" --product "$product" >&2 || return
    bin_dir=$(xcrun swift build "$@" --show-bin-path) || return
    printf '%s\n' "$bin_dir/$product"
}

stage=$(mktemp -d "$output_dir/.assemble.XXXXXX")
cleanup() {
    status=$?
    if [ -e "$stage/previous.app" ] && [ ! -e "$app" ]; then
        if ! mv "$stage/previous.app" "$app"; then
            printf '%s\n' "Previous bundle retained at $stage/previous.app" >&2
            exit 1
        fi
    fi
    rm -rf "$stage"
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

staged_app="$stage/$app_name"
contents="$staged_app/Contents"
binary="$contents/MacOS/$product"
mkdir -p "$contents/MacOS" "$contents/Resources"
if [ "$universal" = true ]; then
    arm_product=$(build_product arm64)
    intel_product=$(build_product x86_64)
    xcrun lipo -create "$arm_product" "$intel_product" -output "$binary"
    xcrun lipo "$binary" -verify_arch arm64 x86_64
    chmod 755 "$binary"
    resource_arch=arm64
    resource_product=$arm_product
else
    native_arch=$(uname -m)
    swift_product=$(build_product "$native_arch")
    install -m 755 "$swift_product" "$binary"
    xcrun lipo "$binary" -verify_arch "$native_arch"
    resource_arch=$native_arch
    resource_product=$swift_product
fi

install -m 644 "$app_info" "$contents/Info.plist"
if [ "$configuration" = debug ]; then
    plutil -insert CodonProteinFactorySmokeTest -bool YES "$contents/Info.plist"
fi

ditto --norsrc --noextattr --noqtn --noacl App/Resources "$contents/Resources"
plist="$contents/Info.plist"
resources="$contents/Resources"
zip_bundle="$(dirname "$resource_product")/ZIPFoundation_ZIPFoundation.bundle"
zip_checkout="$repo_dir/.build/app-swift/$resource_arch/checkouts/ZIPFoundation"
install -m 644 "$zip_bundle/PrivacyInfo.xcprivacy" "$resources/PrivacyInfo.xcprivacy"
install -m 644 "$zip_checkout/LICENSE" "$resources/ZIPFoundation-LICENSE.txt"
plutil -lint "$plist" "$resources/PrivacyInfo.xcprivacy" \
    "$resources/en.lproj/Localizable.strings" "$resources/zh-Hans.lproj/Localizable.strings"
test -s "$resources/AppIcon.icns"
test -s "$resources/ZIPFoundation-LICENSE.txt"
test "$(plutil -extract CFBundleExecutable raw "$plist")" = "$product"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [ -e "$app" ] || [ -L "$app" ]; then
    mv "$app" "$stage/previous.app"
fi
mv "$staged_app" "$app"
printf '%s\n' "Built $app ($(xcrun lipo -archs "$app/Contents/MacOS/$product"))"
