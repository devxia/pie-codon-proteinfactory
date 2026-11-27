#!/bin/sh
set -eu

usage() {
    cat <<'EOF'
Usage: sh Scripts/release-dmg.sh --app PATH --local [--output DIR]
       sh Scripts/release-dmg.sh --app PATH --identity SHA1 --bundle-id ID --notary-profile NAME [--output DIR]

--local creates a sandboxed, ad hoc signed DMG for local testing.
The release path uses an installed Developer ID Application identity and a stored notarytool profile.
Run from a macOS desktop session with permission to automate Finder.
Both modes create Pie-Codon-ProteinFactory-<version>-macos-universal.dmg in the project's dist directory by default.
Rebuilding a version updates its DMG after verification. Use --output DIR to write to a new directory.
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")" && pwd -P)
app=
output=
identity=
bundle_id=
profile=
local_build=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app|--output|--identity|--bundle-id|--notary-profile)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "Missing value for $1."
            case "$1" in
                --app) app=$2 ;;
                --output) output=$2 ;;
                --identity) identity=$2 ;;
                --bundle-id) bundle_id=$2 ;;
                --notary-profile) profile=$2 ;;
            esac
            shift 2
            ;;
        --local) local_build=true; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$app" ] || fail 'Pass the universal Release bundle with --app.'
if [ "$local_build" = true ]; then
    [ -z "$identity$bundle_id$profile" ] || fail 'Use --local by itself or supply the release credentials.'
else
    [ -n "$identity" ] && [ -n "$bundle_id" ] && [ -n "$profile" ] || fail 'Supply --identity, --bundle-id, and --notary-profile.'
    case "$identity" in *[!0-9A-Fa-f]*) fail 'Pass the hexadecimal SHA-1 of the Developer ID Application identity.' ;; esac
    [ "${#identity}" -eq 40 ] || fail 'Pass the 40-character SHA-1 of the Developer ID Application identity.'
    case "$bundle_id" in
        com.example.*|*[!a-zA-Z0-9.-]*|.*|*.|*..*) fail 'Pass the team’s reverse-DNS bundle identifier.' ;;
        *.*) ;;
        *) fail 'Pass the team’s reverse-DNS bundle identifier.' ;;
    esac
    if ! security find-identity -v -p codesigning | awk -v id="$identity" '
        toupper($2) == toupper(id) && /"Developer ID Application:/ { found = 1 }
        END { exit !found }
    '; then
        fail 'The specified Developer ID Application signing identity is unavailable.'
    fi
fi

app=$(cd -- "$app" && pwd -P)
plist="$app/Contents/Info.plist"
resources="$app/Contents/Resources"
# The SwiftPM assembly contains one executable and resources. Embedded code needs its own signing step.
embedded=$(find "$app/Contents" \( -name '*.app' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' -o -name '*.framework' \) -print)
[ -z "$embedded" ] || fail 'Embedded code requires explicit signing before packaging.'
plutil -lint "$plist" "$resources/PrivacyInfo.xcprivacy" "$resources/en.lproj/Localizable.strings" \
    "$resources/zh-Hans.lproj/Localizable.strings" "$script_dir/../App/Release.entitlements"
if plutil -extract CodonProteinFactorySmokeTest raw "$plist" >/dev/null 2>&1; then fail 'Build a Release bundle with no Debug smoke entry.'; fi
app_info="$script_dir/../App/Info.plist"
app_name=$(plutil -extract CFBundleDisplayName raw "$app_info")
product=$(plutil -extract CFBundleExecutable raw "$app_info")
[ "$(plutil -extract CFBundleDisplayName raw "$plist")" = "$app_name" ] &&
    [ "$(plutil -extract CFBundleName raw "$plist")" = "$app_name" ] || fail 'Unexpected app display name.'
[ "$(plutil -extract CFBundleExecutable raw "$plist")" = "$product" ] || fail 'Unexpected app executable.'
[ -s "$resources/AppIcon.icns" ] && [ -s "$resources/ZIPFoundation-LICENSE.txt" ] || fail 'Missing required app resources.'
xcrun lipo "$app/Contents/MacOS/$product" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$app"
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
case "$version" in ''|*[!0-9.]*) fail 'Expected a numeric app version.' ;; esac
filename="Pie-Codon-ProteinFactory-$version-macos-universal.dmg"
publish_to_dist=false
checksum_file=SHA256SUMS
receipt_file=notarization.json
if [ -z "$output" ]; then
    publish_to_dist=true
    output="$(cd "$script_dir/.." && pwd -P)/dist"
    checksum_file="$filename.sha256"
    receipt_file="$filename.notarization.json"
    mkdir -p "$output"
    exec 9>"$output/.release-dmg.lock"
    lockf -t 60 /dev/fd/9 || fail "Could not acquire the packaging lock for $output."
    staging_parent="$output"
else
    case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
    staging_parent=$(dirname "$output")
    mkdir -p "$staging_parent"
    [ ! -e "$output" ] && [ ! -L "$output" ] || fail "Output already exists at $output."
fi
stage=$(mktemp -d "$staging_parent/.cpf-release.XXXXXX")
mount_dir="$stage/mount"
cleanup() {
    if [ -d "$mount_dir/.background" ] && ! hdiutil detach "$mount_dir"; then
        printf '%s\n' "Could not detach $mount_dir. Staging files were retained." >&2
        return 1
    fi
    rm -rf "$stage"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
mkdir "$stage/volume" "$stage/artifacts" "$mount_dir" "$stage/volume/.background"
staged_app="$stage/volume/$app_name.app"
ditto --norsrc --noextattr --noqtn --noacl "$app" "$staged_app"
ln -s /Applications "$stage/volume/Applications"

entitlements="$script_dir/../App/Release.entitlements"
if [ "$local_build" = true ]; then
    codesign --force --sign - --entitlements "$entitlements" "$staged_app"
else
    plutil -replace CFBundleIdentifier -string "$bundle_id" "$staged_app/Contents/Info.plist"
    codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"
codesign --display --entitlements :- "$staged_app" > "$stage/signed.entitlements"
for entitlement in com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.network.client; do
    [ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$stage/signed.entitlements")" = true ] || fail "Missing entitlement $entitlement."
done

xcrun swiftc "$script_dir/dmg-background.swift" -o "$stage/dmg-background"
"$stage/dmg-background" "$stage/volume/.background/Installer.png"

# Finder writes the view settings to the writable image before it is compressed.
writable_image="$stage/installer.dmg"
hdiutil create -srcfolder "$stage/volume" -volname "$app_name $version" -fs HFS+ -format UDRW "$writable_image"
hdiutil attach -noautoopen -mountpoint "$mount_dir" "$writable_image"
osascript "$script_dir/dmg-layout.applescript" "$mount_dir" "$app_name.app"
[ -s "$mount_dir/.DS_Store" ] || fail 'Finder did not save the installer layout.'
hdiutil detach "$mount_dir"

image="$stage/artifacts/$filename"
hdiutil convert "$writable_image" -format UDZO -o "$image"
if [ "$local_build" = false ]; then
    codesign --sign "$identity" --timestamp "$image"
    codesign --verify --strict "$image"
    receipt="$stage/artifacts/$receipt_file"
    if ! xcrun notarytool submit "$image" --keychain-profile "$profile" --wait --output-format json > "$receipt"; then
        cat "$receipt" >&2
        fail 'The notarization request failed.'
    fi
    if [ "$(plutil -extract status raw "$receipt")" != Accepted ]; then
        cat "$receipt" >&2
        fail 'The notarization request was not accepted.'
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
fi
hdiutil verify "$image"
(cd "$stage/artifacts" && shasum -a 256 "$filename" > "$checksum_file" && shasum -a 256 -c "$checksum_file")
if [ "$publish_to_dist" = true ]; then
    for artifact in "$stage/artifacts/"*; do
        destination="$output/${artifact##*/}"
        [ ! -d "$destination" ] || fail "Output path is a directory at $destination."
    done
    if [ "$local_build" = true ] && [ -f "$output/$receipt_file" ]; then
        rm -f "$output/$receipt_file"
    fi
    mv -f "$stage/artifacts/"* "$output/"
else
    [ ! -e "$output" ] && [ ! -L "$output" ] || fail "Output already exists at $output."
    mv "$stage/artifacts" "$output"
fi
printf '%s\n' "Packaged $output/$filename"
