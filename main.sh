#!/bin/bash

set -Eeuo pipefail
trap 'echo "Failed at $BASH_SOURCE:$LINENO: $BASH_COMMAND" >&2' ERR

if [ "$(id -u)" != "0" ]; then
    echo 'Please run this script as root user' >&2
    exit 1
fi

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/common.sh"
load_host_config "${1:-$DIR/host.conf}"
source "$DIR/zsh.sh"
cd -- "$DIR"

# Check access before changing passwords, SSH settings, or firewall rules.
if [ ! -r "$DIR/authorized_keys" ] || [ ! -s "$DIR/authorized_keys" ]; then
    echo "Missing or empty $DIR/authorized_keys; supply your SSH public key(s)." >&2
    exit 1
fi
ssh-keygen -lf "$DIR/authorized_keys" >/dev/null
if ! command -v apt-get >/dev/null || ! command -v systemctl >/dev/null; then
    echo 'This script requires an apt-based Linux host running systemd.' >&2
    exit 1
fi


update_user_pwd () {
    local user_name=$1 password
    password=$(openssl rand -base64 24)
    password="${password//[\/+=]/}"
    printf '%s:%s\n' "$user_name" "$password" | chpasswd
    printf 'New password for %s is %s\n' "$user_name" "$password"
}

setup_system() {
    local old_hostname hosts_file
    old_hostname=$(hostname)
    echo "Change host name to $HOST_NAME"
    hostnamectl set-hostname "$HOST_NAME"
    hosts_file=$(mktemp)
    awk -v old="$old_hostname" -v new="$HOST_NAME" '
        /^[[:space:]]*#/ { print; next }
        {
            for (i = 2; i <= NF && $i !~ /^#/; i++) {
                if ($i == old) $i = new
                if ($1 == "127.0.1.1" && $i == new) found = 1
            }
            print
        }
        END { if (!found) print "127.0.1.1 " new }
    ' /etc/hosts > "$hosts_file"
    # Copy contents, not the inode: /etc/hosts may be a bind mount.
    cat "$hosts_file" > /etc/hosts
    rm -- "$hosts_file"
}

setup_users() {
    update_user_pwd root
    echo 'Setup admin user...'
    if ! id admin >/dev/null 2>&1; then
        useradd --create-home --shell /bin/bash admin
    fi
    ADMIN_HOME=$(getent passwd admin | cut -d: -f6)
    ADMIN_GROUP=$(id -gn admin)
    if [[ $ADMIN_HOME != /* ]] || [ "$ADMIN_HOME" = / ]; then
        echo 'Admin must have a dedicated absolute home directory.' >&2
        return 1
    fi
    install -d -o admin -g "$ADMIN_GROUP" -m 700 "$ADMIN_HOME" "$ADMIN_HOME/.ssh"
    local keys_file sudoers_file
    keys_file=$(mktemp)
    if [ -f "$ADMIN_HOME/.ssh/authorized_keys" ]; then
        cat "$ADMIN_HOME/.ssh/authorized_keys" > "$keys_file"
        printf '\n' >> "$keys_file"
    fi
    cat "$DIR/authorized_keys" >> "$keys_file"
    awk '!seen[$0]++' "$keys_file" > "$keys_file.unique"
    install -o admin -g "$ADMIN_GROUP" -m 600 "$keys_file.unique" "$ADMIN_HOME/.ssh/authorized_keys"
    rm -- "$keys_file" "$keys_file.unique"
    update_user_pwd admin
    usermod -aG sudo admin
    visudo -c
    install -d -m 755 /etc/sudoers.d
    sudoers_file=$(mktemp)
    printf 'admin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudoers_file"
    visudo -cf "$sudoers_file"
    install -o root -g root -m 440 "$sudoers_file" /etc/sudoers.d/90-vps-init-admin
    rm -- "$sudoers_file"
    visudo -c
}

setup_sshd() {
    echo 'Update sshd config...'
    # Verify admin keys and sudo before disabling root/password authentication.
    ssh-keygen -lf "$ADMIN_HOME/.ssh/authorized_keys" >/dev/null
    su - admin -c 'sudo -n true'
    local backup config=/etc/ssh/sshd_config dropin=/etc/ssh/sshd_config.d/00-vps-init.conf
    backup=$(mktemp -d /etc/ssh/vps-init-backup.XXXXXX)
    cp -p -- "$config" "$backup/sshd_config"
    install -d -m 755 /etc/ssh/sshd_config.d
    if [ -f "$dropin" ]; then
        cp -p -- "$dropin" "$backup/dropin"
    fi
    cat > "$dropin" <<'EOF'
PermitRootLogin no
StrictModes yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
ClientAliveInterval 5
ClientAliveCountMax 12
EOF
    chmod 644 "$dropin"
    # First value wins in sshd; put our global include before vendor defaults.
    sed '\|^Include /etc/ssh/sshd_config.d/00-vps-init.conf$|d' "$config" > "$backup/new_config"
    { printf 'Include %s\n' "$dropin"; cat "$backup/new_config"; } > "$config"
    # Generate missing keys only; never rotate existing host identity on reruns.
    ssh-keygen -A
    if ! /usr/sbin/sshd -t; then
        cp -p -- "$backup/sshd_config" "$config"
        if [ -f "$backup/dropin" ]; then
            cp -p -- "$backup/dropin" "$dropin"
        else
            rm -- "$dropin"
        fi
        echo "Invalid SSH configuration; restored originals. Backup: $backup" >&2
        return 1
    fi
    SSH_PORTS=$(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}')
    if [ -z "$SSH_PORTS" ]; then
        echo 'Could not determine SSH listening ports.' >&2
        return 1
    fi
    if systemctl is-active --quiet ssh.service; then
        systemctl reload ssh.service
    elif systemctl is-active --quiet sshd.service; then
        systemctl reload sshd.service
    else
        echo "No active SSH service; configuration backup retained at $backup" >&2
        return 1
    fi
    echo "SSH configuration validated and reloaded. Backup: $backup"
}

update_packages() {
    echo Install common packages...
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo tmux mtr dnsutils htop rsync zsh git vim curl wget unzip gnupg socat \
        iftop iotop ncdu proxychains python-is-python3 ufw zip xxd strace tree openssl openssh-server ca-certificates
}

setup_ufw() {
    ufw default deny incoming
    ufw default allow outgoing
    local port
    for port in $SSH_PORTS; do
        ufw allow "$port/tcp"
    done
    ufw show added
    ufw --force enable
}

setup_misc() {
    touch /etc/vim/vimrc.local
    if ! grep -qxF 'set number' /etc/vim/vimrc.local; then
        printf '\nset number\n' >> /etc/vim/vimrc.local
    fi
    sed -i '/^socks4 .*/d' /etc/proxychains.conf
    if ! grep -qxF 'socks5 127.0.0.1 1080' /etc/proxychains.conf; then
        printf '\nsocks5 127.0.0.1 1080\n' >> /etc/proxychains.conf
    fi
}

# TODO: prompt hostname

update_packages
setup_system
setup_users
setup_sshd
setup_zsh
chsh -s /usr/bin/zsh

setup_ufw
setup_misc

ADMIN_SETUP_DIR=$(mktemp -d "$ADMIN_HOME/.vps-init.XXXXXX")
install -o admin -g "$ADMIN_GROUP" -m 600 "$CONFIG_FILE" "$ADMIN_SETUP_DIR/host.conf"
install -o admin -g "$ADMIN_GROUP" -m 644 admin.sh common.sh zsh.sh "$ADMIN_SETUP_DIR/"
chown admin:"$ADMIN_GROUP" "$ADMIN_SETUP_DIR"
su - admin -c "bash '$ADMIN_SETUP_DIR/admin.sh' '$ADMIN_SETUP_DIR/host.conf'"
rm -- "$ADMIN_SETUP_DIR/admin.sh" "$ADMIN_SETUP_DIR/common.sh" "$ADMIN_SETUP_DIR/zsh.sh" "$ADMIN_SETUP_DIR/host.conf"
rmdir -- "$ADMIN_SETUP_DIR"
chsh -s /usr/bin/zsh admin
