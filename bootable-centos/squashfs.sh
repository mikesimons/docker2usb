# Dracut expects the following for squashed images:
# - squashfs.img/LiveOS/rootfs.img/<actual root files>
# - squashfs.img is the squashed LiveOS dir containing rootfs.img
# - rootfs.img is expected to be a loop image with a supported fs

squashfs() {
  declare rootfs="$1" outdir="$2"

  local ext3_tmp_file=$(mktemp)
  local ext3_tmp_mount=$(mktemp -d)
  local squash_tmp_path=$(mktemp -d)
  clean "file" "$ext3_tmp_file"
  clean "file" "$ext3_tmp_mount"
  clean "file" "$squash_tmp_path"

  # Calculate required size of rootfs.img
  local rootfs_size=$(du -s "$rootfs" | cut -f1)
  local target_size=$((rootfs_size + ((rootfs_size / 100)) * 1)) # 1% buffer

  # Make rootfs.img
  truncate -s "${target_size}K" "$ext3_tmp_file"
  local loop=$(losetup --show -f "$ext3_tmp_file")
  clean "loopdev" "$loop"

  mkfs.ext3 "$loop"

  # Mount, copy and unmount the ext3 device
  squashfs_mount_copy_unmount "$loop" "$ext3_tmp_mount" "$rootfs"

  # Create expected LiveOS/rootfs.img structure
  mkdir -p "$squash_tmp_path/LiveOS"
  mv "$ext3_tmp_file" "$squash_tmp_path/LiveOS/rootfs.img"

  # Squash!
  mkdir -p "$outdir/LiveOS"
  mksquashfs "$squash_tmp_path" "$outdir/LiveOS/squashfs.img"

  cleanfn
}

squashfs_mount_copy_unmount() {
  declare loop="$1" mount="$2" rootfs="$3"
  
  mount "$loop" "$mount"
  clean "mount" "$loop"
  cp -R "$rootfs/"* "$mount/"

  cleanfn
}
