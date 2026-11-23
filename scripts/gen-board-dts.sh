#!/bin/bash
# gen-board-dts.sh -- 用上游 sm8150-mtp.dts 生成 V50 (flashlmdd) 板级 DTS
#
# 为什么这样做：
#   * 本机原厂 DTS（LOS 内核 arch/arm64/boot/dts/lge/sm8150-flash/…）用的是
#     LG 自己的 downstream dtsi，节点名/label 跟上游完全不同，不能直接用。
#   * 上游 sm8150-mtp.dts 已经把整板 90% 配好了，而且实测关键项与 V50 一致：
#       ufshc_mem: vcc=l10a_2p5 / vccq=l9a_1p2 / vccq2=s4a_1p8
#                  （= 原厂 pm8150_l10 / pm8150_l9 / pm8150_s4）
#       ufs_mem_phy: vdda-phy=l5a_0p875(alias vdda_ufs_2ln_core_1) / vdda-pll=l3c_1p2
#                  （= 原厂 pm8150_l5 / pm8150l_l3）
#       pon_resin -> KEY_VOLUMEDOWN（= 原厂音量下走 PMIC RESIN，与我们实测一致）
#   * 所以策略是：整份沿用 mtp，只改 model 并追加 V50 的增量。
#
# 用法: gen-board-dts.sh <linux-tree>
set -euo pipefail

LINUX=${1:?usage: $0 <linux-tree>}
D=$LINUX/arch/arm64/boot/dts/qcom
SRC=$D/sm8150-mtp.dts
DST=$D/sm8150-flashlmdd.dts

[ -f "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

cp "$SRC" "$DST"

# 1) model 标明本机；compatible 保持 mtp 不动（LG ABL 还会改写根 compatible，
#    保留 mtp 能让现有 quirk 继续命中，减少首启变量）
sed -i 's|model = "Qualcomm Technologies, Inc. SM8150 MTP";|model = "LG Electronics V50 ThinQ (flashlmdd)";|' "$DST"

# 2) 在文件末尾追加 V50 增量
cat >> "$DST" <<'EOF'

/*
 * ===== LG V50 ThinQ (flashlmdd / LM-V500N) 增量 =====
 * 数值来源：本机原厂内核 arch/arm64/boot/dts/lge/sm8150-flash/
 *           sm8150-flash_common/sm8150-flash_common-storage.dtsi 等
 */

/* UFS：原厂额外声明低压模式与 vddp-ref-clk，补上
 * 注意：不要加 vdd-hba-supply = <&ufs_phy_gdsc> ——
 * 那是 LG 下游内核的 label，主线 sm8150.dtsi 里没有，dtc 会报
 * "Reference to non-existent node or label" 直接编译失败。
 */
&ufs_mem_hc {
	vcc-low-voltage-sup;
	vcc-voltage-level = <2504000 2950000>;
	qcom,vddp-ref-clk-supply = <&vreg_l9a_1p2>;
	qcom,vddp-ref-clk-max-microamp = <100>;
};

/* UFS PHY：原厂声明 phy 常开 */
&ufs_mem_phy {
	vdda-phy-always-on;
	vdda-phy-max-microamp = <90200>;
	vdda-pll-max-microamp = <19000>;
};

/*
 * 音量上键：V50 走 GPIO 键（音量下走 PMIC RESIN，已在 &pon_resin 里）
 * 原厂节点：gpio_keys/vol_up, linux,code=115, gpios=<pm8150b_gpios 6 ACTIVE_LOW>
 */
/ {
	gpio-keys {
		compatible = "gpio-keys";
		pinctrl-names = "default";

		key-vol-up {
			label = "volume_up";
			gpios = <&pm8150b_gpios 6 GPIO_ACTIVE_LOW>;
			linux,code = <KEY_VOLUMEUP>;
			debounce-interval = <15>;
			wakeup-source;
		};
	};
};

/*
 * ramoops：必须与原厂 reserved-memory 里已有的 ramoops_region 完全一致，
 * 否则保留内存重叠会让 ramoops 注册失败、panic 日志无处可存。
 * 原厂 DT（/proc/device-tree/reserved-memory/ramoops_region@b0000000）：
 *   base = 0xb0000000, size = 0x300000 (3 MiB)
 */
/ {
	reserved-memory {
		#address-cells = <2>;
		#size-cells = <2>;
		ramoops@b0000000 {
			compatible = "ramoops";
			reg = <0x0 0xb0000000 0x0 0x300000>;
			record-size = <0x80000>;   /* 512 KiB */
			console-size = <0x100000>; /* 1 MiB */
			pmsg-size = <0x80000>;     /* 512 KiB */
			ftrace-size = <0x0>;
			ecc-size = <16>;
		};
	};
};

EOF

echo "generated: $DST"
grep -n 'model = ' "$DST" | head -2
grep -c . "$DST" | xargs echo "lines:"
