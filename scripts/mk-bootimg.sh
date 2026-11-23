#!/bin/bash
# mk-bootimg.sh -- 把主线内核 + initramfs + 板级 DTB 打成 LG V50 能启动的 boot.img
#
# 在**构建机**（aarch64）上跑：initramfs 里的 busybox/parted 是 aarch64 二进制，
# x86 CI runner 造不出来。
#
# 打包参数全部来自本机原厂 BoardConfigCommon.mk（不是猜的）：
#   BOARD_BOOT_HEADER_VERSION   := 2
#   BOARD_KERNEL_PAGESIZE       := 4096
#   BOARD_KERNEL_BASE           := 0x00000000
#   BOARD_KERNEL_OFFSET         := 0x00008000
#   BOARD_RAMDISK_OFFSET        := 0x01000000
#   BOARD_KERNEL_TAGS_OFFSET    := 0x00000100
#   BOARD_DTB_OFFSET            := 0x01f00000
#   BOARD_KERNEL_IMAGE_NAME     := Image.gz
#   BOARD_INCLUDE_DTB_IN_BOOTIMG := true
#   BOARD_USES_RECOVERY_AS_BOOT  := true   (没有独立 recovery 分区，recovery 在 boot ramdisk)
#
# 用法:
#   mk-bootimg.sh <Image.gz> <initramfs.cpio.gz> <board.dtb> <out boot.img>
set -euo pipefail

KERNEL=$(realpath "${1:?usage: $0 Image.gz initramfs.cpio.gz board.dtb out.img}")
RAMDISK=$(realpath "${2:?}")
DTB=$(realpath "${3:?}")
OUT=${4:?}

WORK=$(mktemp -d /tmp/mkboot.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- mkbootimg（AOSP 官方 python 实现）----
MKBOOTIMG=${MKBOOTIMG:-}
if [ -z "$MKBOOTIMG" ]; then
	for c in /opt/lgv50/tools/mkbootimg/mkbootimg.py /usr/local/bin/mkbootimg.py; do
		[ -f "$c" ] && { MKBOOTIMG=$c; break; }
	done
fi
if [ -z "$MKBOOTIMG" ]; then
	echo "fetching AOSP mkbootimg.py ..."
	git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg \
		"$WORK/mkbootimg" >/dev/null 2>&1
	MKBOOTIMG="$WORK/mkbootimg/mkbootimg.py"
fi
[ -f "$MKBOOTIMG" ] || { echo "ERROR: mkbootimg.py not found" >&2; exit 1; }

# ---- 板级 DTB 门禁（ufshc/phy 必须 okay，否则一定起不来）----
if [ -x /opt/lgv50/scripts/check-dtb.sh ]; then
	bash /opt/lgv50/scripts/check-dtb.sh "$DTB"
fi

CMDLINE="console=tty0 androidboot.hardware=qcom androidboot.memcg=1 \
lpm_levels.sleep_disabled=1 msm_rtb.filter=0x237 service_locator.enable=1 \
swiotlb=2048 firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 \
androidboot.usbcontroller=a600000.dwc3 kpti=off \
androidboot.boot_devices=soc/1d84000.ufshc"

echo "=== mkbootimg ==="
python3 "$MKBOOTIMG" \
	--header_version 2 \
	--kernel "$KERNEL" \
	--ramdisk "$RAMDISK" \
	--dtb "$DTB" \
	--pagesize 4096 \
	--base 0x00000000 \
	--kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 \
	--second_offset 0x00000000 \
	--tags_offset 0x00000100 \
	--dtb_offset 0x01f00000 \
	--cmdline "$CMDLINE" \
	--output "$OUT"

echo "=== 产物 ==="
ls -l "$OUT"
# 分区容量是 100663296（96 MiB）
SZ=$(stat -c %s "$OUT")
if [ "$SZ" -gt 100663296 ]; then
	echo "ERROR: boot.img ${SZ} > 分区 100663296，会写不下" >&2
	exit 1
fi
echo "size ok: $SZ <= 100663296"

# ---- 回读校验：用 unpack_bootimg 复核头字段 ----
UNPACK="$(dirname "$MKBOOTIMG")/unpack_bootimg.py"
if [ -f "$UNPACK" ]; then
	echo "=== verify (unpack_bootimg) ==="
	python3 "$UNPACK" --boot_img "$OUT" --out "$WORK/unpacked" 2>&1 | head -20
fi

echo "=== md5 ==="
md5sum "$OUT"
