#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

developer_dir=$(xcode-select -p)
case "$developer_dir" in
    */CommandLineTools)
        testing_frameworks="$developer_dir/Library/Developer/Frameworks"
        # Command Line Tools 6.2.4 ships Testing without its Foundation overlay module.
        set -- -Xswiftc "-F$testing_frameworks" \
            -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
            -Xlinker -rpath -Xlinker "$testing_frameworks" "$@"
        ;;
esac

exec xcrun swift test --build-system native --disable-xctest --only-use-versions-from-resolved-file "$@"
