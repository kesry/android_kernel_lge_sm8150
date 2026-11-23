#!/bin/bash
# check-dtb.sh -- DTB 门禁：编完必须过，否则不许打包/刷机
#
# 背景（来自同类项目 SM8150 的实测教训）：
#   sm8150.dtsi 里 ufshc / ufs phy 默认 status="disabled"。
#   板级 DTS 忘了覆写 → 内核没有 /dev/sd* → initramfs 等不到根设备 →
#   静默死循环，屏幕上还留着企鹅（看起来"内核没崩"，极具误导性）。
#
# 用法: check-dtb.sh <dtb文件>
set -u
DTB=${1:?usage: $0 <dtb>}
fail=0

have() { command -v "$1" >/dev/null 2>&1; }
if have dtc; then
	DTS=$(mktemp); dtc -I dtb -O dts -o "$DTS" "$DTB" 2>/dev/null
else
	echo "dtc not found -> skip detailed checks"; exit 0
fi

check_status() {
	# $1 = 节点名（如 ufshc@1d84000）
	local node=$1
	# 取从该节点开始到下一个同级节点的片段，找 status
	local st
	st=$(awk -v n="$node" '
		index($0, n) {f=1}
		f && /status[[:space:]]*=/ {gsub(/.*status[[:space:]]*=[[:space:]]*"|".*/,""); print; exit}
		f && /^[[:space:]]*};/ {f=0}
	' "$DTS")
	if [ "$st" = "okay" ]; then
		echo "[ok]   $node status=okay"
	else
		echo "[FAIL] $node status=${st:-未找到/disabled}  ← 会导致没有存储"
		fail=1
	fi
}

say_hdr() { echo "=== DTB 门禁: $DTB ==="; }

say_hdr
for n in "ufshc@1d84000" "phy@1d87000"; do
	check_status "$n"
done

# model / compatible 是否为本机板子
if grep -q 'flashlmdd\|LG Electronics\|LM-V500' "$DTS"; then
	echo "[ok]   model/compatible 含 flashlmdd/LGE"
else
	echo "[warn] model/compatible 未见 flashlmdd/LGE（首启后必须核对 /proc/device-tree/model）"
fi

rm -f "$DTS"
if [ $fail -ne 0 ]; then
	echo "=== DTB 门禁失败：不要打包、不要刷机 ==="
	exit 1
fi
echo "=== DTB 门禁通过 ==="
