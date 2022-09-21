#!/bin/bash
set -e
set -x

NUM_CPUS=`nproc`
echo "###############"
echo "### Using ${NUM_CPUS} cores"

# setup some build variables
BUILD_ROOT=$PWD/kernel_build
BUILD_CACHE=$BUILD_ROOT/cache
LINUX_KERNEL=$BUILD_CACHE/linux-kernel
#NEW_VERSION=1.`date +%Y%m%d-%H%M%S`
NEW_VERSION="1.20220918-jclab1"
LINUX_KERNEL_COMMIT=5b775d7293eb75d6dfc9c5ffcb95c5012cd0c3f8 # Linux 5.15 1.20220830
RASPBERRY_FIRMWARE=$BUILD_CACHE/rpi_firmware

# running in Circle build
SRC_DIR=`pwd`

BUILD_RESULTS=$BUILD_ROOT/results/kernel-$NEW_VERSION

function setup_build_dirs () {
  for dir in $BUILD_ROOT $BUILD_CACHE $BUILD_RESULTS $LINUX_KERNEL $RASPBERRY_FIRMWARE; do
    mkdir -p $dir
  done
}

function clone_or_update_repo_for () {
  local repo_url=$1
  local repo_path=$2
  local repo_commit=$3

  if [ ! -z "${repo_commit}" ]; then
    rm -rf $repo_path
  fi
  if [ -d ${repo_path}/.git ]; then
    pushd $repo_path
    git reset --hard HEAD
    git pull
    popd
  else
    echo "Cloning $repo_path with commit $repo_commit"
    git clone $repo_url $repo_path
    if [ ! -z "${repo_commit}" ]; then
      cd $repo_path && git checkout -qf ${repo_commit}
    fi
  fi
}

function setup_linux_kernel_sources () {
  echo "### Check if Raspberry Pi Linux Kernel repository at ${LINUX_KERNEL} is still up to date"
  clone_or_update_repo_for 'https://github.com/raspberrypi/linux.git' $LINUX_KERNEL $LINUX_KERNEL_COMMIT
  echo "### Cleaning .version file for deb packages"
  rm -f $LINUX_KERNEL/.version
}

function setup_rpi_firmware () {
  echo "### Check if Raspberry Pi Firmware repository at ${LINUX_KERNEL} is still up to date"
  clone_or_update_repo_for 'https://github.com/RPi-Distro/firmware' $RASPBERRY_FIRMWARE ""
}

function prepare_kernel_building () {
  setup_build_dirs
  setup_linux_kernel_sources
  setup_rpi_firmware
}


create_kernel_for () {
  echo "###############"
  echo "### START building kernel for ${PI_VERSION}"

  local PI_VERSION=$1

  cd $LINUX_KERNEL

  # save git commit id of this build
  local KERNEL_COMMIT=`git rev-parse HEAD`
  echo "### git commit id of this kernel build is ${KERNEL_COMMIT}"

  # clean build artifacts
  make ARCH=arm64 clean

  KERNEL=kernel8

  echo "### building kernel"
  mkdir -p $BUILD_RESULTS
  echo $KERNEL_COMMIT > $BUILD_RESULTS/kernel-commit.txt
  cp $LINUX_KERNEL/arch/arm64/configs/bcm2711_defconfig $LINUX_KERNEL/.config
  cat "${SRC_DIR}/append_configs" >> $LINUX_KERNEL/.config
  sed -i -E 's/^CONFIG_LOCALVERSION.+$/CONFIG_LOCALVERSION="-v8-jclab"/g' $LINUX_KERNEL/.config

  echo "### building kernel and deb packages"
  KBUILD_DEBARCH=arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make deb-pkg -j$NUM_CPUS

  version=$(${LINUX_KERNEL}/scripts/mkknlimg --ddtk $LINUX_KERNEL/arch/arm64/boot/Image $BUILD_RESULTS/${KERNEL}.img | head -1 | sed 's/Version: //')
  suffix=""
  echo "$version" > $RASPBERRY_FIRMWARE/extra/uname_string$suffix

  echo "### installing kernel modules"
  mkdir -p $BUILD_RESULTS/modules
  ARCH=arm CROSS_COMPILE=${CCPREFIX[${PI_VERSION}]} INSTALL_MOD_PATH=$BUILD_RESULTS/modules make modules_install -j$NUM_CPUS

  echo "### Listing $BUILD_RESULTS/modules"
  ls -l $BUILD_RESULTS/modules

  # remove symlinks, mustn't be part of raspberrypi-bootloader*.deb
  echo "### removing symlinks"
  rm -f $BUILD_RESULTS/modules/lib/modules/*/build
  rm -f $BUILD_RESULTS/modules/lib/modules/*/source

  if [[ ! -z $CIRCLE_ARTIFACTS ]]; then
    cp ../*.deb $CIRCLE_ARTIFACTS
  fi
  mv ../*.deb $BUILD_RESULTS
  echo "###############"
  echo "### END building kernel for ${PI_VERSION}"
  echo "### Check the $BUILD_RESULTS/kernel.img and $BUILD_RESULTS/modules directory on your host machine."
}

function create_kernel_deb_packages () {
  echo "###############"
  echo "### START building kernel DEBIAN PACKAGES"

  PKG_TMP=`mktemp -d`

  NEW_KERNEL=$PKG_TMP/raspberrypi-kernel-${NEW_VERSION}

  mkdir -p $NEW_KERNEL

  # copy over source files for building the packages
  echo "copying firmware from $RASPBERRY_FIRMWARE to $NEW_KERNEL"
  # skip modules directory from standard tree, because we will our on modules below
  tar --exclude=modules --exclude=headers --exclude=.git -C $RASPBERRY_FIRMWARE -cf - . | tar -C $NEW_KERNEL -xvf -
  # create an empty modules directory, because we have skipped this above
  mkdir -p $NEW_KERNEL/modules/
  cp -r $SRC_DIR/debian $NEW_KERNEL/debian
  touch $NEW_KERNEL/debian/files

  mkdir -p $NEW_KERNEL/headers/
  for deb in $BUILD_RESULTS/linux-headers-*.deb; do
    dpkg -x $deb $NEW_KERNEL/headers/
  done

  for pi_version in ${!CCPREFIX[@]}; do
    cp $BUILD_RESULTS/$pi_version/${IMAGE_NAME[${pi_version}]} $NEW_KERNEL/boot
    cp -R $BUILD_RESULTS/$pi_version/modules/lib/modules/* $NEW_KERNEL/modules
  done
  echo "copying dtb files to $NEW_KERNEL/boot"
  cp $LINUX_KERNEL/arch/arm64/boot/dts/broadcom/bcm2*.dtb $NEW_KERNEL/boot
  # build debian packages
  cd $NEW_KERNEL

  (cd $NEW_KERNEL/debian ; ./gen_bootloader_postinst_preinst.sh)

  dch -v ${NEW_VERSION} --package raspberrypi-firmware 'add Hypriot custom kernel'
  debuild --no-lintian -b -aarm64 -us -uc
  cp ../*.deb $BUILD_RESULTS
  if [[ ! -z $CIRCLE_ARTIFACTS ]]; then
    cp ../*.deb $CIRCLE_ARTIFACTS
  fi

  echo "###############"
  echo "### FINISH building kernel DEBIAN PACKAGES"
}


##############
###  main  ###
##############

echo "*** all parameters are set ***"
echo "*** the kernel timestamp is: $NEW_VERSION ***"
echo "#############################################"

# clear build cache to fetch the current raspberry/firmware
rm -fr $RASPBERRY_FIRMWARE

# setup necessary build environment: dir, repos, etc.
prepare_kernel_building

# create kernel, associated modules
create_kernel_for rpi4

# create kernel packages
create_kernel_deb_packages

# running in vagrant VM
if [ -d /vagrant ]; then
  # copy build results to synced vagrant host folder
  FINAL_BUILD_RESULTS=/vagrant/build_results/$NEW_VERSION
else
  # running in Circle build
  FINAL_BUILD_RESULTS=$SRC_DIR/output/$NEW_VERSION
fi

echo "###############"
echo "### Copy deb packages to $FINAL_BUILD_RESULTS"
mkdir -p $FINAL_BUILD_RESULTS
cp $BUILD_RESULTS/*.deb $FINAL_BUILD_RESULTS
cp $BUILD_RESULTS/*.txt $FINAL_BUILD_RESULTS

ls -lh $FINAL_BUILD_RESULTS
echo "*** kernel build done"
