ninja_tulip() {
	(
		. out/env-$TARGET_PRODUCT.sh
		exec prebuilts/ninja/linux-x86/ninja -C "$(gettop)" -f out/build-$TARGET_PRODUCT.ninja "$@"
	)
}

sdcard_image() {
	if [[ $# -ne 1 ]] && [[ $# -ne 2 ]]; then
		echo "Usage: $0 <output-image> [boot-size-in-MB]"
		return 1
	fi

  out_gz="$1"
  out="$(dirname "$out_gz")/$(basename "$out_gz" .gz)"

  get_device_dir

  boot0="$(gettop)/device/pine64-common/bootloader/boot0.bin"
  uboot="$(gettop)/device/pine64-common/bootloader/u-boot-with-dtb.bin"
  kernel="$ANDROID_PRODUCT_OUT/kernel"
  ramdisk="$ANDROID_PRODUCT_OUT/ramdisk.img"
  ramdisk_recovery="$ANDROID_PRODUCT_OUT/ramdisk-recovery.img"

  boot0_position=8       # KiB
  uboot_position=19096   # KiB
  part_position=21       # MiB
  boot_size=${2:-2200}   # MiB
  mbs=$((1024*1024/512)) # MiB to sector

  (
    set -eo pipefail

    echo "Compiling dtbs..."
    make -C "$(gettop)/device/pine64-common/bootloader"

    echo "Create beginning of disk..."
    dd if=/dev/zero bs=1M count=$part_position of="$out" status=none
    dd if="$boot0" conv=notrunc bs=1k seek=$boot0_position of="$out" status=none
    dd if="$uboot" conv=notrunc bs=1k seek=$uboot_position of="$out" status=none

    echo "Create boot file system... (VFAT)"
    dd if=/dev/zero bs=1M count=${boot_size} of="${out}.boot" status=none
    mkfs.vfat -n BOOT "${out}.boot"

    mcopy -v -m -i "${out}.boot" "$kernel" ::
    mcopy -v -m -i "${out}.boot" "$ramdisk" ::
    mcopy -v -m -i "${out}.boot" "$ramdisk_recovery" ::
    mcopy -v -s -m -i "${out}.boot" "$(gettop)/device/pine64-common/bootloader/pine64" ::

    mkimage -C none -A arm -T script -d "$(gettop)/device/pine64-common/bootloader/boot.cmd" boot.scr
    mcopy -v -m -i "${out}.boot" "boot.scr" ::
    mcopy -m -i "${out}.boot" "$(gettop)/device/pine64-common/bootloader/uEnv.txt" ::
    rm -f boot.scr

    echo "Append system to boot file system..."
    mcopy -v -m -i "${out}.boot" "$ANDROID_PRODUCT_OUT/system.img" ::

    echo "Append boot..."
    dd if="${out}.boot" conv=notrunc oflag=append bs=1M of="$out" status=none
    rm -f "${out}.boot"

    echo "Append cache..."
    cache_size=$(stat -c%s "$ANDROID_PRODUCT_OUT/cache.img")
    dd if="$ANDROID_PRODUCT_OUT/cache.img" conv=notrunc oflag=append bs=1M of="$out" status=none

    echo "Append data..."
    data_size=$(stat -c%s "$ANDROID_PRODUCT_OUT/userdata.img")
    dd if="$ANDROID_PRODUCT_OUT/userdata.img" conv=notrunc oflag=append bs=1M of="$out" status=none

    echo "Partition table..."
    cat <<EOF | sfdisk "$out"
$((part_position*mbs)),$((boot_size*mbs)),6
$(((part_position+boot_size)*mbs)),$((cache_size/512)),L
$(((part_position+boot_size)*mbs)),$((data_size/512)),L
EOF

    # TODO: this is broken, because https://github.com/longsleep/u-boot-pine64
    # doesn't execute sunxi_partition_init
    #
    # echo "Updating fastboot table..."
    # sunxi-nand-part -f a64 "$out" $(((part_position-20)*mbs)) \
    #   "boot $((boot_size*mbs)) 32768" \
    #   "cache $((cache_size*mbs)) 32768" \
    #   "data 0 33024"

    size=$(stat -c%s "$out")

    if [[ "$(basename "$out_gz" .gz)" != "$(basename "$out_gz")" ]]; then
      echo "Compressing image..."
      pigz "$out"
      echo "Compressed image: $out (size: $size)."
    else
      echo "Uncompressed image: $out (size: $size)."
    fi
  )
}

tulip_sync() {
  (
    set -xe
    command make -C $ANDROID_BUILD_TOP/device/pine64-common/bootloader
    adb wait-for-device
    adb shell umount /bootloader || true
    adb shell mount -t vfat /dev/block/mmcblk0p1 /bootloader
    adb remount
    adb sync system
    mkimage -C none -A arm -T script -d "$(gettop)/device/pine64-common/bootloader/boot.cmd" $ANDROID_PRODUCT_OUT/boot.scr
    for i in kernel ramdisk.img ramdisk-recovery.img boot.scr; do
      adb push $ANDROID_PRODUCT_OUT/$i /bootloader/
    done
    for i in pine64/sun50i-a64-pine64-plus.dtb; do
      adb push $ANDROID_BUILD_TOP/device/pine64-common/bootloader/$i /bootloader/$i
    done
    adb shell sync
  )
}
