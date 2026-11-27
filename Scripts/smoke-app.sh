#!/bin/sh
set -eu

usage() {
    printf '%s\n' "Usage: sh Scripts/smoke-app.sh --app '/path/to/Codon ProteinFactory.app'"
}

if [ "$#" -eq 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
if [ "$#" -ne 2 ] || [ "$1" != --app ]; then usage >&2; exit 2; fi
app=$(cd -- "$2" && pwd -P)
plist="$app/Contents/Info.plist"
if [ "$(plutil -extract CodonProteinFactorySmokeTest raw "$plist" 2>/dev/null)" != true ]; then
    printf '%s\n' 'The startup check requires a Debug app from Scripts/build-app.sh.' >&2
    exit 2
fi
codesign --verify --deep --strict "$app"

results=$(mktemp -d "${TMPDIR:-/tmp}/cpf-smoke.XXXXXX")
launcher_pid=
cleanup() {
    if [ -n "$launcher_pid" ]; then kill "$launcher_pid" 2>/dev/null || true; fi
    rm -rf "$results"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

cd /tmp
open -n -g -W "$app" --args --smoke-test "$results" >"$results/launch.log" 2>&1 &
launcher_pid=$!
deadline=$(( $(date +%s) + 25 ))
while kill -0 "$launcher_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '%s\n' 'The startup check timed out.' >&2
        cat "$results/launch.log" >&2
        exit 1
    fi
    sleep 0.2
done
launch_status=0
wait "$launcher_pid" || launch_status=$?
launcher_pid=

if [ "$launch_status" -ne 0 ] || [ ! -f "$results/result" ]; then
    printf '%s\n' 'Launch Services did not return a startup check result.' >&2
    cat "$results/launch.log" >&2
    exit 1
fi
result=$(cat "$results/result")
case "$result" in
    'PASS '*) printf '%s\n' "$result" ;;
    *) printf '%s\n' "$result" >&2; exit 1 ;;
esac
