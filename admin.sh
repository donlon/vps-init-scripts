#!/bin/bash

set -Eeuo pipefail
umask 077
trap 'echo "Failed at $BASH_SOURCE:$LINENO: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" == "0" ]; then
    echo "Please run this script as non-root user"
    exit 1
fi

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/common.sh"
load_host_config "${1:-$DIR/host.conf}"
source "$DIR/zsh.sh"
cd -- "$DIR"

setup_local_key() {
    mkdir -p ~/.gnupg/
    chmod 700 ~/.gnupg/
    if ! SIGNING_KEY=$(gpg --batch --with-colons --list-secret-keys "$HOST_EMAIL" 2>/dev/null |
        awk -F: '$1 == "fpr" && !found {print $10; found = 1}'); then
        SIGNING_KEY=
    fi
    if [ -z "$SIGNING_KEY" ]; then
        local key_params
        key_params=$(mktemp "$HOME/.gnupg/key-params.XXXXXX")
        cat > "$key_params" <<EOF
%echo Generating a basic OpenPGP key
Key-Type: eddsa
Key-Curve: Ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: $HOST_NAME
Name-Email: $HOST_EMAIL
Expire-Date: 0
%no-protection
%commit
%echo done
EOF
        gpg --batch --generate-key "$key_params"
        rm -- "$key_params"
        SIGNING_KEY=$(gpg --batch --with-colons --list-secret-keys "$HOST_EMAIL" |
            awk -F: '$1 == "fpr" && !found {print $10; found = 1}')
    fi
    if [ -z "$SIGNING_KEY" ]; then
        echo 'GPG signing key is not found.' >&2
        return 1
    fi
    gpg --batch --yes --output "$HOME/.gnupg/default.pub" --export "$SIGNING_KEY"
    echo "Local key for $HOST_NAME is:"
    gpg --show-keys --fingerprint ~/.gnupg/default.pub
}

setup_misc() {
    echo "Generating new ssh key"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ''
    fi

    git config --global init.defaultBranch main
    git config --global user.name "$HOST_NAME"
    git config --global user.email "$HOST_EMAIL"
    git config --global commit.gpgsign true
    git config --global user.signingkey "$SIGNING_KEY"
}

setup_zsh
# TODO: chsh
setup_local_key
setup_misc
