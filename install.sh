#!/usr/bin/env bash
# dell-8bpc-edid v2 — EDID depth-override installer (GRUB + systemd-boot/kernelstub)
#
# Presents Dell S2721QS monitors to the Nvidia driver as 8 bpc panels by
# installing modified EDID firmware files, embedding them in the initramfs,
# and setting the drm.edid_firmware kernel parameter via the detected
# bootloader backend (GRUB or Pop!_OS kernelstub). Idempotent.
#
# Usage:
#   curl -fsSL <raw-url> | sudo bash
#   sudo ./dell-8bpc-edid.sh [--dry-run|--uninstall [--purge]|--force-count]
#
# Exit codes:
#   0 success | 1 not root | 2 missing dependency/bad arg | 3 monitor count
#   4 EDID validation failure | 5 edid-decode gate failure
#   6 bootloader operation failed | 7 no supported bootloader / missing
#     initramfs tooling | 8 initramfs embed/verification failure
#
# Env overrides (production defaults; overrides double as test seams):
#   EDID_TARGET_NAME EDID_SYSFS_GLOB EDID_FW_DIR EDID_LOG_FILE     (as v1)
#   EDID_GRUB_FILE EDID_UPDATE_GRUB                                 (as v1)
#   EDID_BOOT_BACKEND=grub|kernelstub   force backend selection
#   EDID_KERNELSTUB_CMD     (kernelstub)
#   EDID_KERNELSTUB_CONF    (/etc/kernelstub/configuration)
#   EDID_LOADER_DIR         (/boot/efi/loader/entries)
#   EDID_LOADER_ENTRY       (/boot/efi/loader/entries/Pop_OS-current.conf)
#   EDID_INITRAMFS_HOOK_DIR (/etc/initramfs-tools/hooks)
#   EDID_UPDATE_INITRAMFS   (update-initramfs)
#   EDID_LSINITRAMFS        (lsinitramfs)
#   EDID_INITRD_PATH        (newest /boot/initrd.img*)
#   EDID_BACKUP_DIR         (/var/backups/dell-8bpc-edid)
#   EDID_SKIP_ROOT_CHECK=1  (tests only)

set -euo pipefail

# ---------------------------------------------------------------- constants
TARGET_NAME="${EDID_TARGET_NAME:-DELL S2721QS}"
SYSFS_GLOB="${EDID_SYSFS_GLOB:-/sys/class/drm/card*-DP-*/edid}"
FW_DIR="${EDID_FW_DIR:-/usr/lib/firmware/edid}"
GRUB_FILE="${EDID_GRUB_FILE:-/etc/default/grub}"
UPDATE_GRUB="${EDID_UPDATE_GRUB:-update-grub}"
LOG_FILE="${EDID_LOG_FILE:-/var/log/dell-8bpc-edid.log}"
KS_CMD="${EDID_KERNELSTUB_CMD:-kernelstub}"
KS_CONF="${EDID_KERNELSTUB_CONF:-/etc/kernelstub/configuration}"
LOADER_DIR="${EDID_LOADER_DIR:-/boot/efi/loader/entries}"
LOADER_ENTRY="${EDID_LOADER_ENTRY:-/boot/efi/loader/entries/Pop_OS-current.conf}"
HOOK_DIR="${EDID_INITRAMFS_HOOK_DIR:-/etc/initramfs-tools/hooks}"
UPDATE_INITRAMFS="${EDID_UPDATE_INITRAMFS:-update-initramfs}"
LSINITRAMFS="${EDID_LSINITRAMFS:-lsinitramfs}"
BACKUP_DIR="${EDID_BACKUP_DIR:-/var/backups/dell-8bpc-edid}"
EDID_DECODE="${EDID_DECODE_CMD:-edid-decode}"
APT_GET="${EDID_APT_GET:-apt-get}"
HOOK_FILE="$HOOK_DIR/dell-8bpc-edid"
STAMP="$(date +%Y%m%d-%H%M%S)"

DRY_RUN=0; UNINSTALL=0; PURGE=0; FORCE_COUNT=0; BACKEND=""

# ---------------------------------------------------------------- logging
log()  { printf '%s [dell-8bpc-edid] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
err()  { printf '%s [dell-8bpc-edid][ERROR] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { err "$2 (step: $1)"; exit "$3"; }

# ---------------------------------------------------------------- args
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    --purge)       PURGE=1 ;;
    --force-count) FORCE_COUNT=1 ;;
    *) die "args" "Unknown argument: $arg" 2 ;;
  esac
done

# ---------------------------------------------------------------- preflight
if [[ "${EDID_SKIP_ROOT_CHECK:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
  printf '[dell-8bpc-edid][ERROR] Must run as root (try: sudo).\n' >&2
  exit 1
fi
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
command -v python3 >/dev/null 2>&1 || die "preflight" "python3 is required but not found" 2

ensure_edid_decode() {
  command -v "${EDID_DECODE%% *}" >/dev/null 2>&1 && return 0
  log "edid-decode not found; attempting automatic install via ${APT_GET%% *}"
  if command -v "${APT_GET%% *}" >/dev/null 2>&1; then
    if $APT_GET install -y edid-decode >>"$LOG_FILE" 2>&1 \
       && command -v "${EDID_DECODE%% *}" >/dev/null 2>&1; then
      log "edid-decode installed automatically"
      return 0
    fi
  fi
  die "preflight" "edid-decode is required (validation gate) and could not be auto-installed. Install it manually: apt-get install edid-decode" 2
}

log "=== run start: dry_run=$DRY_RUN uninstall=$UNINSTALL purge=$PURGE force_count=$FORCE_COUNT target='$TARGET_NAME'"

# ---------------------------------------------------------------- backend detection
ks_available() {
  command -v "${KS_CMD%% *}" >/dev/null 2>&1 || return 1
  [[ -e "$KS_CONF" || -d "$LOADER_DIR" ]] || return 1
  return 0
}
grub_available() {
  [[ -f "$GRUB_FILE" ]] || return 1
  command -v "${UPDATE_GRUB%% *}" >/dev/null 2>&1 || return 1
  return 0
}

detect_backend() {
  local ks=no grub=no
  ks_available && ks=yes
  grub_available && grub=yes
  log "backend probe: kernelstub=$ks (cmd='${KS_CMD%% *}', conf='$KS_CONF', loader='$LOADER_DIR') grub=$grub (file='$GRUB_FILE', cmd='${UPDATE_GRUB%% *}')"
  if [[ -n "${EDID_BOOT_BACKEND:-}" ]]; then
    case "$EDID_BOOT_BACKEND" in
      kernelstub) [[ "$ks" == yes ]]   || die "detect" "EDID_BOOT_BACKEND=kernelstub forced but kernelstub not available" 7
                  BACKEND=kernelstub ;;
      grub)       [[ "$grub" == yes ]] || die "detect" "EDID_BOOT_BACKEND=grub forced but GRUB not available" 7
                  BACKEND=grub ;;
      *) die "detect" "Invalid EDID_BOOT_BACKEND='$EDID_BOOT_BACKEND' (use grub|kernelstub)" 2 ;;
    esac
    log "backend: $BACKEND (forced via EDID_BOOT_BACKEND)"
    return
  fi
  if [[ "$ks" == yes && "$grub" == yes ]]; then
    log "WARNING: both kernelstub and GRUB detected; preferring kernelstub (systemd-boot boots Pop!_OS; /etc/default/grub may be an inert package artifact). Override with EDID_BOOT_BACKEND=grub if this machine truly boots via GRUB."
    BACKEND=kernelstub
  elif [[ "$ks" == yes ]];  then BACKEND=kernelstub
  elif [[ "$grub" == yes ]]; then BACKEND=grub
  else
    die "detect" "No supported bootloader found (probed kernelstub and GRUB)" 7
  fi
  log "backend: $BACKEND"
}
detect_backend

# ---------------------------------------------------------------- grub backend
grub_get_cmdline() { grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | tail -1; }
grub_current_value() { grub_get_cmdline | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="?//; s/"?$//'; }
strip_edid_param() { sed -E 's/(^| )drm\.edid_firmware=[^ ]*//g; s/  +/ /g; s/^ //; s/ $//'; }

grub_write_cmdline() {
  local new="$1" backup="${GRUB_FILE}.bak.${STAMP}"
  cp -a "$GRUB_FILE" "$backup"
  log "GRUB backup: $backup"
  log "GRUB line before: $(grub_get_cmdline)"
  python3 - "$GRUB_FILE" "$new" <<'PYEOF'
import re, sys
path, new = sys.argv[1], sys.argv[2]
src = open(path).read()
pat = re.compile(r'^(GRUB_CMDLINE_LINUX_DEFAULT=).*$', re.M)
if not pat.search(src):
    sys.exit("GRUB_CMDLINE_LINUX_DEFAULT not found in " + path)
src = pat.sub(lambda m: m.group(1) + '"' + new + '"', src, count=1)
open(path, 'w').write(src)
PYEOF
  log "GRUB line after:  $(grub_get_cmdline)"
  if ! $UPDATE_GRUB >>"$LOG_FILE" 2>&1; then
    err "update-grub failed. Restore with: cp '$backup' '$GRUB_FILE' && $UPDATE_GRUB"
    exit 6
  fi
  log "update-grub: OK"
}

# ---------------------------------------------------------------- kernelstub backend
ks_current_token() {  # prints existing drm.edid_firmware=... token or nothing
  $KS_CMD -p 2>&1 | grep -oE 'drm\.edid_firmware=[^ "]*' | head -1 || true
}
ks_backup() {
  mkdir -p "$BACKUP_DIR"
  $KS_CMD -p > "$BACKUP_DIR/kernelstub-p.$STAMP" 2>&1 || true
  log "kernelstub -p snapshot: $BACKUP_DIR/kernelstub-p.$STAMP"
  if [[ -f "$LOADER_ENTRY" ]]; then
    cp -a "$LOADER_ENTRY" "$BACKUP_DIR/$(basename "$LOADER_ENTRY").$STAMP"
    log "loader entry backup: $BACKUP_DIR/$(basename "$LOADER_ENTRY").$STAMP"
  fi
}
ks_param_install() {
  local new="$1" old; old="$(ks_current_token)"
  ks_backup
  log "kernelstub param before: ${old:-<none>}"
  if [[ -n "$old" && "$old" != "$new" ]]; then
    if ! $KS_CMD -d "$old" >>"$LOG_FILE" 2>&1; then
      err "kernelstub -d '$old' failed. Previous state snapshot: $BACKUP_DIR/kernelstub-p.$STAMP"
      exit 6
    fi
    log "kernelstub: removed stale token '$old'"
  fi
  if [[ "$old" == "$new" ]]; then
    log "kernelstub: token already current; re-adding for safety (kernelstub dedups)"
  fi
  if ! $KS_CMD -a "$new" >>"$LOG_FILE" 2>&1; then
    err "kernelstub -a '$new' failed. Previous state snapshot: $BACKUP_DIR/kernelstub-p.$STAMP"
    exit 6
  fi
  log "kernelstub param after:  $(ks_current_token)"
}
ks_param_remove() {
  local old; old="$(ks_current_token)"
  if [[ -z "$old" ]]; then log "kernelstub: no drm.edid_firmware token present; nothing to remove"; return; fi
  ks_backup
  if ! $KS_CMD -d "$old" >>"$LOG_FILE" 2>&1; then
    err "kernelstub -d '$old' failed. Previous state snapshot: $BACKUP_DIR/kernelstub-p.$STAMP"
    exit 6
  fi
  log "kernelstub: removed token '$old'"
}

# ---------------------------------------------------------------- param dispatch
param_install() {
  case "$BACKEND" in
    grub)
      [[ -f "$GRUB_FILE" ]] || die "param" "GRUB file not found: $GRUB_FILE" 6
      local cur new; cur="$(grub_current_value)"
      new="$(strip_edid_param <<<"$cur")"; new="${new:+$new }$1"
      grub_write_cmdline "$new" ;;
    kernelstub) ks_param_install "$1" ;;
  esac
}
param_remove() {
  case "$BACKEND" in
    grub)
      [[ -f "$GRUB_FILE" ]] || die "param" "GRUB file not found: $GRUB_FILE" 6
      local cur; cur="$(grub_current_value)"
      if grep -q 'drm\.edid_firmware=' <<<"$cur"; then
        grub_write_cmdline "$(strip_edid_param <<<"$cur")"
        log "Removed drm.edid_firmware parameter from GRUB."
      else
        log "No drm.edid_firmware parameter present; GRUB untouched."
      fi ;;
    kernelstub) ks_param_remove ;;
  esac
}

# ---------------------------------------------------------------- initramfs subsystem
hook_content() {
  cat <<HOOK_EOF
#!/bin/sh
# Installed by dell-8bpc-edid — embeds Dell 8bpc EDID overrides in the initramfs.
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case \$1 in prereqs) prereqs; exit 0 ;; esac
[ -r /usr/share/initramfs-tools/hook-functions ] && . /usr/share/initramfs-tools/hook-functions
mkdir -p "\${DESTDIR}/lib/firmware/edid"
for f in $FW_DIR/dell-*-8bpc.bin; do
  [ -e "\$f" ] || continue
  cp -a "\$f" "\${DESTDIR}/lib/firmware/edid/"
done
exit 0
HOOK_EOF
}

initramfs_tooling_required() {
  command -v "${UPDATE_INITRAMFS%% *}" >/dev/null 2>&1 \
    || die "initramfs" "update-initramfs not found; unsupported environment" 7
}

initrd_path() {
  if [[ -n "${EDID_INITRD_PATH:-}" ]]; then echo "$EDID_INITRD_PATH"; return; fi
  find /boot -maxdepth 1 -name 'initrd.img*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true
}

initramfs_regen() {
  log "running: $UPDATE_INITRAMFS -u"
  if ! $UPDATE_INITRAMFS -u >>"$LOG_FILE" 2>&1; then return 1; fi
  return 0
}

initramfs_embed_and_verify() {  # $@ = expected embedded basenames
  install -m 0755 /dev/stdin "$HOOK_FILE" < <(hook_content)
  log "installed initramfs hook: $HOOK_FILE  sha256=$(sha256sum "$HOOK_FILE" | cut -d' ' -f1)"
  if ! initramfs_regen; then
    err "update-initramfs failed; removing hook and aborting BEFORE bootloader changes."
    rm -f "$HOOK_FILE"
    exit 8
  fi
  if ! command -v "${LSINITRAMFS%% *}" >/dev/null 2>&1; then
    log "WARNING: lsinitramfs not found; skipping embed verification"
    return 0
  fi
  local initrd; initrd="$(initrd_path)"
  if [[ -z "$initrd" ]]; then
    log "WARNING: no initrd image found to verify; skipping embed verification"
    return 0
  fi
  local f listing
  listing="$($LSINITRAMFS "$initrd" 2>>"$LOG_FILE" || true)"
  for f in "$@"; do
    if grep -qF "$f" <<<"$listing"; then
      log "initramfs verify: $f present in $initrd — OK"
    else
      err "initramfs verify FAILED: $f not found in $initrd; removing hook, aborting BEFORE bootloader changes."
      rm -f "$HOOK_FILE"
      $UPDATE_INITRAMFS -u >>"$LOG_FILE" 2>&1 || true
      exit 8
    fi
  done
  return 0
}

# ---------------------------------------------------------------- uninstall
if [[ "$UNINSTALL" -eq 1 ]]; then
  RC=0
  if [[ "$PURGE" -eq 1 ]]; then
    shopt -s nullglob
    for f in "$FW_DIR"/dell-*-8bpc.bin; do rm -f "$f"; log "Purged $f"; done
    shopt -u nullglob
  fi
  if [[ -e "$HOOK_FILE" ]]; then
    rm -f "$HOOK_FILE"; log "Removed initramfs hook: $HOOK_FILE"
    if command -v "${UPDATE_INITRAMFS%% *}" >/dev/null 2>&1; then
      if ! initramfs_regen; then err "update-initramfs failed during uninstall; continuing to remove bootloader parameter."; RC=8; fi
    else
      log "WARNING: update-initramfs not found; initramfs not regenerated"
    fi
  else
    log "No initramfs hook present."
  fi
  param_remove
  log "Uninstall complete (rc=$RC). Reboot to apply."
  exit "$RC"
fi

# ---------------------------------------------------------------- discovery
initramfs_tooling_required
ensure_edid_decode

declare -a M_CONN=() M_SERIAL=() M_FILE=()
shopt -s nullglob
# shellcheck disable=SC2206  # intentional: SYSFS_GLOB must glob-expand; sysfs paths contain no spaces
candidates=( $SYSFS_GLOB )
shopt -u nullglob
[[ ${#candidates[@]} -gt 0 ]] || die "discovery" "No DP connectors found under glob: $SYSFS_GLOB" 3

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for edid_path in "${candidates[@]}"; do
  conn="$(basename "$(dirname "$edid_path")" | sed -E 's/^card[0-9]+-//')"
  # NOTE: sysfs EDID files are binary attributes that stat as size 0 regardless
  # of content; the data only exists when actually read. Never use stat here.
  cp "$edid_path" "$WORK/$conn.orig.bin" 2>/dev/null || : > "$WORK/$conn.orig.bin"
  size=$(wc -c < "$WORK/$conn.orig.bin" 2>/dev/null || echo 0)
  if [[ "$size" -eq 0 ]]; then
    log "connector $conn: no EDID (disconnected) — skipped"; continue
  fi
  info="$(python3 - "$WORK/$conn.orig.bin" <<'PYEOF'
import sys
d = open(sys.argv[1], 'rb').read()
def fail(m): print("INVALID|" + m); sys.exit(0)
if len(d) < 128 or len(d) % 128: fail(f"length {len(d)}")
if d[:8] != bytes.fromhex('00ffffffffffff00'): fail("bad header")
if sum(d[:128]) % 256 != 0: fail("block-0 checksum invalid")
name = serial = ""
for off in range(54, 126, 18):
    blk = d[off:off+18]
    if blk[0:3] == b'\x00\x00\x00':
        text = blk[5:18].split(b'\x0a')[0].decode('ascii', 'replace').strip()
        if blk[3] == 0xFC: name = text
        if blk[3] == 0xFF: serial = text
if not serial: serial = f"{int.from_bytes(d[12:16],'little'):08x}"
depth_bits = (d[20] >> 4) & 0x07
depth = {0:"undef",1:"6",2:"8",3:"10",4:"12",5:"14",6:"16"}.get(depth_bits, "?")
print(f"OK|{name}|{serial}|{d[20]:#04x}|{depth}")
PYEOF
)"
  IFS='|' read -r status name serial byte20 depth <<<"$info"
  if [[ "$status" != "OK" ]]; then
    log "connector $conn: EDID invalid ($name) — skipped"; continue
  fi
  if [[ "$name" != "$TARGET_NAME" ]]; then
    log "connector $conn: '$name' (serial $serial) — not target — skipped"; continue
  fi
  log "connector $conn: MATCH '$name' serial=$serial byte20=$byte20 depth=${depth}bpc"
  M_CONN+=("$conn"); M_SERIAL+=("$serial")
done

count=${#M_CONN[@]}
log "matched monitors: $count (expected 2)"

diag_connectors() {
  log "--- discovery diagnostics ---"
  local p conn card drv sz
  for p in "${candidates[@]}"; do
    conn="$(basename "$(dirname "$p")")"
    card="${conn%%-*}"
    drv="$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    sz="$(wc -c < "$p" 2>/dev/null || echo '?')"
    log "  $conn: edid_read_bytes=$sz driver=${drv:-unknown}"
  done
  if command -v nvidia-smi >/dev/null 2>&1; then
    local smi; smi="$(nvidia-smi 2>&1 | head -3 || true)"
    log "  nvidia-smi: $(head -1 <<<"$smi")"
    if grep -qi 'version mismatch' <<<"$smi"; then
      log "  HINT: Nvidia driver/library version mismatch — a driver update is pending activation. REBOOT and re-run this script."
    fi
  else
    log "  nvidia-smi: not present"
  fi
  log "  HINT: monitors must be connected, powered on, and driven by a functional GPU driver when this script runs."
  log "--- end diagnostics ---"
}

if [[ "$count" -ne 2 && "$FORCE_COUNT" -ne 1 ]]; then
  diag_connectors
  die "discovery" "Expected exactly 2 matched '$TARGET_NAME' monitors, found $count. Use --force-count to override." 3
fi
[[ "$count" -ge 1 ]] || die "discovery" "Nothing to do: 0 matched monitors." 3

# ---------------------------------------------------------------- modify
for i in "${!M_CONN[@]}"; do
  conn="${M_CONN[$i]}"; serial="${M_SERIAL[$i]}"
  safe_serial="$(tr -cd 'A-Za-z0-9._-' <<<"$serial")"
  out="$WORK/dell-s2721qs-${safe_serial}-8bpc.bin"
  result="$(python3 - "$WORK/$conn.orig.bin" "$out" <<'PYEOF'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
old20, oldck = d[20], d[127]
d[20] = (d[20] & 0x8F) | 0x20            # bits 6-4 := 010 (8 bpc)
d[127] = (256 - sum(d[0:127]) % 256) % 256
open(sys.argv[2], 'wb').write(d)
print(f"{old20:#04x}->{d[20]:#04x}|{oldck:#04x}->{d[127]:#04x}|{'nochange' if old20==d[20] else 'changed'}")
PYEOF
)"
  IFS='|' read -r b20chg ckchg changed <<<"$result"
  if [[ "$changed" == "nochange" ]]; then
    log "connector $conn: already 8 bpc — no modification needed (will still install)"
  else
    log "connector $conn: byte20 $b20chg checksum $ckchg"
  fi
  # Differential conformity gate: vendor EDIDs often fail edid-decode's
  # pedantic checks AS SHIPPED (and strictness varies by edid-decode version),
  # so we do not demand absolute PASS — we demand 8 bpc and NO NEW failures
  # relative to the unmodified original.
  extract_failures() { sed -n '/^Failures:/,/^EDID conformity/p' <<<"$1" | grep -v -e '^Failures:' -e '^EDID conformity' -e '^[[:space:]]*$' | sort -u; }
  orig_dec="$($EDID_DECODE --check "$WORK/$conn.orig.bin" 2>&1 || true)"
  mod_dec="$($EDID_DECODE --check "$out" 2>&1 || true)"
  grep -q 'Bits per primary color channel: 8' <<<"$mod_dec" \
    || die "edid-decode" "connector $conn: modified EDID does not report 8 bpc" 5
  if grep -q 'EDID conformity: PASS' <<<"$mod_dec"; then
    log "connector $conn: edid-decode gate PASS (8 bpc, fully conformant)"
  else
    orig_f="$(extract_failures "$orig_dec")"
    mod_f="$(extract_failures "$mod_dec")"
    new_f="$(grep -Fxv -f <(printf '%s\n' "$orig_f") <(printf '%s\n' "$mod_f") || true)"
    if [[ -z "$new_f" ]]; then
      log "connector $conn: edid-decode gate PASS (8 bpc; $(wc -l <<<"$orig_f") pre-existing nonconformity line(s) unchanged from original)"
    else
      mkdir -p "$BACKUP_DIR"
      cp "$WORK/$conn.orig.bin" "$BACKUP_DIR/$conn.orig.$STAMP.bin"
      cp "$out" "$BACKUP_DIR/$conn.modified.$STAMP.bin"
      err "connector $conn: modification introduced NEW conformity failures:"
      while IFS= read -r l; do err "  NEW: $l"; done <<<"$new_f"
      die "edid-decode" "connector $conn: gate failed; originals preserved in $BACKUP_DIR for inspection" 5
    fi
  fi
  M_FILE+=("$(basename "$out")")
done

# ---------------------------------------------------------------- build kernel param
param="drm.edid_firmware="
sep=""
for i in "${!M_CONN[@]}"; do
  param+="${sep}${M_CONN[$i]}:edid/${M_FILE[$i]}"
  sep=","
done
log "kernel parameter: $param"

# ---------------------------------------------------------------- dry-run
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "--dry-run: backend=$BACKEND"
  log "--dry-run: would install to $FW_DIR: ${M_FILE[*]}"
  for i in "${!M_CONN[@]}"; do
    log "--dry-run: $FW_DIR/${M_FILE[$i]}  sha256=$(sha256sum "$WORK/${M_FILE[$i]}" | cut -d' ' -f1)"
  done
  log "--dry-run: would write hook $HOOK_FILE with content:"
  hook_content | sed 's/^/    | /' | tee -a "$LOG_FILE"
  log "--dry-run: would run: $UPDATE_INITRAMFS -u  (then verify via ${LSINITRAMFS%% *})"
  case "$BACKEND" in
    grub)
      [[ -f "$GRUB_FILE" ]] && log "--dry-run: GRUB line would become: GRUB_CMDLINE_LINUX_DEFAULT=\"$(strip_edid_param <<<"$(grub_current_value)") $param\"" ;;
    kernelstub)
      old="$(ks_current_token)"
      [[ -n "$old" && "$old" != "$param" ]] && log "--dry-run: would run: $KS_CMD -d '$old'"
      log "--dry-run: would run: $KS_CMD -a '$param'" ;;
  esac
  log "--dry-run complete; nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------- install
# Order per spec: firmware -> hook -> initramfs regen+verify -> bootloader param.
mkdir -p "$FW_DIR"
for i in "${!M_CONN[@]}"; do
  dst="$FW_DIR/${M_FILE[$i]}"
  if [[ -e "$dst" ]]; then
    cp -a "$dst" "$dst.bak.$STAMP"; log "backed up existing $dst -> $dst.bak.$STAMP"
  fi
  install -m 0644 "$WORK/${M_FILE[$i]}" "$dst"
  log "installed $dst  sha256=$(sha256sum "$dst" | cut -d' ' -f1)"
done

mkdir -p "$HOOK_DIR"
initramfs_embed_and_verify "${M_FILE[@]}"

param_install "$param"

# ---------------------------------------------------------------- summary
log "=== SUMMARY ==="
log "  bootloader: $BACKEND"
for i in "${!M_CONN[@]}"; do
  log "  ${M_CONN[$i]}  serial=${M_SERIAL[$i]}  -> $FW_DIR/${M_FILE[$i]}"
done
log "  initramfs hook: $HOOK_FILE (embedded: ${M_FILE[*]})"
log "  kernel parameter set: $param"
if [[ "$BACKEND" == kernelstub ]]; then
  log "  NOTE: parameter is stored in kernelstub's config; manual 'kernelstub -o' calls can override it."
fi
log "  NOTE: connector names (${M_CONN[*]}) are driver-assigned and can change"
log "        across driver/GPU-mode changes; re-run this script if they do."
log "  REBOOT REQUIRED to apply."
log "  Revert: re-run with --uninstall (add --purge to delete firmware files)."
log "=== run complete (success) ==="
