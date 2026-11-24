# UEFI 引导：状态与下一步（2026-11-25 02:45）

## 重要更正：Engineering ABL 不需要

WoA 文档 `guide/1-partition.md` 里写得很清楚：

> ### Flashing engineering ABL
> **If fastboot works on your phone, you can skip this step**

**只有 fastboot 不可用时才需要刷 Engineering ABL。** 这台机器的 fastboot 正常，
所以不需要它 —— 之前刷它是我误读文档，已还原原厂。

（另外即使要刷，文档也要求 a、b 两个槽都刷；我们只刷了 a。）

## 已准备好的东西

### 1. ESP（microSD 卡，FAT32 310 MB，MBR 类型 0x0e）

```
EFI/BOOT/BOOTAA64.EFI   92672    systemd-boot arm64（支持 devicetree）
Image                52062720    主线内核 EFI 应用（pe_header_offset=0x40）
dtb                    134524    V50 主线 DTB（三段内存 + msm-id + simplefb）
initramfs.cpio.gz     3832070    维护 initramfs
loader/loader.conf + loader/entries/v50.conf
startup.nsh                      UEFI Shell 兜底
```

四个大文件 md5 已与构建机逐一比对，未被假卡截断。

### 2. UEFI 镜像（已验证有效）

```
boot.img (header v0, page 4096)
├── kernel 段 = gzip(edk2 固件 3,145,840 B)
│               含 Firmware Volume Header @0x98、PE/COFF @0x1352d
│               字符串里能搜到 "LinuxLoader" 和 "Shell"（带 Linux 加载器和 UEFI Shell）
├── 追加 DTB = 499,866 B（厂商下游 DTB，含 qcom,msm-id / board-id）
└── ramdisk = 6 B
```

`id` 字段校验：按「不含 cmdline」的 SHA1 变体完全匹配（原厂镜像按同公式不匹配却仍能启动
→ ABL 不校验 id，这条排除）。

### 3. 分区状态

| 分区 | 当前内容 | md5 |
|---|---|---|
| `abl_a` | **原厂**（工程 ABL 已撤销） | `0db942c4` |
| `abl_b` | 原厂（从未动过） | `0db942c4` |
| `boot_a` | UEFI 镜像 | 首 4KB `7c52683c` |
| `boot_b` | 原厂 LOS Android | `477ce8ba` |
| `dtbo_a` | **已从 dtbo_b 恢复为原厂 overlay** | `d65a921b` |
| `dtbo_b` | 原厂 | `d65a921b` |

## 下一步（用户切槽后执行）

1. `adb reboot recovery` → 用户在 recovery 里进 fastbootd
2. `fastboot set_active a`
3. `fastboot flash boot_a flashlmdd-uefi-v240722.img`
4. 重启（SD 卡在机内）→ 观察屏幕

### 这次比之前多的两个变量

- **dtbo_a 现在有原厂 overlay**（之前是全零）—— UEFI 用厂商 DTB，配厂商 dtbo 天然匹配
- **abl_a 回到原厂**（按文档，fastboot 正常就不需要工程 ABL）

## 如果还是不行的备选

| 方案 | 说明 |
|---|---|
| 内部 ESP | 照 WoA 流程从 userdata 切出 512 MB FAT32 + `parted set N esp on`，但会丢 Android 数据 |
| vbmeta 关闭校验 | `fastboot --disable-verification flash vbmeta_a`，需先备份 vbmeta_a |
| UEFI Shell | 若 UEFI 起来了但找不到 ESP，屏幕应显示 Shell；届时可手动 `fs0:` 浏览 |
| UART 线 | 终极方案，LG UART 走 USB-C SBU |

## 踩过的坑（累计）

1. **boot.img 格式**：LK 路径要 header v1 + page 2048 + DTB 追加；UEFI 镜像是 header v0。
2. **dtbo overlay**：ABL 把该槽 dtbo 叠加到 boot.img 的 DTB 上，叠加失败会中止启动。
3. **memory 节点**：`sm8150.dtsi` 里大小是 0，靠 bootloader 填；V50 实际三段不连续内存
   （0x80000000+0.95G / 0xc0000000+2G / 0x140000000+3G），注意 `0x140000000` 在 2-cell
   地址里要写 `<0x1 0x40000000>`。
4. **arm64 没有 `CONFIG_ARM64_APPENDED_DTB`**：UEFI 下必须由引导器（systemd-boot 的
   `devicetree` 指令）把 DT 通过 EFI 配置表传给内核。
5. **Engineering ABL 只在 fastboot 坏了才需要**。
6. **userdata 是元数据加密的**，外部工具无法缩容。
7. **LG V50 进 fastboot 只能走 recovery 菜单**，`adb reboot bootloader` / `adb reboot fastboot`
   都无效；`set_active` 只在 fastbootd 里可用。
