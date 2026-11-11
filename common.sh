#!/bin/bash

load_host_config() {
    CONFIG_FILE=${1:-"$DIR/host.conf"}
    if [ ! -r "$CONFIG_FILE" ]; then
        echo "Missing host config: $CONFIG_FILE (copy host.conf.example and edit it)." >&2
        return 1
    fi
    CONFIG_FILE=$(realpath -- "$CONFIG_FILE")
    # Configuration is trusted shell code, not an environment file.
    source "$CONFIG_FILE"
    if [[ ! ${HOST_NAME:-} =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] ||
        [[ ! ${HOST_EMAIL:-} =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
        echo 'Set a valid HOST_NAME and HOST_EMAIL in the host config.' >&2
        return 1
    fi
    export HOST_NAME HOST_EMAIL
}
