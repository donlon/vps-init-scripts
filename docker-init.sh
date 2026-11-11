#!/bin/bash

set -Eeuo pipefail
trap 'echo "Failed at $BASH_SOURCE:$LINENO: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" = "0" ]; then
    echo "Please run this script as non-root user"
    exit 1
fi

if ! command -v apt-get >/dev/null || ! command -v systemctl >/dev/null; then
    echo 'This script requires an apt-based Linux host running systemd.' >&2
    exit 1
fi
user_name=$(id -un)
user_id=$(id -u)
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$user_id}
if [ ! -d "$XDG_RUNTIME_DIR" ] || [ ! -O "$XDG_RUNTIME_DIR" ] ||
    ! systemctl --user show-environment >/dev/null; then
    echo 'Log in directly as this user over SSH so a systemd user session exists, then rerun.' >&2
    exit 1
fi
for mapping in /etc/subuid /etc/subgid; do
    if ! awk -F: -v user="$user_name" -v uid="$user_id" \
        '($1 == user || $1 == uid) && $3 >= 65536 {found = 1} END {exit !found}' "$mapping"; then
        echo "Assign at least 65536 non-overlapping subordinate IDs to $user_name in $mapping, then rerun." >&2
        exit 1
    fi
done
if [ "$(cat /proc/sys/user/max_user_namespaces)" -eq 0 ] ||
    { [ -f /proc/sys/kernel/unprivileged_userns_clone ] &&
        [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" -eq 0 ]; }; then
    echo 'Rootless Docker requires unprivileged user namespaces to be enabled.' >&2
    exit 1
fi
sudo apt-get update
sudo apt-get install -y ca-certificates curl uidmap dbus-user-session slirp4netns fuse-overlayfs
if ! command -v docker >/dev/null; then
    installer=$(mktemp)
    curl -fsSL https://get.docker.com/ -o "$installer"
    sh "$installer"
    rm -- "$installer"
fi
if ! command -v dockerd-rootless-setuptool.sh >/dev/null; then
    echo 'Install the official Docker docker-ce-rootless-extras package, then rerun.' >&2
    exit 1
fi
sudo loginctl enable-linger "$user_name"
dockerd-rootless-setuptool.sh install --force
systemctl --user enable --now docker.service
# Always target rootless Docker, regardless of inherited Docker environment.
unset DOCKER_HOST DOCKER_CONTEXT
docker --context rootless info --format '{{json .SecurityOptions}}' | grep -q rootless

if docker --context rootless network inspect inet >/dev/null 2>&1; then
    subnet=$(docker --context rootless network inspect inet --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
    driver=$(docker --context rootless network inspect inet --format '{{.Driver}}')
    attachable=$(docker --context rootless network inspect inet --format '{{.Attachable}}')
    if [ "$subnet" != '192.168.240.0/20 ' ] || [ "$driver" != bridge ] || [ "$attachable" != true ]; then
        echo 'Existing inet network differs from the requested network; resolve it manually.' >&2
        exit 1
    fi
else
    docker --context rootless network create --driver bridge --subnet 192.168.240.0/20 --attachable inet
fi
echo "Docker networks:"
docker --context rootless network ls

# Rootless daemon data stays under ~/.local/share/docker, not /var/lib.
mkdir -p "$HOME/docker-hosting"
if [ ! -d "$HOME/docker-hosting/.git" ]; then
    git -C "$HOME/docker-hosting" init
fi
