# usb-wipe

[![ci](https://github.com/lostsh/usb-wipe/actions/workflows/ci.yml/badge.svg)](https://github.com/lostsh/usb-wipe/actions/workflows/ci.yml)

Wipe an external USB disk (HDD or SSD) before giving it back to its owner, verify that the
old data is gone, reformat the disk as exFAT and write a report you can attach to a ticket.

Methods follow [NIST SP 800-88](https://csrc.nist.gov/pubs/sp/800/88/r2/final): overwrite
for hard disks, the drive's own Sanitize command for SSDs, and destruction when neither can
be done reliably.

> **Warning:** this script erases disks irreversibly. Test it on spare disks before using it
> on real ones.

## Requirements

- Ubuntu (linux distro), run as root
- `hdparm` and `exfatprogs`: `sudo apt install -y hdparm exfatprogs`

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/lostsh/usb-wipe/main/install.sh | bash
```

This installs the latest release as `/usr/local/bin/usb-wipe` (set `INSTALL_DIR` to choose
another folder). Add `--with-deps` to also install `hdparm` and `exfatprogs` with apt:

```bash
curl -fsSL https://raw.githubusercontent.com/lostsh/usb-wipe/main/install.sh | bash -s -- --with-deps
```

You can also download `usb-wipe.sh` from the releases page and run it directly.

## Usage

Copy the files to keep off the disk first. Then unplug every USB disk except the one to
wipe, and run:

```bash
sudo usb-wipe                 # find the disk, wipe it, verify, reformat
sudo usb-wipe --verify-only   # after an SSD was erased with the manufacturer's tool
```

The script asks for a ticket number and the operator's name, then:

1. **Finds the disk.** Only USB disks are considered. Disks running the system (mounted
   outside `/media`, swap, or a live USB stick) are never picked. It stops when it finds no
   candidate or more than one.
2. **Identifies it:** model, serial number, size, HDD or SSD (asks the operator when the
   USB adapter does not tell).
3. **Asks for confirmation:** the operator types the last 4 characters of the serial number.
4. **Fingerprints the disk:** SHA-256 of 5 samples of 256 MiB (start, 25 %, 50 %, 75 %, end).
5. **Wipes it:**
   - HDD: `shred -n 1 -z` (one random pass, then zeros).
   - SSD: ATA Sanitize (crypto scramble, else block erase) sent over USB with `hdparm`.
     When the USB adapter or the SSD does not support it, the script saves the fingerprint,
     names the manufacturer's tool (Samsung Magician, SanDisk Dashboard, Crucial Storage
     Executive) and exits with code 2. Erase the SSD with that tool, then run
     `--verify-only`.
6. **Verifies it:** every sample that held data must have changed. A sample that was empty
   (only `0x00` or `0xFF`) may stay identical. On failure the wipe is repeated once; a second
   failure means the disk must be destroyed.
7. **Reformats it** as exFAT (GPT, label `PERSONAL`).
8. **Writes a report** `wipe-report-<ticket>-<date>.txt` in the current folder. In a live USB
   session, save it before rebooting.

## Why fingerprints and not a keyword search

Searching the raw disk for known words only proves that those words are absent: the data
may never have contained them. Comparing fingerprints taken before and after the wipe shows
that the data that was there is gone.

## SSDs over USB

Sanitize is a command executed by the SSD's own controller. It is the only reliable way to
erase the spare flash cells that the computer cannot address. Many USB adapters do not pass
it through, and a faulty adapter can leave the SSD unusable. The script only uses Sanitize,
never the password-based ATA Security Erase, which can leave a drive locked if it fails.
If you tried it with an SSD and a USB adapter, please share the result with a
"Hardware report" issue: it builds the list of hardware known to work.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Wiped, verified and reformatted |
| 1 | Stopped: nothing erased, or the operator must act (see the message) |
| 2 | SSD: use the manufacturer's tool, then `--verify-only` |
| 3 | The disk cannot be wiped reliably and must be destroyed |

## Tests

```bash
bash tests/run-tests.sh
```

System commands (`lsblk`, `hdparm`, `blockdev`, `sfdisk`...) are mocked and 32 MiB image
files stand in for the disk: no real device is touched.
