#!/bin/bash

SUDO=$(which sudo || true)

set -e

${SUDO} apt-get -y update
${SUDO} apt-get install -y git-core build-essential libncurses5-dev bc tree fakeroot devscripts binfmt-support qemu qemu-user-static debootstrap kpartx lvm2 dosfstools apt-cacher-ng debhelper quilt zip
${SUDO} apt-get install -y libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf llvm make gcc g++
${SUDO} apt-get install -y crossbuild-essential-arm64
