# edid_setup

Force **8 bpc (24-bit) color** on Dell S2721QS monitors under Linux with the Nvidia proprietary driver, by installing modified EDID firmware that removes the panels' 10-bit capability claim.

## Why this exists

The Nvidia Linux driver drives DisplayPort links at **10 bpc** whenever a monitor's EDID advertises it — and on Wayland it exposes **no user-facing control** to lower it (no `max bpc` DRM property; compositor depth preferences are ignored; the Windows driver defaults the same links to 8 bpc). On marginal display chains — in my case, one DP output of a Thunderbolt 3 dock — the extra link bandwidth of 10-bit can manifest as intermittent screen corruption that is impossible to reproduce under Windows.

Since the driver can't be told to use 8-bit, this project tells the driver the monitor can't *do* 10-bit: it captures each monitor's EDID live from sysfs, flips the color-depth field (byte 20, bits 6–4) from 10 bpc to 8 bpc, fixes the checksum, and loads the modified EDID at boot via the kernel's `drm.edid_firmware` mechanism.

## What it does

1. **Discovers** connected DP outputs in `/sys/class/drm/` and matches monitors by EDID product name (`DELL S2721QS` by default)
2. **Modifies** each matched EDID: byte 20 → 8 bpc, block-0 checksum recomputed, extension blocks untouched
3. **Validates** with `edid-decode --check` (must report 8 bpc and full conformity) before anything is installed
4. **Installs** the firmware files to `/usr/lib/firmware/edid/`
5. **Embeds** them in the initramfs (hook + `update-initramfs`), verified with `lsinitramfs` — required because the EDID is read too early in boot for the root filesystem to be available on some setups
6. **Sets the kernel parameter** `drm.edid_firmware=DP-X:edid/...,DP-Y:edid/...` via the detected bootloader:
   - **GRUB** (`/etc/default/grub` + `update-grub`) — e.g. TUXEDO OS, Ubuntu, Mint
   - **systemd-boot via kernelstub** — Pop!_OS

Everything is idempotent (safe to re-run), verbosely logged to `/var/log/dell-8bpc-edid.log`, and backed up before mutation (GRUB file, kernelstub state snapshot, loader entry, overwritten firmware).

## Usage

```bash
# Fresh install (review first — you are piping a script into root bash)
curl -fsSL https://raw.githubusercontent.com/<user>/edid_setup/main/dell-8bpc-edid.sh | sudo bash

# Or download, inspect, run
sudo ./dell-8bpc-edid.sh --dry-run    # show exactly what would be done, change nothing
sudo ./dell-8bpc-edid.sh              # install
sudo reboot
```

Both monitors must be **connected and powered on** when you run it (the EDID is read live), and the Nvidia driver must be functional — check that `nvidia-smi` prints a table first. In particular, **reboot after any Nvidia driver update before running**: in the post-update, pre-reboot state (`Failed to initialize NVML: Driver/library version mismatch`) the GPU's connectors expose no EDIDs and discovery will correctly find nothing. If discovery fails, the script logs per-connector diagnostics (EDID bytes read, owning driver, nvidia-smi state) to tell you why.

### Verify after reboot

```bash
edid-decode /sys/class/drm/card*-DP-*/edid | grep -i "bits per primary"
# Expect: Bits per primary color channel: 8   (for each overridden output)
```

### Uninstall

```bash
sudo ./dell-8bpc-edid.sh --uninstall           # remove kernel param + initramfs hook
sudo ./dell-8bpc-edid.sh --uninstall --purge   # also delete the firmware files
sudo reboot
```

### Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Full discovery/modification/validation in a temp dir; prints the complete plan (files, hook content, bootloader commands); zero system changes |
| `--uninstall` | Reverts the install (see above) |
| `--purge` | With `--uninstall`: also deletes installed firmware files |
| `--force-count` | Proceed even if the number of matched monitors ≠ 2 |

### Exit codes

`0` success · `1` not root · `2` missing dependency / bad argument · `3` monitor count mismatch · `4` EDID validation failure · `5` edid-decode gate failure · `6` bootloader operation failed · `7` no supported bootloader / missing initramfs tooling · `8` initramfs embed or verification failure

### Configuration (environment variables)

Different monitor? Set `EDID_TARGET_NAME` to the product name exactly as it appears in `edid-decode` output (`Display Product Name`). Force a bootloader with `EDID_BOOT_BACKEND=grub|kernelstub` if auto-detection picks wrong on a dual-bootloader system. All paths and external commands are overridable — see the header of the script for the full list.

## Requirements

- Ubuntu-family distro with `initramfs-tools` (tested targets: TUXEDO OS 24.04 base, Pop!_OS)
- `bash`, `python3`, `update-initramfs`, `edid-decode` — edid-decode is **required** (it is the validation gate); on apt systems the script installs it automatically, otherwise it exits cleanly at preflight with instructions
- Nvidia proprietary driver with DRM modesetting (`nvidia_drm`) — the `drm.edid_firmware` override is honored on driver series ~570+

## Caveats

- **Connector names can change.** The kernel parameter binds to connector names (`DP-2`, `DP-3`), which are driver-assigned and may shift after driver upgrades or GPU-mode (MUX) changes. If the override stops applying or targets the wrong output, just re-run the script — it re-discovers and replaces the parameter.
- **You lose 10-bit output** on the overridden monitors. For SDR desktop use this matches what Windows does by default on the same hardware.
- **Safety design:** the bootloader parameter is written *last*, only after the firmware files are installed, embedded in the initramfs, and verified present — a failed step aborts before the boot configuration is touched, and every mutation is preceded by a timestamped backup.
- Arch/Fedora (mkinitcpio/dracut) and non-kernelstub systemd-boot setups are out of scope.

## Repository contents

- `dell-8bpc-edid.sh` — the installer (self-contained; no network access at runtime)

## License / warranty

Provided as-is; it edits your boot configuration — read `--dry-run` output before committing, and know your recovery route (boot menu → previous kernel / remove the `drm.edid_firmware` parameter).
