#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
source "$task_root/scripts/signing.zsh"
task_signing_identity="$(hawkeye_signing_identity "$task_root")"
task_check_bundle="$task_root/.work/Hawkeye 2 Check.app"
mkdir -p "$task_root/.work"
if [[ ! -d "$task_root/dist/Hawkeye 2.app" ]]; then
    print -u2 "Run scripts/build-app.sh first."
    exit 1
fi
ditto "$task_root/dist/Hawkeye 2.app" "$task_check_bundle"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.hawkeye2.check' "$task_check_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Hawkeye 2 Check' "$task_check_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Hawkeye 2 Check' "$task_check_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :HawkeyeDataDirectory' "$task_check_bundle/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :HawkeyeDataDirectory string $task_root/.work/ui-data" "$task_check_bundle/Contents/Info.plist"
hawkeye_sign_app "$task_check_bundle" "$task_signing_identity"
print "Prepared $task_check_bundle"
