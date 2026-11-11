#!/bin/bash

if [ "$(id -u)" = "0" ]; then
    echo "Please run this script as non-root user"
    exit 1
fi

# if []
curl -fsSL https://get.docker.com/ | bash

# sudo usermod -aG docker admin
sudo apt-get install -y uidmap
echo dockerd-rootless-setuptool.sh install
dockerd-rootless-setuptool.sh install

docker network create --driver bridge --subnet 192.168.240.0/20 inet --attachable
echo "Docker networks:"
docker network ls

sudo mkdir -p /var/lib/docker-data

mkdir ~/docker-hosting
pushd ~/docker-hosting
git init
popd

