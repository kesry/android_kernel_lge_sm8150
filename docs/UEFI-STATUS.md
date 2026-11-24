# UEFI 引导：当前进展与下一步（2026-11-25 02:40）

## 已完成

1. **ESP 做好并放进 microSD 卡**（FAT32，310 MB 卡，用了 54 MB）
   - `EFI/BOOT/BOOTAA64.EFI` = systemd-boot arm64（92 KB，支持 `devicetree`）
   - `Image` = 主线内核 EFI 应用（49.7 MB，`pe_header_offset=0x40`）
   - `dtb` = V50 主线 DTB（131 KB，三段内存 + msm-id + simplefb）
   - `initramfs.cpio.gz` = 维护 initramfs（3.8 MB）
   - `loader/loader.conf` + `loader/entries/v50.conf`
   - `startup.nsh`（UEFI Shell 兜底）
   - 四个大文件 md5 已与构建机逐一比对，未被假卡截断

2. **Engineering ABL 已刷入 `abl_a`**（`5ee8a7a5`，`abl_b` 保持原厂 `0db942c4`）
   - 证据：V50 / G8X / V50S 三个项目的 `engabl_ab.bin` 是**同一个文件**（md5 完全一致）
   - 它是 WoA 安装流程文档里明确列出的必需前置
   - 自报型号变成 `LMG850N` 是共享构建里写死的字符串，不是拿错文件

3. **UEFI 镜像已验证有效**
   ```
   boot.img (header v0, page 4096)
   ├── kernel 段 = gzip(edk2 固件 3,145,840 B)  → 含 Firmware Volume Header @0x98 + PE/COFF
   ├── 追加 DTB = 499,866 B                     → 厂商下游 DTB，含 qcom,msm-id / board-id
   └── ramdisk = 6 B（几乎空）
   ```
   **它用的是厂商下游 DTB**（不是主线 DTB），所以能初始化硬件；LG 的 dtbo overlay
   天然能叠加到它上面。

## 卡在哪

刷 `boot_a` = UEFI 镜像 → 重启 → **落到工程 ABL 的 fastboot（`LMG850N`）**，UEFI 没接管。
`fastboot boot`（RAM 启动）同样失败，设备回退到 b 槽 Android。

判别方法：`fastboot getvar all` 里若出现 `variant: SDM UFS`、`hw-revision` 等，就是
**LG ABL 的 fastboot**；UEFI 自己的 fastboot 没有这些。

## 下一步假设（按可能性排序）

### 1. dtbo_a 全零导致 ABL 传 DT 失败（最可能）

现状：
```
dtbo_a = 全零（被清空过）
dtbo_b = d7b7ab1e ... 6,121,625 B（原厂 overlay 容器）
```

UEFI 镜像用厂商 DTB，配厂商 dtbo 是天然匹配；dtbo_a 全零可能让 ABL 在准备 DT 时失败。

**测试**：把 dtbo_b 内容写入 dtbo_a（两槽 dtbo 通常相同），再刷 UEFI 启动。

```bash
# 在 Android（root）里：
dd if=/dev/block/bootdevice/by-name/dtbo_b of=/dev/block/bootdevice/by-name/dtbo_a bs=1M
sync
# 回读校验应与 dtbo_b 一致（d65a921b...）
```

注意：这会让 LK 路径下的主线内核重新被 overlay 卡住（这正是我们当初清空 dtbo_a 的原因），
但 UEFI 路径下应当无碍。

### 2. boot 分区需要匹配的 vbmeta

```bash
fastboot --disable-verification --disable-verity flash vbmeta_a <vbmeta_a>
```
需要先 dump `vbmeta_a`。风险：改 vbmeta 可能影响 Android 启动，需备份。

### 3. 工程 ABL 需要额外触发条件

查 Renegade Project / `edk2-porting` 的文档，确认 V50 是否有额外要求
（例如必须先分区、或某个 `fastboot oem` 命令）。

## 需要用户配合的操作

**只有一步需要人**：切槽。因为 LG V50 的 `adb reboot bootloader` / `adb reboot fastboot`
都无效，进 fastboot 只能走 recovery 菜单，且 `set_active` 只在 fastbootd 里可用。

流程：
1. 我 `adb reboot recovery`
2. 用户在 recovery 里进 fastbootd
3. 我 `fastboot set_active a` + `fastboot flash boot_a uefi.img`
4. 重启看屏幕

## 设备当前状态

| 项 | 状态 |
|---|---|
| 活动槽 | **b**（Android 正常运行，4.14.355） |
| `abl_a` | 工程 ABL `5ee8a7a5` |
| `abl_b` | 原厂 `0db942c4` |
| `boot_a` | UEFI 镜像（首 4KB md5 `7c52683c`） |
| `boot_b` | 原厂 LOS Android |
| `dtbo_a` | 全零 |
| `dtbo_b` | 原厂 `d65a921b` |
| SD 卡 | 已插入，ESP 就绪 |

## 完整备份清单（本地 `v50-maint/`）

| 文件 | md5 |
|---|---|
| `abl_a_orig.bin` / `abl_b_orig.bin` | `0db942c4` |
| `dtbo_b.img` | `d65a921b` |
| `bootbackup_20261123_before_kernel/boot_a_orig.img` | `e3301193` |
| `bootbackup_20261123_before_kernel/boot_b_orig.img` | `477ce8ba` |
| `v50-uefi/engabl_ab.bin` | `5ee8a7a5` |
| `v50-uefi/flashlmdd-uefi-v240722.img` | `c4172cf5` |
