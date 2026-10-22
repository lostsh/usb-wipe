#!/usr/bin/env bash
# usb-wipe.sh: wipe an external USB disk (HDD or SSD) before giving it back, verify the
# wipe, reformat the disk as exFAT and write a report. Methods follow NIST SP 800-88:
# overwrite for hard disks, the drive's own Sanitize command for SSDs, destruction when
# neither can be done reliably.
#
# Run it on Ubuntu (installed or live USB), only after the files to keep have been
# copied off the disk. Copy this script onto the computer itself and unplug every USB
# disk except the one to wipe.
#
#   sudo apt install -y hdparm exfatprogs
#   sudo ./usb-wipe.sh                 find the disk, wipe it, verify, reformat
#   sudo ./usb-wipe.sh --verify-only   after an SSD was erased with the manufacturer's tool
#
# HDD: shred -n 1 -z (one random pass, then zeros).
# SSD: the SSD's built-in ATA Sanitize, sent over USB with hdparm. When the USB adapter
#      or the SSD does not support it, the script names the manufacturer's tool instead.
# Verification: 5 samples of the raw disk are fingerprinted before the wipe; afterwards,
# every sample that held data must have changed.
#
# Exit codes: 0 done, 1 stopped, 2 manufacturer's tool needed, 3 disk must be destroyed.

set -euo pipefail

SAMPLE_MIB=256                                   # size of each raw-read sample
BASIC_DATA=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7  # GPT partition type used for exFAT

MODE=wipe DISK="" MODEL="" SERIAL="" SIZE="" KIND="" ATA="" SANITIZE="" METHOD="" REPORT="" TMP=""
declare -A BASE_SHA=() BASE_DATA=()

say() { printf '%s\n' "$*" | tee -a "${REPORT:-/dev/null}"; }
die() { local code=$1; shift; say "STOP: $*"; exit "$code"; }
ask() { local answer; read -r -p "$1 " answer </dev/tty; printf '%s' "$answer"; }
squeeze() { awk '{$1=$1};1'; }                   # trim and collapse spaces

check_prerequisites() {
  [[ $EUID -eq 0 ]] || die 1 "Run the script with sudo."
  local tool missing=()
  for tool in hdparm shred sfdisk mkfs.exfat udevadm; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || die 1 "Missing ${missing[*]}. Install with: sudo apt install -y hdparm exfatprogs"
}

# A disk is protected when it runs the system: a partition mounted outside /media (where
# Ubuntu mounts external disks), active swap ([SWAP]), or a live USB stick (iso9660).
is_protected() {
  local mounts fstypes other
  mounts=$(lsblk -nrpo MOUNTPOINT "$1")
  fstypes=$(lsblk -nrpo FSTYPE "$1")
  grep -qx iso9660 <<<"$fstypes" && return 0
  other=$(grep -c -v -e '^$' -e '^/media/' -e '^/run/media/' <<<"$mounts" || true)
  (( other > 0 ))
}

find_disk() {
  local name tran type bytes found=()
  while read -r name tran type; do
    [[ $tran == usb && $type == disk ]] || continue
    bytes=$(blockdev --getsize64 "$name" 2>/dev/null || echo 0)
    (( bytes > 0 )) || continue                  # card reader without a card
    is_protected "$name" && continue
    found+=("$name")
  done < <(lsblk -dnrpo NAME,TRAN,TYPE)
  case ${#found[@]} in
    0) die 1 "No external USB disk found. Plug the disk in and run the script again." ;;
    1) DISK=${found[0]} ;;
    *) die 1 "Several USB disks found (${found[*]}). Unplug all of them except the one to wipe." ;;
  esac
}

identify_disk() {
  SIZE=$(lsblk -dno SIZE "$DISK" | squeeze)
  MODEL=$(lsblk -dno VENDOR,MODEL "$DISK" | squeeze)
  SERIAL=$(lsblk -dno SERIAL "$DISK" | squeeze)
  # Over USB, hdparm only answers when the adapter passes ATA commands through (SATA disks).
  ATA=$(timeout 30 hdparm -I "$DISK" 2>/dev/null || true)
  if grep -q 'Model Number:' <<<"$ATA"; then
    MODEL=$(sed -n 's/^[[:space:]]*Model Number:[[:space:]]*//p' <<<"$ATA" | squeeze)
    SERIAL=$(sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' <<<"$ATA" | squeeze)
  else
    ATA=
  fi
  if grep -q 'Rotation Rate: Solid State Device' <<<"$ATA"; then KIND=SSD
  elif grep -Eq 'Rotation Rate: [0-9]+' <<<"$ATA"; then KIND=HDD
  elif [[ $MODE == wipe ]]; then
    KIND=$(ask "Cannot tell whether $MODEL ($SIZE) is an HDD or an SSD. Check its label, then type HDD or SSD:")
    KIND=${KIND^^}
    [[ $KIND == HDD || $KIND == SSD ]] || die 1 "Answer HDD or SSD. Nothing was erased."
  fi
}

disk_bytes() { blockdev --getsize64 "$DISK"; }

offsets() {                                      # start, 25 %, 50 %, 75 % and end, in MiB
  local last=$(( $(disk_bytes) / 1048576 - SAMPLE_MIB ))
  (( last > 0 )) || last=0
  echo 0 $(( last / 4 )) $(( last / 2 )) $(( last * 3 / 4 )) "$last"
}

# Read SAMPLE_MIB at offset $1 (MiB), bypassing the page cache.
# Prints "<sha256> <data bytes>", data bytes being the bytes other than 0x00 and 0xFF.
scan() {
  dd if="$DISK" of="$TMP" bs=1M count="$SAMPLE_MIB" skip="$1" iflag=direct status=none || return 1
  printf '%s %s\n' "$(sha256sum <"$TMP" | cut -d' ' -f1)" "$(tr -d '\000\377' <"$TMP" | wc -c)"
}

baseline() {
  local off sha data held=0
  for off in $(offsets); do
    read -r sha data < <(scan "$off") || die 1 "Cannot read $DISK. Nothing was erased."
    BASE_SHA[$off]=$sha BASE_DATA[$off]=$data
    (( data == 0 )) || held=$(( held + 1 ))
  done
  say "Before the wipe: $held of 5 samples hold data."
}

# The fingerprint is kept on disk when the erase happens outside this script (--verify-only).
baseline_file() { echo "$PWD/usb-wipe-baseline-${SERIAL//[^A-Za-z0-9_-]/_}.txt"; }

save_baseline() {
  local off file
  file=$(baseline_file)
  for off in "${!BASE_SHA[@]}"; do echo "$off ${BASE_SHA[$off]} ${BASE_DATA[$off]}"; done >"$file"
  [[ -z ${SUDO_USER:-} ]] || chown "$SUDO_USER:" "$file"
}

load_baseline() {
  local off sha data file
  file=$(baseline_file)
  [[ -f $file ]] || die 1 "No fingerprint from before the erase ($file). Run the script without --verify-only before using the manufacturer's tool."
  while read -r off sha data; do BASE_SHA[$off]=$sha BASE_DATA[$off]=$data; done <"$file"
}

# A sample passes when it changed since the fingerprint taken before the wipe, or when it
# held no data before (an empty area may read back identical).
verify() {
  local off sha data verdict ok=0
  blockdev --flushbufs "$DISK" 2>/dev/null || true
  for off in $(offsets); do
    if ! read -r sha data < <(scan "$off"); then
      say "  offset $off MiB: FAIL, read error"; ok=1; continue
    fi
    if [[ -z ${BASE_SHA[$off]:-} ]]; then verdict="FAIL, no fingerprint from before the wipe"
    elif [[ $sha != "${BASE_SHA[$off]}" ]]; then verdict="PASS, changed"
    elif (( BASE_DATA[$off] == 0 )); then verdict="PASS, empty before and after"
    else verdict="FAIL, unchanged"
    fi
    say "  offset $off MiB: $verdict"
    [[ $verdict == PASS* ]] || ok=1
  done
  return "$ok"
}

# Built-in Sanitize method of the SSD: crypto scramble (seconds), else block erase (minutes).
sanitize_method() {
  grep -q 'SANITIZE feature set' <<<"$ATA" || return 1
  if grep -q 'CRYPTO_SCRAMBLE_EXT command' <<<"$ATA"; then echo crypto-scramble
  elif grep -q 'BLOCK_ERASE_EXT command' <<<"$ATA"; then echo block-erase
  else return 1
  fi
}

vendor_tool() {
  local tool="the manufacturer's SSD tool (Secure Erase or Sanitize option)"
  case ${MODEL,,} in
    *samsung*) tool="Samsung Magician, option Secure Erase: https://semiconductor.samsung.com/consumer-storage/support/tools/" ;;
    *sandisk*|*wd*|*western*) tool="SanDisk Dashboard, option Erase Drive or Sanitize: https://www.sandisk.com/topics/upgrades/drive-monitoring-sandisk-dashboard" ;;
    *crucial*|*micron*) tool="Crucial Storage Executive, option Sanitize Drive: https://www.crucial.com/support/storage-executive" ;;
    *kingston*) die 3 "Kingston SSD Manager does not support USB drives: this SSD cannot be erased reliably and must be destroyed." ;;
  esac
  baseline
  save_baseline
  say "This SSD cannot be erased from Linux through this USB connection."
  say "1. On a Windows computer, erase it with $tool"
  say "2. Plug it back here and run: sudo $0 --verify-only (keep $(baseline_file) next to it)"
  say "If the tool has no erase option for this SSD, the SSD must be destroyed."
  exit 2
}

check_ssd() {
  local status
  SANITIZE=$(sanitize_method) || vendor_tool
  status=$(hdparm --sanitize-status "$DISK" 2>&1 || true)
  [[ ${status,,} != *frozen* ]] || die 1 "The SSD is frozen. Unplug it, plug it back in, then run the script again."
}

confirm() {
  local source=drive token=ERASE hint="" answer
  [[ -n $ATA ]] || source="USB adapter, may differ from the label"
  say "Disk: $DISK | $MODEL | $SIZE | ${KIND:-type unknown} | serial ${SERIAL:-unknown} ($source)"
  [[ $MODE == wipe && $KIND == SSD ]] && say "SSD over USB: a faulty USB adapter can leave the SSD unusable."
  if (( ${#SERIAL} >= 4 )); then token=${SERIAL: -4} hint=" (end of the serial number)"; fi
  answer=$(ask "Everything on this disk will be erased. The files to keep must already be copied off it. Type '$token'$hint to continue:")
  [[ $answer == "$token" ]] || die 1 "Confirmation does not match. Nothing was erased."
}

unmount_disk() {
  local part
  for part in $(lsblk -nrpo NAME "$DISK"); do umount "$part" 2>/dev/null || true; done
  [[ -z $(lsblk -nrpo MOUNTPOINT "$DISK" | tr -d '\n') ]] || die 1 "Cannot unmount $DISK. Close any window using it and try again."
}

wipe_hdd() {
  METHOD="shred -n 1 -z: one random pass, then zeros"
  say "Wiping with $METHOD. Expect 4 to 6 hours per TB. Do not unplug the disk."
  shred -v -n 1 -z "$DISK"
}

wipe_ssd() {
  local status tries=0
  METHOD="ATA Sanitize $SANITIZE (hdparm over USB)"
  say "Erasing with $METHOD. Do not unplug the SSD."
  hdparm --yes-i-know-what-i-am-doing "--sanitize-$SANITIZE" "$DISK" >/dev/null || return 1
  while (( tries++ < 1440 )); do                 # poll every 5 s for up to 2 hours
    sleep 5
    status=$(hdparm --sanitize-status "$DISK" 2>&1 || true)
    case $status in
      *"In Process"*) printf '\r  in progress %s' "$(grep -o '[0-9]*%' <<<"$status" || true)" ;;
      *"Completed Without Error"*|*succeeded*) echo; return 0 ;;
      *) echo; say "$status"; return 1 ;;
    esac
  done
  return 1
}

# If the verification fails, the wipe is repeated once; a second failure means destruction.
wipe_and_verify() {
  local attempt
  for attempt in 1 2; do
    if ! "wipe_${KIND,,}"; then say "Attempt $attempt: the wipe command failed."; continue; fi
    say "Verification, attempt $attempt:"
    verify && return 0
  done
  die 3 "The wipe failed twice: the disk must be physically destroyed. Do not return it."
}

reformat() {
  local part
  say "Reformatting as exFAT, label PERSONAL."
  printf 'label: gpt\ntype=%s, name="PERSONAL"\n' "$BASIC_DATA" | sfdisk --quiet --wipe always "$DISK" \
    || die 1 "Could not create the partition. The disk is wiped; format it manually."
  udevadm settle || true
  part=$(lsblk -nrpo NAME "$DISK" | sed -n 2p)
  mkfs.exfat -L PERSONAL "$part" >/dev/null || die 1 "Could not format $part. The disk is wiped; format it manually."
}

main() {
  case ${1:-} in
    "") ;;
    --verify-only) MODE=verify ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die 1 "Unknown option '$1'. See --help." ;;
  esac
  check_prerequisites
  local ticket operator
  ticket=$(ask "Ticket or reference number:")
  operator=$(ask "Your name:")
  REPORT="$PWD/wipe-report-${ticket//[^A-Za-z0-9_-]/_}-$(date +%Y%m%d-%H%M%S).txt"
  TMP=$(mktemp -p /dev/shm 2>/dev/null || mktemp)
  trap 'rm -f "$TMP"; [[ -z ${SUDO_USER:-} ]] || chown "$SUDO_USER:" "$REPORT" 2>/dev/null' EXIT

  say "Disk wipe report"
  say "Ticket: $ticket | Operator: $operator | Date: $(date -Is) | Computer: $(hostname) | Mode: $MODE"
  find_disk
  identify_disk
  if [[ $MODE == verify ]]; then load_baseline; elif [[ $KIND == SSD ]]; then check_ssd; fi
  confirm
  unmount_disk
  if [[ $MODE == verify ]]; then
    METHOD="manufacturer's tool, before this script"
    say "Verification:"
    verify || die 1 "Data unchanged: erase it once more with the manufacturer's tool. If this check fails again, the disk must be destroyed."
  else
    baseline
    wipe_and_verify
  fi
  reformat
  say "RESULT: PASS. Wiped ($METHOD), verified, reformatted as exFAT."
  say "Next: copy the files to keep back onto the disk and attach this report to the ticket: $REPORT"
}

[[ ${BASH_SOURCE[0]} != "$0" ]] || main "$@"
