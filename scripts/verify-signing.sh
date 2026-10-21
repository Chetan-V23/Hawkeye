#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
source "$task_root/scripts/signing.zsh"
task_identity="$(hawkeye_signing_identity "$task_root")"
mkdir -p "$task_root/.work"
task_temp="$(mktemp -d "$task_root/.work/signing-check.XXXXXX")"
trap 'rm -rf -- "$task_temp"' EXIT

for task_version in 1 2; do
    task_app="$task_temp/version-$task_version.app"
    mkdir -p "$task_app/Contents/MacOS"
    print -r -- "int main(void) { return $task_version; }" > "$task_temp/version-$task_version.c"
    /usr/bin/clang "$task_temp/version-$task_version.c" -o "$task_app/Contents/MacOS/SigningCheck"
    cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SigningCheck</string>
    <key>CFBundleIdentifier</key><string>com.hawkeye2.signing-check</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    hawkeye_sign_app "$task_app" "$task_identity"
done

task_first="$task_temp/version-1.app"
task_second="$task_temp/version-2.app"
if /usr/bin/cmp -s "$task_first/Contents/MacOS/SigningCheck" "$task_second/Contents/MacOS/SigningCheck"; then
    print -u2 "FAIL: the fixture executables must contain different code."
    exit 1
fi
task_requirement="$(/usr/bin/codesign -d -r- "$task_first" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
task_next_requirement="$(/usr/bin/codesign -d -r- "$task_second" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$task_requirement" && "$task_requirement" == "$task_next_requirement" ]]
[[ "$task_requirement" != *cdhash* ]]
/usr/bin/codesign --verify --strict -R "=$task_requirement" "$task_second"
print "PASS: different executable builds satisfy the same certificate-backed signing requirement."

/usr/bin/codesign --force --sign - "$task_second"
if /usr/bin/codesign --verify --strict -R "=$task_requirement" "$task_second" >/dev/null 2>&1; then
    print -u2 "FAIL: an ad-hoc replacement must not satisfy the certificate requirement."
    exit 1
fi
print "PASS: an ad-hoc replacement is rejected."

if HAWKEYE_SIGNING_IDENTITY=- hawkeye_signing_identity "$task_temp" >/dev/null 2>&1; then
    print -u2 "FAIL: ad-hoc signing must not be selectable."
    exit 1
fi
print -r -- "0000000000000000000000000000000000000000" > "$task_temp/.signing-identity"
if HAWKEYE_SIGNING_IDENTITY= hawkeye_signing_identity "$task_temp" >/dev/null 2>&1; then
    print -u2 "FAIL: a missing pinned identity must not fall back to another identity."
    exit 1
fi
: > "$task_temp/.signing-identity"
if HAWKEYE_SIGNING_IDENTITY= hawkeye_signing_identity "$task_temp" >/dev/null 2>&1; then
    print -u2 "FAIL: an empty identity pin must not silently select another identity."
    exit 1
fi
print -r -- "$task_identity" > "$task_temp/.signing-identity"
[[ "$(HAWKEYE_SIGNING_IDENTITY= hawkeye_signing_identity "$task_temp")" == "$task_identity" ]]
print "PASS: identity selection reuses its pin and fails on unavailable or ad-hoc identities."
