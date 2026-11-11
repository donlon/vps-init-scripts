#!/bin/bash

set -Eeuo pipefail
trap 'echo "Failed at $BASH_SOURCE:$LINENO: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" == "0" ]; then
    echo "Please run this script as non-root user"
    exit 1
fi

DIR=$(dirname -- "$0")
cd -- "$DIR"

source common.sh

setup_local_key() {
    mkdir -p ~/.gnupg/
    chmod 700 ~/.gnupg/
    cat > ~/.gnupg/key-params <<EOF
%echo Generating a basic OpenPGP key
Key-Type: eddsa
Key-Curve: Ed25519
Subkey-Type: ecdh
Subkey-Curve: Curve25519
Name-Real: $HOST_NAME
Name-Email: $HOST_EMAIL
Expire-Date: 0
%no-protection
%pubring $HOME/.gnupg/default.pub
%commit
%echo Public key saved to ~/.gnupg/default.pub
%echo done
EOF
    gpg --batch --generate-key ~/.gnupg/key-params
    echo "Local key for $HOST_NAME is:"
    gpg --show-keys --fingerprint ~/.gnupg/default.pub
}

setup_misc() {
    echo "Generating new ssh key"
    ssh-keygen -t ed25519 -f /home/admin/.ssh/id_ed25519 -N ''

    git config --global init.defaultBranch main
    git config --global user.name "$HOST_NAME"
    git config --global user.email "$HOST_EMAIL"
    git config --global credential.helper store

    SIGNING_KEY=$(gpg --show-keys --keyid-format=long --with-colons ~/.gnupg/default.pub | awk -F: '/^fpr/ {print $10}' | head -1)
    if [ -z "$SIGNING_KEY" ]; then
        echo "GPG signing key is not found."
    else
        git config --global commit.gpgsign true
        git config --global user.signingkey $SIGNING_KEY
    fi
}

setup_zsh
# TODO: chsh
setup_local_key
setup_misc
