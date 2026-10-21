hawkeye_signing_identity() {
    local task_root="$1"
    local task_pin="$task_root/.signing-identity"
    local task_selected="${HAWKEYE_SIGNING_IDENTITY:-}"
    local task_available
    local -a task_identities
    task_available="$(/usr/bin/security find-identity -v -p codesigning)" || return 1
    task_identities=("${(@f)$(print -r -- "$task_available" | /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) .*/\1/p')}")

    if [[ -z "$task_selected" && -f "$task_pin" ]]; then
        task_selected="$(< "$task_pin")" || return 1
        if [[ -z "$task_selected" ]]; then
            print -u2 "The signing identity pin is empty. Explicitly select a certificate with HAWKEYE_SIGNING_IDENTITY."
            return 1
        fi
    fi
    if [[ -z "$task_selected" ]]; then
        if (( ${#task_identities} != 1 )) || [[ -z "${task_identities[1]}" ]]; then
            print -u2 "Choose a signing certificate by setting HAWKEYE_SIGNING_IDENTITY to its SHA-1 fingerprint."
            print -u2 "List certificates with: security find-identity -v -p codesigning"
            return 1
        fi
        task_selected="${task_identities[1]}"
    fi
    task_selected="${task_selected:u}"
    if [[ ! "$task_selected" =~ '^[[:xdigit:]]{40}$' ]]; then
        print -u2 "The signing identity must be a certificate SHA-1 fingerprint. Ad-hoc signing is not supported."
        return 1
    fi
    if ! print -rl -- "${task_identities[@]}" | /usr/bin/grep -Fqx -- "$task_selected"; then
        print -u2 "The pinned signing identity is unavailable or invalid: $task_selected"
        print -u2 "Restore that identity or explicitly select another with HAWKEYE_SIGNING_IDENTITY."
        return 1
    fi
    print -r -- "$task_selected"
}

hawkeye_sign_app() {
    local task_bundle="$1"
    local task_identity="$2"
    /usr/bin/codesign --force --sign "$task_identity" --timestamp=none "$task_bundle" || return 1
    /usr/bin/codesign --verify --deep --strict "$task_bundle"
}
