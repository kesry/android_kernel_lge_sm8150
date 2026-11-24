# 走 edk2-msm UEFI 引导（LG V50 / flashlmdd）

## 为什么放弃 LK 路径

用 LG 的 LK 引导主线内核时**完全看不到输出**：

| 手段 | 结果 |
|---|---|
| simple-framebuffer 控制台 | 屏幕无文字（内核没跑到 simpledrm） |
| pstore / ramoops | 永远为空（panic 早于 ramoops 驱动 probe） |
| `softlockup_panic` / `hardlockup_panic` | 不触发（死在更早阶段） |
| UART | 无 UART 线（LG 的 UART 走 USB-C SBU，需专用线） |

等于盲调。两个成功的 LG/SM8150 社区移植（nura-g8x、xiaomi-cephous）都走 UEFI。

## 社区配方（读自 `heyManNice/flashlmdd_rec_flash_win`）

`asset/sh/boot.sh`：

```bash
dd if=uefi.img of=/dev/block/by-name/boot$slot_suffix     # UEFI 刷进 boot 分区
cp ${WIN}/Windows/Boot/EFI/* ${ESP}/EFI/Microsoft/Boot
cp ${ESP}/EFI/Microsoft/Boot/bootmgfw.efi ${ESP}/EFI/Boot/bootaa64.efi
```

要点：**UEFI 刷进 `boot` 分区** + **必须有 FAT32 的 ESP**，ESP 里放 `EFI/Boot/bootaa64.efi`。

## 我们的方案：ESP 放 microSD 卡

V50 有 microSD 槽，把 ESP 放卡上，**手机上一个分区都不用动**。

### ESP 内容（已做好，在 `v50-esp/`，并已拷到 SD 卡）

```
EFI/BOOT/BOOTAA64.EFI    92672    systemd-boot arm64（支持 devicetree）
Image                 52062720    内核，EFI 应用（pe_header_offset=0x40）
dtb                     134524    V50 DTB（三段内存 + msm-id + simplefb）
initramfs.cpio.gz      3832070    维护 initramfs（parted + USB ACM 控制台）
loader/loader.conf                 默认入口 v50，超时 5s
loader/entries/v50.conf            linux /Image + devicetree /dtb + initrd + options
startup.nsh                        UEFI Shell 兜底
```

### 为什么需要 systemd-boot（不能直接把内核当 BOOTAA64.EFI）

**arm64 主线没有 `CONFIG_ARM64_APPENDED_DTB`**（那是 ARM32 的）。arm64 的 EFI stub
从 **EFI 配置表**里取 DTB，不会去找追加在 Image 后面的 DTB。

所以必须有个引导器把 DTB 通过 EFI 配置表传给内核。systemd-boot 的 loader entry
支持 `devicetree` 指令，正好干这个。

### 内核配置（commit f379f02）

```
CONFIG_EFI=y / CONFIG_EFI_STUB=y    -> Image 变成 PE/EFI 应用
CONFIG_DMI=y / DMIID / DMI_SYSFS    -> 飞牛需要
CONFIG_ARM64_VA_BITS=48             -> SM8150 是 ARMv8.2-A，不支持 52 位/LPA2
CONFIG_DRM_SIMPLEDRM=y              -> UEFI 的 GOP 帧缓冲 -> 屏幕出控制台
CONFIG_FRAMEBUFFER_CONSOLE=y
```

## 操作步骤

1. **SD 卡插进手机**
2. `fastboot flash boot_a flashlmdd-uefi-v240722.img`
   （UEFI 镜像 3.3 MB，md5 `c4172cf5dc9a34a1b7624139d84f6639`）
3. 确认 `current-slot` 是 **a**
4. 重启 → UEFI 起来 → systemd-boot 菜单 → 选 `LG V50 mainline` → 内核启动
5. **屏幕上应出现内核日志**（这是我们要的第一手输出）

## 关键资产

| 文件 | md5 | 说明 |
|---|---|---|
| `v50-uefi/flashlmdd-uefi-v240722.img` | `c4172cf5` | V50 专用 UEFI（3.3 MB） |
| `v50-maint/abl_a_orig.bin` | `0db942c4` | 原厂 abl_a（**已还原到位**） |
| `v50-maint/abl_b_orig.bin` | `0db942c4` | 原厂 abl_b（从未动过） |
| `v50-maint/dtbo_b.img` | `d65a921b` | 原厂 dtbo_b |
| `bootbackup_20261123_before_kernel/` | — | boot_a / boot_b 原厂镜像 |
| `v50-uefi/engabl_ab.bin` | `5ee8a7a5` | Engineering ABL（**已撤销，勿用**） |

## 踩过的坑

1. **LG 的 boot.img 格式**：header v1 + page 2048 + DTB 追加在内核后。v2/4096 会被拒。
2. **dtbo overlay**：ABL 会把该槽的 `dtbo` 叠加到 boot.img 的 DTB 上。`dtbo_b` 有厂商
   overlay（引用 211 个主线没有的 label），叠加失败就**中止启动**；`dtbo_a` 全零，
   叠加是 no-op。所以**只用 a 槽**测试。
3. **memory 节点**：`sm8150.dtsi` 的 `memory@80000000` 大小是 0，靠 bootloader 填充。
   V50 实际是**三段不连续内存**（0x80000000+0.95G / 0xc0000000+2G / 0x140000000+3G，
   合计 5.95 GiB）。注意 `0x140000000` 在 2-cell 地址里要写成 `<0x1 0x40000000>`。
4. **Engineering ABL**：V50 WoA 项目提供的 `engabl_ab.bin` 实际自报 `LMG850N`（G8X），
   刷了会改变机器身份。**已还原原厂**，UEFI 引导这一步不需要它。
5. **userdata 无法缩容**：整分区是 Android 元数据加密（块层随机数据），外部工具
   无法 resize。要腾空间只能删重建。

## 当前设备状态（2026-11-25 02:00）

- `abl_a` / `abl_b` = **原厂**（`0db942c4`）
- `boot_a` = UEFI 镜像（等 SD 卡 + 启动测试）
- `boot_b` = 原厂 LOS Android（正常，作为回退）
- `dtbo_a` = 全零，`dtbo_b` = 原厂
- 序列号 `LMV500N...` = 原厂 ABL 在跑
