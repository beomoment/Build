#!/bin/bash

set -eo pipefail

# This script will be run in chroot under qemu.
# Re import helpers in chroot
# shellcheck source=./scripts/helpers.sh
source /helpers.sh
CHROOT=yes
export CHROOT
export -f log
export -f time_it

# shellcheck source=/dev/null
source /chroot_device_config.sh

function exit_error()
{
  log "Volumio chroot config failed" "$(basename "$0")" "err"
}

trap exit_error INT ERR

log "Running final config for ${DEVICENAME}"

## Setup Fstab
log "Creating fstab" "info"
cat <<-EOF > /etc/fstab
# ${DEVICENAME} fstab

proc           /proc                proc    defaults                                  0 0
/dev/mmcblk0p1 /boot                vfat    defaults,utf8,user,rw,umask=111,dmask=000 0 1
tmpfs          /var/log             tmpfs   size=20M,nodev,uid=1000,mode=0777,gid=4,  0 0
tmpfs          /var/spool/cups      tmpfs   defaults,noatime,mode=0755                0 0
tmpfs          /var/spool/cups/tmp  tmpfs   defaults,noatime,mode=0755                0 0
tmpfs          /tmp                 tmpfs   defaults,noatime,mode=0755                0 0
tmpfs          /dev/shm             tmpfs   defaults,nosuid,noexec,nodev              0 0
EOF

## Activate modules
log "Activating ${#MODULES[@]} custom modules:" "" "$(echo "${MODULES[@]}")"
mod_list=$(printf "%s\n"  "${MODULES[@]}")
cat <<-EOF >> /etc/initramfs-tools/modules
"${mod_list}"
EOF

#On The Fly Patch
#TODO Where should this be called?
PATCH=$(cat /patch)
if [ "$PATCH" = "volumio" ]; then
  log "No Patch To Apply" "wrn"
else
  log "Applying Patch ${PATCH}" "wrn"
  PATCHPATH=/${PATCH}
  cd $PATCHPATH || exit
  #Check the existence of patch script
  if [ -f "patch.sh" ]; then
    sh patch.sh
  else
    log "Cannot Find Patch File, aborting" "err"
  fi
  cd /
  rm -rf ${PATCH}
fi

## Adding board specific packages
log "Installing ${#PACKAGES[@]} custom packages:" "" "$(echo "${PACKAGES[@]}")"
apt-get update
apt-get install -y "${PACKAGES[@]}"

log "Cleaning APT Cache and remove policy file" "info"
rm -f /var/lib/apt/lists/*archive*
apt-get clean
rm /usr/sbin/policy-rc.d

#First Boot operations
log "Signaling the init script to re-size the Volumio data partition"
touch /boot/resize-volumio-datapart

log "Running device_chroot_tweaks_pre" "cfg"
device_chroot_tweaks_pre

log "Creating initramfs 'volumio.initrd'" "info"
mkinitramfs-buster.sh -o /tmp/initramfs-tmp
log "Finished creating initramfs" "okay"

log "Running device_chroot_tweaks_post" "cfg"
device_chroot_tweaks_post

if [[ ! $BUILD == "x86" ]]; then
  log "Creating uInitrd from 'volumio.initrd'" "info"
  mkimage -v -A $ARCH -O linux -T ramdisk -C none -a 0 -e 0 -n uInitrd -d /boot/volumio.initrd /boot/uInitrd
  if [[ -f /boot/boot.cmd ]]; then
    log "Creating boot.scr"
    mkimage -A $ARCH -T script -C none -d /boot/boot.cmd /boot/boot.scr
  fi
fi