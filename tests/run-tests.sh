#!/usr/bin/env bash
# Tests for usb-wipe.sh. System commands (lsblk, hdparm, blockdev, sfdisk...) are mocked
# and a 32 MiB image file stands in for the disk: no real device is ever touched.
# Test bodies are single-quoted for eval (SC2016) and mocks are called indirectly (SC2317).
# shellcheck disable=SC2016,SC2317
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d -p "$HERE")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=usb-wipe.sh
source "$HERE/../usb-wipe.sh"
set +e
SAMPLE_MIB=2
TMP=$WORK/sample
PASSED=0 FAILED=0

# ---- mocks ---------------------------------------------------------------------------
declare -A M_TRAN M_MOUNTS M_FSTYPES M_BYTES M_MODEL M_SERIAL M_PART
DISKS=() HDPARM_I="" STATUS_SEQ=() SANITIZE_RC=0 SANITIZE_EFFECT=none ANS_KIND=ssd ANS_TOKEN=""

lsblk() {
  local cols="" dev="" next=0 a d
  for a in "$@"; do
    if (( next )); then cols=$a; next=0
    elif [[ $a == -*o ]]; then next=1
    elif [[ $a == /* ]]; then dev=$a; fi
  done
  case $cols in
    NAME,TRAN,TYPE) for d in "${DISKS[@]}"; do echo "$d ${M_TRAN[$d]} disk"; done ;;
    MOUNTPOINT) printf '%s\n' "${M_MOUNTS[$dev]:-}" ;;
    FSTYPE) printf '%s\n' "${M_FSTYPES[$dev]:-}" ;;
    SIZE) echo "  32M" ;;
    VENDOR,MODEL) echo "${M_MODEL[$dev]:-Generic   Disk  }" ;;
    SERIAL) echo "${M_SERIAL[$dev]:-}" ;;
    NAME) echo "$dev"; [[ -z ${M_PART[$dev]:-} ]] || echo "${M_PART[$dev]}" ;;
  esac
}
blockdev() {
  case $1 in
    --getsize64) if [[ -f $2 ]]; then stat -c %s "$2"; else echo "${M_BYTES[$2]:-1000204886016}"; fi ;;
  esac
}
hdparm() {
  case "$*" in
    "-I "*) [[ -n $HDPARM_I ]] || return 5; printf '%s\n' "$HDPARM_I" ;;
    "--sanitize-status "*)
      local n; n=$(cat "$WORK/n" 2>/dev/null || echo 0); echo $(( n + 1 )) >"$WORK/n"
      printf '%b\n' "${STATUS_SEQ[$n]:-${STATUS_SEQ[-1]}}" ;;
    *--sanitize-*)
      echo "hdparm $*" >>"$WORK/calls"
      [[ $SANITIZE_EFFECT == random ]] && dd if=/dev/urandom of="$DISK" bs=1M count=32 conv=notrunc status=none
      return "$SANITIZE_RC" ;;
  esac
}
timeout() { shift; "$@"; }
sleep() { :; }
umount() { :; }
udevadm() { :; }
hostname() { echo testhost; }
sfdisk() { cat >"$WORK/sfdisk-input"; echo "sfdisk $*" >>"$WORK/calls"; }
mkfs.exfat() { echo "mkfs.exfat $*" >>"$WORK/calls"; }
check_prerequisites() { :; }
ask() {
  case $1 in
    *Ticket*) echo "T-42" ;;
    *name*) echo "Test Operator" ;;
    *"HDD or an SSD"*) echo "$ANS_KIND" ;;
    *Type*) echo "$ANS_TOKEN" ;;
  esac
}

# ---- fixtures ------------------------------------------------------------------------
SSD_CRYPTO=$'\tModel Number:       Samsung SSD 870 EVO 1TB\n\tSerial Number:      S5Y1NJ0R123456X\n\tNominal Media Rotation Rate: Solid State Device\n\t   *\tBLOCK_ERASE_EXT command\n\t   *\tCRYPTO_SCRAMBLE_EXT command\n\t   *\tSANITIZE feature set'
SSD_BLOCK=$'\tModel Number:       Crucial CT500MX500\n\tSerial Number:      2045E4C1A2B3\n\tNominal Media Rotation Rate: Solid State Device\n\t   *\tBLOCK_ERASE_EXT command\n\t   *\tSANITIZE feature set'
SSD_NO_SANITIZE=$'\tModel Number:       SanDisk SDSSDA240G\n\tSerial Number:      170552800123\n\tNominal Media Rotation Rate: Solid State Device'
HDD=$'\tModel Number:       WDC WD10JMVW-11AJGS4\n\tSerial Number:      WD-WXA1A97F1234\n\tNominal Media Rotation Rate: 5400'
IDLE='Sanitize status:\n    State:    SD0 Sanitize Idle'
RUNNING='Sanitize status:\n    State:    SD2 Sanitize operation In Process\n    Progress: 0x5a3b (35%)'
DONE='Sanitize status:\n    State:    SD0 Sanitize Idle\n    Last Sanitize Operation Completed Without Error'
FAILED_ST='Sanitize status:\n    State:    SD3 Sanitize Operation Failed'
FROZEN='Sanitize status:\n    State:    SD1 Sanitize Frozen'

reset() {
  M_TRAN=() M_MOUNTS=() M_FSTYPES=() M_BYTES=() M_MODEL=() M_SERIAL=() M_PART=()
  DISKS=() HDPARM_I="" STATUS_SEQ=("$IDLE") SANITIZE_RC=0 SANITIZE_EFFECT=none ANS_KIND=ssd ANS_TOKEN=""
  MODE=wipe DISK="" MODEL="" SERIAL="" KIND="" ATA="" SANITIZE="" METHOD="" REPORT=""
  BASE_SHA=() BASE_DATA=()
  rm -f "$WORK/n" "$WORK/calls" "$WORK/sfdisk-input" "$WORK"/wipe-report-* "$WORK"/usb-wipe-baseline-*
}
# 32 MiB disk image filled with random data (default), zeros or 0xFF.
usb_image() {
  DISK=$WORK/disk.img
  case ${1:-random} in
    random) head -c 33554432 /dev/urandom >"$DISK" ;;
    zeros) head -c 33554432 /dev/zero >"$DISK" ;;
    ff) head -c 33554432 /dev/zero | tr '\000' '\377' >"$DISK" ;;
  esac
  DISKS=("$DISK"); M_TRAN[$DISK]=usb; M_PART[$DISK]=$DISK-part1
  IMG_SHA=$(sha256sum <"$DISK")
}
scramble() { dd if=/dev/urandom of="$DISK" bs=1M count=32 conv=notrunc status=none; }
untouched() { [[ $(sha256sum <"$WORK/disk.img") == "$IMG_SHA" ]]; }

# ---- runner --------------------------------------------------------------------------
# run <name> <expected exit code> <command...>: runs in a subshell with set -euo pipefail.
run() {
  local name=$1 want=$2; shift 2
  ( set -euo pipefail; cd "$WORK"; "$@" ) >"$WORK/out" 2>&1
  local rc=$?
  if (( rc == want )); then echo "ok   $name"; PASSED=$(( PASSED + 1 ))
  else echo "FAIL $name (exit $rc, expected $want)"; sed 's/^/       /' "$WORK/out"; FAILED=$(( FAILED + 1 )); fi
}
expect() {   # expect <name> <pattern> <file>
  if grep -Eq -- "$2" "$3" 2>/dev/null; then echo "ok   $1"; PASSED=$(( PASSED + 1 ))
  else echo "FAIL $1: /$2/ not in $3"; sed 's/^/       /' "$3" 2>/dev/null; FAILED=$(( FAILED + 1 )); fi
}
eq() { [[ $1 == "$2" ]] || { echo "got '$1', expected '$2'"; return 1; }; }

# ---- find_disk -----------------------------------------------------------------------
live_session() {
  DISKS=(/dev/nvme0n1 /dev/sda /dev/sdb)
  M_TRAN=([/dev/nvme0n1]=nvme [/dev/sda]=usb [/dev/sdb]=usb)
  M_MOUNTS=([/dev/nvme0n1]=/ [/dev/sda]=$'\n/cdrom' [/dev/sdb]=$'\n/media/ubuntu/DATA')
  M_FSTYPES=([/dev/sda]=$'iso9660\niso9660\nvfat' [/dev/sdb]=$'\nexfat')
}
reset; live_session
run "find: live session picks the external disk, not the live stick" 0 eval 'find_disk; eq "$DISK" /dev/sdb'
reset; live_session; DISKS+=(/dev/sdc); M_TRAN[/dev/sdc]=usb
run "find: two external disks -> stop" 1 find_disk
reset; live_session; DISKS=(/dev/nvme0n1 /dev/sda)
run "find: no external disk -> stop" 1 find_disk
reset; live_session; DISKS+=(/dev/sdc); M_TRAN[/dev/sdc]=usb; M_BYTES[/dev/sdc]=0
run "find: empty card reader is ignored" 0 eval 'find_disk; eq "$DISK" /dev/sdb'
reset; live_session; DISKS+=(/dev/sdc); M_TRAN[/dev/sdc]=usb; M_MOUNTS[/dev/sdc]=$'\n[SWAP]'
run "find: USB disk used as swap is protected" 0 eval 'find_disk; eq "$DISK" /dev/sdb'
reset; live_session; DISKS+=(/dev/sdc); M_TRAN[/dev/sdc]=usb; M_MOUNTS[/dev/sdc]=$'\n/mnt/backup'
run "find: USB disk mounted outside /media is protected" 0 eval 'find_disk; eq "$DISK" /dev/sdb'

# ---- identify_disk / sanitize_method -------------------------------------------------
reset; DISK=/dev/sdb; HDPARM_I=$SSD_CRYPTO
run "identify: SATA SSD with crypto scramble" 0 eval 'identify_disk; eq "$KIND/$MODEL/$SERIAL/$(sanitize_method)" "SSD/Samsung SSD 870 EVO 1TB/S5Y1NJ0R123456X/crypto-scramble"'
reset; DISK=/dev/sdb; HDPARM_I=$SSD_BLOCK
run "identify: SATA SSD with block erase only" 0 eval 'identify_disk; eq "$(sanitize_method)" block-erase'
reset; DISK=/dev/sdb; HDPARM_I=$SSD_NO_SANITIZE
run "identify: SSD without Sanitize has no method" 1 eval 'identify_disk; sanitize_method'
reset; DISK=/dev/sdb; HDPARM_I=$HDD
run "identify: HDD from rotation rate" 0 eval 'identify_disk; eq "$KIND" HDD'
reset; DISK=/dev/sdb; M_MODEL[/dev/sdb]="Samsung  PSSD T7 "; ANS_KIND=ssd
run "identify: no ATA pass-through -> operator answer, lsblk model" 0 eval 'identify_disk; eq "$KIND/$MODEL/$ATA" "SSD/Samsung PSSD T7/"'
reset; DISK=/dev/sdb; ANS_KIND=maybe
run "identify: invalid HDD/SSD answer -> stop" 1 identify_disk

# ---- check_ssd / vendor_tool ---------------------------------------------------------
reset; usb_image; MODEL="Samsung PSSD T7"; SERIAL=S6XNNS0T1234
run "vendor: Samsung over NVMe bridge -> manufacturer tool" 2 check_ssd
expect "vendor: names Samsung Magician" "Samsung Magician" "$WORK/out"
expect "vendor: fingerprint saved for --verify-only" "^0 [0-9a-f]{64} [0-9]+$" "$WORK/usb-wipe-baseline-S6XNNS0T1234.txt"
reset; DISK=/dev/sdb; MODEL="Kingston XS2000"
run "vendor: Kingston -> destroy" 3 check_ssd
reset; DISK=/dev/sdb; ATA=$SSD_CRYPTO; STATUS_SEQ=("$FROZEN")
run "check_ssd: frozen -> stop" 1 check_ssd

# ---- wipe_ssd polling ----------------------------------------------------------------
reset; DISK=/dev/sdb; SANITIZE=crypto-scramble; STATUS_SEQ=("$RUNNING" "$RUNNING" "$DONE")
run "sanitize: in process then completed" 0 wipe_ssd
expect "sanitize: hdparm called with the right option" "hdparm --yes-i-know-what-i-am-doing --sanitize-crypto-scramble /dev/sdb" "$WORK/calls"
reset; DISK=/dev/sdb; SANITIZE=block-erase; STATUS_SEQ=("$RUNNING" "$FAILED_ST")
run "sanitize: operation failed" 1 wipe_ssd
reset; DISK=/dev/sdb; SANITIZE=block-erase; SANITIZE_RC=5
run "sanitize: start command rejected" 1 wipe_ssd

# ---- baseline / verify on an image ---------------------------------------------------
reset; usb_image
run "verify: shred (ends with zeros) -> pass" 0 eval 'baseline; shred -n 1 -z "$DISK"; verify'
expect "verify: baseline counted the samples holding data" "Before the wipe: 5 of 5 samples hold data" "$WORK/out"
reset; usb_image
run "verify: nothing written -> fail" 1 eval 'baseline; verify'
expect "verify: reports unchanged data" "FAIL, unchanged" "$WORK/out"
reset; usb_image
run "verify: new random data (crypto scramble) -> pass" 0 eval 'baseline; scramble; verify'
reset; usb_image zeros
run "verify: empty disk, zeros before and after -> pass" 0 eval 'baseline; verify'
reset; usb_image ff
run "verify: empty disk, 0xFF before and after -> pass" 0 eval 'baseline; verify'
reset; usb_image
run "verify: no fingerprint from before -> fail" 1 verify

# ---- full runs of main ---------------------------------------------------------------
reset; usb_image; HDPARM_I=$HDD; ANS_TOKEN=1234
run "main HDD: wipe, verify, reformat" 0 main
expect "main HDD: report says PASS" "RESULT: PASS. Wiped \(shred" "$WORK"/wipe-report-T-42-*.txt
expect "main HDD: report has the disk identity" "WDC WD10JMVW-11AJGS4 .* serial WD-WXA1A97F1234 \(drive\)" "$WORK"/wipe-report-T-42-*.txt
expect "main HDD: exFAT partition type" "type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7" "$WORK/sfdisk-input"
expect "main HDD: mkfs on the new partition" "mkfs.exfat -L PERSONAL $WORK/disk.img-part1" "$WORK/calls"
[[ -z ${SHOW_REPORT:-} ]] || { echo "----- sample report -----"; cat "$WORK"/wipe-report-T-42-*.txt; echo "-------------------------"; }

reset; usb_image; HDPARM_I=$SSD_CRYPTO; ANS_TOKEN=456X; SANITIZE_EFFECT=random
STATUS_SEQ=("$IDLE" "$RUNNING" "$DONE")
run "main SSD: sanitize over USB, verify, reformat" 0 main
expect "main SSD: report names the method" "ATA Sanitize crypto-scramble" "$WORK"/wipe-report-T-42-*.txt

reset; usb_image; HDPARM_I=$SSD_CRYPTO; ANS_TOKEN=456X; STATUS_SEQ=("$IDLE" "$DONE")
run "main SSD: sanitize reports success but data unchanged -> destroy" 3 main
expect "main SSD: second attempt was made" "attempt 2" "$WORK/out"

reset; usb_image; M_MODEL[$DISK]="Samsung PSSD T7"; M_SERIAL[$DISK]=S6XNNS0T1234; ANS_KIND=ssd
run "main SSD: NVMe bridge -> manufacturer tool" 2 main
run "main SSD: NVMe bridge -> nothing erased" 0 untouched
scramble                                         # the manufacturer's tool erases the SSD
ANS_TOKEN=1234; rm -f "$WORK"/wipe-report-*
run "main --verify-only: after the manufacturer's tool -> pass" 0 main --verify-only
expect "main --verify-only: report says PASS" "RESULT: PASS. Wiped \(manufacturer's tool" "$WORK"/wipe-report-T-42-*.txt

reset; usb_image; M_SERIAL[$DISK]=S6XNNS0T1234; ANS_TOKEN=1234
run "main --verify-only: no fingerprint from before -> stop" 1 main --verify-only

reset; usb_image; HDPARM_I=$HDD; ANS_TOKEN=0000
run "main: wrong confirmation -> stop" 1 main
run "main: wrong confirmation -> nothing erased" 0 untouched

reset; usb_image; HDPARM_I=$HDD; ANS_TOKEN=1234
shred() { :; }                                   # simulate a wipe that writes nothing
run "main HDD: wipe ineffective twice -> destroy" 3 main
unset -f shred

echo
echo "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
