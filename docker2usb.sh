#!/bin/bash
set -o errexit
set -o pipefail
set -x

# Making sure we can clean up after ourselves after any failure is *really* important
# We're using loopback devices which are in short supply
# And if we fail after a mount of a kpartx partition it's important to follow the right cleanup sequence
# Failure to do so often results in loop devices that can't be freed without a reboot
# Only `clean` and `cleanfn` are intended to be used directly
__clean_items=()

# Queues an item for cleaning
#
# item_type is one of file | mount | kpartx | loopdev | container
# item is the file | mount point | kpartx-ed loop device | loop device | container id
clean() {
  declare fn="${FUNCNAME[1]}" item_type="$1" item="$2"
  __clean_items+=("#$fn#$item_type#${#__clean_items[@]}##$item")
}

# Cleans up items queued by the calling function
#
# Items are cleaned in reverse order
cleanfn() {
  local fn="${FUNCNAME[1]}"
  [[ "$fn" == "__cleanall" ]] && fn=".*"
  local _filtered_items="$(printf "%s\n" "${__clean_items[@]}" | sed -e '/^#'"$fn"#'/!d' | tac)"
  for item in ${_filtered_items[@]}; do
    __clean_item "$item"
  done
}

# Trap func for cleanup. It's special cased by cleanfn to process all items in the queue
__cleanall() {
  cleanfn
}

# Removes an item from the cleanup queue
__use_clean_item() {
  declare raw="$1"
  local i=0
  for item in ${__clean_items[@]}; do
    if echo "$item" | grep "^$raw$" > /dev/null; then
      __clean_items[$i]=""
    fi
    i+=1
  done
}

# Item type implementations
# If you want to add a new type of cleanup item, here is where you do it
__clean_file_item()      { rm -rf "$1"; }
__clean_mount_item()     { umount "$1"; }
__clean_kpartx_item()    { kpartx -d "$1"; }
__clean_loopdev_item()   { losetup -d "$1"; }
__clean_container_item() { docker kill "$1"; }

# Processes an item in the cleanup queue
__clean_item() {
  declare raw="$1"

  # Example: #myfunc#file#1##some_file
  # Matches as: dummy#<fn:myfunc>#<item_type:file>#<id:1>#dummy#<item:some_file>
  IFS="#" read dummy fn item_type id dummy item <<< "$raw"
  [[ "$item_type" == "" ]] && return

  local fn="__clean_${item_type}_item"
  local fn_type=$(type -t "$fn")

  if [[ "$fn_type" != "function" ]]; then
    echo "Unknown cleanup item type $item_type"
  else
    "$fn" "$item"
  fi

  __use_clean_item "$raw"
}

# Extracts contents of <input> archive to <rootfs_path>
#
# If <input> starts with docker:// then an image with that name is started, exported and extracted.
# Otherwise <input> is assumed to be an actual file that `tar` can extract (.tar, .tgz, .tar.bz2 etc)
extract_rootfs() {
  declare input="$1" rootfs_path="$2"

  mkdir -p "$rootfs_path"
  if [[ "$input" == docker://* ]]; then
    local image=${input:9}
    local container_id=$(docker run -d -t "$image" sh)
    clean "container" "$container_id"
    docker export "$container_id" | tar -x -C "$rootfs_path"
  else
    tar -xf "$input" -C "$rootfs_path"
  fi

  cleanfn
}

# Squashes <rootfs_path> destructively and places resulting file somewhere under <working_path>
#
# The exact location is determined by the `squashfs.sh` script located in the <rootfs_path>
# Please note that <rootfs_path> will be forcefully removed by this function.
squash_rootfs() {
  declare rootfs_path="$1" working_path="$2"

  source "$rootfs_path/squashfs.sh"
  squashfs "$rootfs_path" "$working_path"
  rm -rf "$rootfs_path"

  cleanfn
}

# Packages the given <working_path> as an isohybrid image which will be written to <output>
#
# This method isn't very well tested so YMMV
package_isohybrid() {
  declare working_path="$1" output="$2" label="$2"

  # FIXME Does this use syslinux from host?
  # If so, may need to override path to include $working_path/syslinux
  # Mismatched syslinux versions are ripe for problems
  xorriso -as mkisofs \
    -o "$output" \
    -volid "$label" \
    -isohybrid-mbr "$working_path/syslinux/isohdpfx.bin" \
    -c syslinux/boot.cat \
    -b syslinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "$working_path"
}

# Given a size in KB this method returns a size aligned to 4MiB
#
# It is used to calculate the last partition alignment so that subsequent partitions can start on a 4MiB boundary
aligned_partition_end() {
  declare size_kb="$1"
  local size_mb=$((size_kb / 1024))
  local aligned_mb=$(((size_mb / 4) * 4))
  echo $aligned_mb
}

# Packages the given working path in to a raw disk image specified by <output>
#
# This is the best tested packaging method (whatever that means)
# It is possible to remount the resulting file and add extra partitions
# You will need to extend the file with `truncate` to do so though
# And there are only 2 partitions left after the alignment and boot partitions
# Also note that windows will only see the first formatted partition if this is written to a USB drive
package_raw_disk() {
  declare working_path="$1" output="$2" label="$3"

  # Calculate sizes
  local working_path_size_kb=$(du -s "$working_path" | cut -f1)
  local target_size_kb=$((working_path_size_kb + ((working_path_size_kb / 100)) * 10)) # 10% ish buffer
  local aligned_end_mb=$(aligned_partition_end "$target_size_kb")

  # Create and mount sparse file
  truncate -s "${target_size_kb}K" "$output"
  local loop=$(losetup --show -f "$output")
  local boot_device="/dev/mapper/${loop/\/dev\/}p2"
  clean "loopdev" "$loop"

  # Create partitions on loopback
  parted -s "$loop" "mklabel msdos"
  parted -s "$loop" "mkpart primary fat32 64s 4MiB" # Alignment partition
  parted -s "$loop" "mkpart primary 4MiB ${aligned_end_mb}MiB"
  parted -s "$loop" "set 2 boot on"
  parted -s "$loop" "set 2 lba on"
  kpartx -a "$loop"
  clean "kpartx" "$loop"

  # Create vfat fs on boot_device
  mkfs.msdos -n "$label" "$boot_device"

  # Mount new boot_device vfat fs
  local tmp_mount=$(mktemp -d)
  mount "$boot_device" "$tmp_mount"
  clean "file" "$tmp_mount"
  clean "mount" "$boot_device"

  # Copy the working tree in to the mount
  cp -r "$working_path/"* "$tmp_mount"

  # Install mbr
  dd bs=440 count=1 conv=notrunc if="$working_path/syslinux/mbr.bin" of="$loop"

  # Install syslinux boot code to partition
  "$working_path/syslinux/syslinux" --install "$boot_device" --directory "/syslinux"

  cleanfn
}

prepare_syslinux() {
  declare rootfs_path="$1" working_path="$2" label="$3"
  local version="6.03"
  local syslinux_path="/tmp/syslinux-$version"

  if [[ ! -e "$syslinux_path" ]]; then
    (cd /tmp && \
      wget "https://www.kernel.org/pub/linux/utils/boot/syslinux/syslinux-$version.tar.xz" && \
      tar -xf "/tmp/syslinux-$version.tar.xz" -C /tmp \
    )
  fi

  mkdir -p "$working_path/syslinux"

  # syslinux.cfg needs to be supplied by image as kernel params will be distro specific
  # It is expected to reside within /syslinux on the rootfs
  cp -r "$rootfs_path/syslinux/"* "$working_path/syslinux/"
  rm -rf "$rootfs_path/syslinux"

  cat "$rootfs_path/syslinux/syslinux.cfg" | ROOT_LABEL="$label" envsubst > "$rootfs_path/syslinux/syslinux.cfg.tmp"
  mv "$rootfs_path/syslinux/syslinux.cfg.tmp" "$rootfs_path/syslinux/syslinux.cfg"

  cp "$syslinux_path/bios/linux/syslinux"            "$working_path/syslinux/" # syslinux binary
  cp "$syslinux_path/bios/core/isolinux.bin"         "$working_path/syslinux/" # isolinux bootloader binary
  cp "$syslinux_path/bios/mbr/mbr.bin"               "$working_path/syslinux/" # raw disk bootsector
  cp "$syslinux_path/bios/mbr/isohdpfx.bin"          "$working_path/syslinux/" # isohybrid bootsector
  cp "$syslinux_path/bios/com32/menu/vesamenu.c32"   "$working_path/syslinux/" # graphical menu module
  cp "$syslinux_path/bios/com32/menu/menu.c32"       "$working_path/syslinux/" # text menu module
  cp "$syslinux_path/bios/com32/lib/libcom32.c32"    "$working_path/syslinux/" # bootloader libs
  cp "$syslinux_path/bios/com32/libutil/libutil.c32" "$working_path/syslinux/" # bootloader libs

  cleanfn
}

main() {
  declare input="$1" output="$2"

  local working_path=$(mktemp -d)
  local rootfs_path="$working_path/rootfs"
  local label="ISOIMAGE"
  clean "file" "$working_path"

  # TODO shopt for things like label, syslinux version & hooks

  extract_rootfs "$input" "$rootfs_path"
  squash_rootfs "$rootfs_path" "$working_path"
  prepare_syslinux "$rootfs_path" "$working_path" "$label"
  package_raw_disk "$working_path" "$output" "$label"

  cleanfn
}

trap __cleanall EXIT ERR INT
main "$@"
