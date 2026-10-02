PitchBlack Recovery (PBRP) device tree for Redmi Note 8 Pro (begonia)
=====================================================================

Device configuration for building PitchBlack Recovery Project (PBRP) 12.1 for the
Redmi Note 8 Pro (begonia, MediaTek Helio G90T / MT6785). One image handles both
partition layouts that begonia ROMs use:

| Layout  | Partitions | Examples |
| ------- | ---------- | -------- |
| dynamic | Retrofit dynamic partitions: super spans `by-name/system` and `by-name/vendor`, LP metadata on `by-name/system` (`androidboot.super_partition=system`); logical `system`, `system_ext`, `product`, `vendor` (and `odm` where a ROM has it) | current Infinity-X builds |
| legacy  | Plain `system` and `vendor` partitions (erofs or ext4) | static builds and older ROMs |

**Status: not tested on a device yet.** No ROM has been verified with this tree so far;
tested ROMs will be listed here by name.

## How the layout is chosen

`recovery/root/system/bin/begonia-layout.sh` runs from `init.recovery.mt6785.rc` at
`on init`, before the recovery starts, and reads `by-name/system`:

- **dynamic**: valid LP geometry and metadata header, and no file system superblock in
  the first 4 KiB. `recovery.fstab.dynamic` and `twrp.flags.dynamic` are appended: the
  logical partitions, read-only, with no backup, flash or image entries.
  `ro.boot.dynamic_partitions` is set to `true` in this mode only.
- **legacy**: no LP metadata and an erofs or ext4 superblock. `recovery.fstab.legacy` and
  `twrp.flags.legacy` are appended: raw System and Vendor, System Image and Vendor Image.
- **unknown**: anything else. Nothing is appended, so no System or Vendor entry exists,
  and the recovery shows a warning.

The result is in the property `twrp.begonia.layout`. After installing a ROM with the
other layout, use Reboot > Recovery before using Wipe, Backup or Install Image.

## Warnings

- **NVRAM, NVDATA, NVCFG and Protect (protect1/protect2) backups belong to the phone they
  were made on.** They hold its IMEI, modem calibration and SIM data. Never restore them
  on another phone; that breaks the IMEI and the radio. These partitions carry the
  `perdevice` flag: they are not pre-selected for restore, and restoring one prints a
  warning. Persist holds per-phone data too (calibration, keys) and carries the same
  flag: restore only your own backup.
- **Never back up, restore or flash "Super".** On begonia super spans two partitions; a
  single-device Super image is incomplete. This tree does not create a Super entry.
- Install Image is not offered for Persist.
- MTP is disabled (the recovery kernel has no configfs MTP function).

## Differences from the base tree

Forked from [Saikrishna1504/device_xiaomi_begonia-pbrp](https://github.com/Saikrishna1504/device_xiaomi_begonia-pbrp)
at `3bf5154` ("begonia: Fix Decryption", FBE v1). Its later FBEv2/keydirectory changes are
not taken; `/data` here matches the ROM (FBE v1, inlinecrypt, no keydirectory).

- PBRP product naming (`pb_begonia`, Sai's `18dadeb`).
- Super block from the ROM's BoardConfig.mk, `TW_SUPER_MULTI_BLOCK_DEVICES`.
- Header cmdline: `androidboot.init_fatal_reboot_target=recovery` (LK passes the recovery's
  cmdline on to every normal boot, so `bootloader` there would also apply to the ROM),
  `androidboot.super_partition=system` added by hand, no `buildvariant=` in the header.
  `androidboot.selinux=permissive` is still in the header.
- Runtime layout switch (above), `/data`, `/metadata` and `/cache` from the ROM's fstab.
- fastbootd, lpdump/lpdumpd and lptools in the ramdisk, without
  `PRODUCT_USE_DYNAMIC_PARTITIONS` (that flag would put `ro.boot.dynamic_partitions=true`
  into `prop.default` for static ROMs too).
- USB gadget built by the recovery's `init.rc` (configfs from `on init`), so fastbootd
  gets its `ffs.fastboot` function.
- Kernel from the ROM's kernel source (see Sources). It is the ROM's configuration with
  `CONFIG_BEGONIA_BLANK_PERMISSIVE_CMDLINE` turned off, so `androidboot.selinux=permissive`
  from the header reaches the recovery.
- Kept as they were: the dtb and dtbo prebuilts (LK also reads the recovery's dtb on normal
  boots and panics on the ROM's overlay-first dtb section), boot image geometry, AVB, the
  crypto flags, the keymaster/gatekeeper/TEE blobs, the `PB_*` flags, and the version spoof
  (`PLATFORM_VERSION 99.87.36`, security patch 2099-12-31).

## Building

This tree needs the begonia patch series for PBRP's `bootable/recovery`
(branch `android-12.1-begonia` on top of PBRP `android-12.1`): the layout property, the
LP-metadata super check, `TW_SUPER_MULTI_BLOCK_DEVICES` and the `perdevice` flag come from
there.

```bash
repo init --depth=1 -u https://github.com/PitchBlackRecoveryProject/manifest_pb -b android-12.1
# add a local manifest with this tree at device/xiaomi/begonia and the patched
# bootable/recovery, then
repo sync -c --no-tags --no-clone-bundle
export ALLOW_MISSING_DEPENDENCIES=true
. build/envsetup.sh
lunch pb_begonia-eng
mka recoveryimage   # or: mka pbrp (image plus flashable zip)
```

## Sources

- Device tree base: [Saikrishna1504/device_xiaomi_begonia-pbrp](https://github.com/Saikrishna1504/device_xiaomi_begonia-pbrp) (`3bf5154`, `18dadeb`)
- Recovery: [PitchBlackRecoveryProject/android_bootable_recovery](https://github.com/PitchBlackRecoveryProject/android_bootable_recovery) (`android-12.1`) plus the begonia patch series
- Manifest: [PitchBlackRecoveryProject/manifest_pb](https://github.com/PitchBlackRecoveryProject/manifest_pb) (`android-12.1`)
- Prebuilt kernel (`prebuilt/Image.gz`): built from [krispgece/kernel_xiaomi_mt6785](https://github.com/krispgece/kernel_xiaomi_mt6785) at `e75824e1` (`begonia-16` plus the switch for the permissive blanking), `begonia_user_defconfig` with `CONFIG_BEGONIA_BLANK_PERMISSIVE_CMDLINE` off, clang r563880c (the ROM's)
- dtb and dtbo: built from [begonia-recovery/twrp_kernel_xiaomi_begonia](https://github.com/begonia-recovery/twrp_kernel_xiaomi_begonia) (`twrp-12.1`, `9f08459a`), which earlier builds also used for the kernel; its mt6785 base differs from the ROM kernel's only in the `loop.max_part` boot argument
- Partition values: the ROM's device tree (`device/redmi/begonia`, BoardConfig.mk and fstab.mt6785)

## Credits

- Saikrishna1504 and Shamik: the PBRP begonia device tree, the decryption setup and the
  TEE/keymaster blobs this tree is built on
- The begonia-recovery kernel project: the dtb and dtbo, and the recovery kernel source of the earlier builds
- WuXing90: the idea of one recovery image that picks the partition layout at boot
  (Unified TWRP)
- PitchBlack Recovery Project: PBRP
- Team Win Recovery Project: TWRP, which PBRP is based on
- SebaUbuntu's TWRP device tree generator: the original tree layout

## License

Apache-2.0 (see the SPDX headers); prebuilt blobs belong to their respective owners.
