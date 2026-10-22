#!/usr/bin/env bash
# install.sh: download the latest release of usb-wipe and install it as
# /usr/local/bin/usb-wipe (set INSTALL_DIR to choose another folder).
#
#   curl -fsSL https://raw.githubusercontent.com/lostsh/usb-wipe/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/lostsh/usb-wipe/main/install.sh | bash -s -- --with-deps
#
# --with-deps also installs hdparm and exfatprogs with apt.
# Uninstall: sudo rm /usr/local/bin/usb-wipe
set -euo pipefail

BIN_NAME="usb-wipe"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DOWNLOAD_URL="https://github.com/lostsh/usb-wipe/releases/latest/download/usb-wipe.sh"
RULE="-----------------------------------------------------"

step() { printf '[ > ] %s\n' "$1"; }
sub() { printf '\t[ - ] %s\n' "$1"; }
ok() { printf '[ OK ] %s\n' "$1"; }
die() { printf '[ ERR ] %s\n' "$1" >&2; exit 1; }
banner() { printf '[ * ] %s\n' "$@"; }          # printf repeats the format: one line per argument

# Everything runs from main, called on the last line: when piped from curl, a cut
# connection leaves main undefined or uncalled, so nothing half-done runs.
main() {
    local with_deps=0 sudo="" target="${INSTALL_DIR}/${BIN_NAME}" cmd
    case "${1:-}" in
        "") ;;
        --with-deps) with_deps=1 ;;
        *) die "Unknown option: $1 (only --with-deps is supported)" ;;
    esac

    step "Starting installation for ${BIN_NAME}"

    sub "Checking dependencies"
    for cmd in curl install cmp; do
        command -v "${cmd}" >/dev/null 2>&1 || die "Dependency required but not found: ${cmd}"
    done

    step "Downloading the latest release"
    sub "Source: ${DOWNLOAD_URL}"
    TMP_FILE=$(mktemp)
    trap 'rm -f "${TMP_FILE}"' EXIT
    curl --proto '=https' --tlsv1.2 --retry 3 -fsSL "${DOWNLOAD_URL}" -o "${TMP_FILE}" || die "Download failed."

    # curl -f already fails on HTTP errors and incomplete transfers; this also refuses
    # anything that is not a bash script, such as an HTML page served by a proxy.
    sub "Checking the downloaded script"
    if ! head -n 1 "${TMP_FILE}" | grep -q '^#!.*bash' || ! bash -n "${TMP_FILE}" 2>/dev/null; then
        die "The downloaded file is not a valid bash script."
    fi

    if ! { mkdir -p "${INSTALL_DIR}" 2>/dev/null && [ -w "${INSTALL_DIR}" ]; }; then
        sub "Administrator rights needed: using sudo"
        sudo="sudo"
    fi

    if [ -f "${target}" ] && cmp -s "${TMP_FILE}" "${target}"; then
        ok "Already up to date: ${target}"
    else
        step "Installing to ${target}"
        if [ -f "${target}" ]; then
            sub "Replacing the existing installation"
        fi
        ${sudo} install -D -m 0755 "${TMP_FILE}" "${target}"
        ok "Installation complete."
    fi

    if [ "${with_deps}" -eq 1 ]; then
        step "Installing hdparm and exfatprogs"
        command -v apt-get >/dev/null 2>&1 || die "apt-get not found: install hdparm and exfatprogs with your package manager."
        sudo="sudo"
        if [ "$(id -u)" -eq 0 ]; then
            sudo=""
        fi
        ${sudo} apt-get update -qq
        ${sudo} apt-get install -y -qq hdparm exfatprogs
        ok "Dependencies installed."
    fi

    local run_cmd="sudo ${target}" deps=()
    [ "${INSTALL_DIR}" != "/usr/local/bin" ] || run_cmd="sudo ${BIN_NAME}"
    [ "${with_deps}" -eq 1 ] || deps=("It needs hdparm and exfatprogs:" $'\t sudo apt install -y hdparm exfatprogs')

    printf '\n'
    banner "${RULE}" \
        "The tool '${BIN_NAME}' is now installed in:" $'\t '"${INSTALL_DIR}" "" \
        "${deps[@]}" \
        "Run it with:" $'\t '"${run_cmd}" "" \
        "If this tool saves you time, please consider" \
        "starring the repository to support the project:" "" \
        $'\t https://github.com/lostsh/usb-wipe' \
        "${RULE}"
    printf '\n'
}

main "$@"
