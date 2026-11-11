#!/bin/bash
# Safe local checks: never invoke the provisioning entrypoints.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/vps-init-tests.XXXXXX")
cleanup() {
    if [ -n "${GPG_TEST_HOME:-}" ]; then
        gpgconf --homedir "$GPG_TEST_HOME" --kill gpg-agent 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT

for file in "$ROOT"/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$file"
done
echo 'PASS: Bash syntax'

source "$ROOT/common.sh"
DIR=$ROOT
printf 'HOST_NAME=test.example.com\nHOST_EMAIL=test@example.com\n' > "$work/host.conf"
load_host_config "$work/host.conf"
[ "$HOST_NAME" = test.example.com ]
[ "$HOST_EMAIL" = test@example.com ]
if (load_host_config "$work/missing.conf") 2>/dev/null; then
    echo 'FAIL: missing config accepted' >&2; exit 1
fi
printf 'HOST_NAME="bad name"\nHOST_EMAIL=invalid\n' > "$work/invalid.conf"
if (load_host_config "$work/invalid.conf") 2>/dev/null; then
    echo 'FAIL: invalid config accepted' >&2; exit 1
fi
echo 'PASS: host configuration validation'

# Run only the key/dependency preflight, never the provisioning entrypoint.
sed -n '/^# Check access/,/^update_user_pwd () {/p' "$ROOT/main.sh" |
    sed '$d' > "$work/preflight.sh"
mkdir "$work/access"
if DIR="$work/access" bash -e "$work/preflight.sh" > "$work/preflight.log" 2>&1; then
    echo 'FAIL: missing authorized_keys accepted' >&2; exit 1
fi
grep -q 'Missing or empty' "$work/preflight.log"
touch "$work/access/authorized_keys"
if DIR="$work/access" bash -e "$work/preflight.sh" > "$work/preflight.log" 2>&1; then
    echo 'FAIL: empty authorized_keys accepted' >&2; exit 1
fi
printf 'not a public key\n' > "$work/access/authorized_keys"
if DIR="$work/access" bash -e "$work/preflight.sh" > "$work/preflight.log" 2>&1; then
    echo 'FAIL: malformed authorized_keys accepted' >&2; exit 1
fi
grep -q 'not a public key file' "$work/preflight.log"
echo 'PASS: missing, empty, and invalid authorized_keys rejected'

# Extract function definitions only, without root checks or setup calls.
sed -n '/^update_user_pwd () {/,/^# TODO: prompt hostname/p' "$ROOT/main.sh" > "$work/main-functions.sh"
source "$work/main-functions.sh"
openssl() { printf 'abc/+DEF=xyz\n'; }
chpasswd() {
    if [ "${PASSWORD_FAIL:-0}" = 1 ]; then return 1; fi
    cat > "$work/password-input"
}
output=$(update_user_pwd admin)
[ "$(cat "$work/password-input")" = 'admin:abcDEFxyz' ]
[ "$output" = 'New password for admin is abcDEFxyz' ]
export -f openssl chpasswd update_user_pwd
if output=$(PASSWORD_FAIL=1 bash -e -o pipefail -c 'update_user_pwd admin'); then
    echo 'FAIL: password update failure ignored' >&2; exit 1
fi
[ -z "$output" ]
unset -f openssl chpasswd
echo 'PASS: password filtering, setting, display, and failure propagation'

(
    # Exercise both installer and rerun paths with no network or real dotfiles.
    export HOME="$work/zsh-home"
    unset ZSH ZSH_CUSTOM XDG_CACHE_HOME
    mkdir -p "$HOME"
    curl() {
        local destination=${!#}
        cat > "$destination" <<'INSTALLER'
set -eu
[ "$RUNZSH" = no ]
[ "$CHSH" = no ]
[ "$KEEP_ZSHRC" = yes ]
[ "$1" = --unattended ]
mkdir -p "$ZSH/templates"
printf 'source "$ZSH/oh-my-zsh.sh"\n' > "$ZSH/templates/zshrc.zsh-template"
touch "$ZSH/oh-my-zsh.sh"
INSTALLER
    }
    git() { mkdir -p -- "${!#}"; }
    source "$ROOT/zsh.sh"
    setup_zsh
    cp "$HOME/.zshrc" "$work/first.zshrc"
    setup_zsh
    cmp "$work/first.zshrc" "$HOME/.zshrc"
    bash -n "$HOME/.zshrc"
    [ "$(grep -c '^# BEGIN vps-init$' "$HOME/.zshrc")" = 1 ]
    grep -qxF "alias t='tree -a'" "$HOME/.zshrc"
)
echo 'PASS: unattended Zsh installation and idempotent rc generation'

# Real GPG and SSH key generation is confined to a disposable home directory.
if command -v gpg >/dev/null && command -v gpgconf >/dev/null && command -v ssh-keygen >/dev/null; then
    export HOME="$work/admin-home"
    mkdir -p "$HOME"
    GPG_TEST_HOME="$HOME/.gnupg"
    gpg() { command gpg --homedir "$GPG_TEST_HOME" "$@"; }
    awk '/^setup_local_key\(\)/ {capture = 1} /^setup_zsh$/ {exit} capture {print}' \
        "$ROOT/admin.sh" > "$work/admin-functions.sh"
    source "$work/admin-functions.sh"
    setup_local_key
    first_key=$SIGNING_KEY
    setup_local_key
    [ "$SIGNING_KEY" = "$first_key" ]
    setup_misc
    first_ssh_key=$(sha256sum "$HOME/.ssh/id_ed25519")
    setup_misc
    [ "$(sha256sum "$HOME/.ssh/id_ed25519")" = "$first_ssh_key" ]
    [ "$(git config --global user.signingkey)" = "$first_key" ]
    [ "$(git config --global user.email)" = "$HOST_EMAIL" ]
    echo 'PASS: real disposable GPG export, Git signing config, and SSH key reuse'
else
    echo 'SKIP: disposable key tests require gpg, gpgconf, and ssh-keygen'
fi

echo 'All smoke tests passed (no system provisioning performed).'
