#!/bin/bash

setup_zsh() {
    echo 'Setup zsh...'
    local zsh_dir=${ZSH:-$HOME/.oh-my-zsh}
    local custom_dir=${ZSH_CUSTOM:-$zsh_dir/custom}
    local installer
    if [ ! -d "$zsh_dir" ]; then
        installer=$(mktemp)
        curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$installer"
        ZSH="$zsh_dir" RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$installer" --unattended
        rm -- "$installer"
    fi
    if [ ! -f "$HOME/.zshrc" ]; then
        cp -- "$zsh_dir/templates/zshrc.zsh-template" "$HOME/.zshrc"
    fi
    mkdir -p -- "$custom_dir/plugins" "${XDG_CACHE_HOME:-$HOME/.cache}"
    if [ ! -d "$custom_dir/plugins/zsh-autosuggestions" ]; then
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git \
            "$custom_dir/plugins/zsh-autosuggestions"
    fi
    if [ ! -d "$custom_dir/plugins/F-Sy-H" ]; then
        git clone --depth=1 https://github.com/z-shell/F-Sy-H.git "$custom_dir/plugins/F-Sy-H"
    fi
    # Replace only the block managed by this script; preserve other user settings.
    sed -i '/^# BEGIN vps-init$/,/^# END vps-init$/d' "$HOME/.zshrc"
    cat >> "$HOME/.zshrc" <<EOF
# BEGIN vps-init
export ZSH="$zsh_dir"
export ZSH_CUSTOM="$custom_dir"
ZSH_THEME="maran"
plugins=(git zsh-autosuggestions F-Sy-H)
EOF
    # Place the managed settings before Oh My Zsh is loaded by an existing rc.
    sed -i '/^source .*oh-my-zsh.sh/d' "$HOME/.zshrc"
    cat >> "$HOME/.zshrc" <<'EOF'
HISTSIZE=10000000
SAVEHIST=10000000
ZSH_COMPDUMP="${XDG_CACHE_HOME:-$HOME/.cache}/.zcompdump-${ZSH_VERSION}"
source "$ZSH/oh-my-zsh.sh"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/sbin:$PATH"
export EDITOR=vim
alias diff='diff --color=always'
alias t='tree -a'
alias pxy='proxychains'
# END vps-init
EOF
}
