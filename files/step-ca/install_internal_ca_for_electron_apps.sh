#!/usr/bin/env bash

set -euo pipefail

show_help() {
cat << EOF
install_internal_ca.sh
-----------------------
Purpose:
  Install a custom/internal CA certificate so that:
    1. System applications trust it (system trust store).
    2. Electron/Chromium-based apps (e.g., Obsidian, VS Code) trust it via NSS DB.

Usage:
  $0 /path/to/YourInternalCA.crt

Options:
  -h, --help    Show this help message.

How it works:
  - Copies the CA certificate to /usr/local/share/ca-certificates/
  - Runs update-ca-certificates to refresh system trust.
  - Adds the CA certificate to the user's NSS DB (~/.pki/nssdb) for Electron apps.

Requirements:
  - certutil (from libnss3-tools)
  - update-ca-certificates (Debian/Ubuntu)
  - Sudo privileges for system CA update.

Example:
  $0 ./root_ca.crt
EOF
}

# --- Argument parsing ---
if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

CERT_PATH="$1"

# Validate input file
if [[ ! -f "$CERT_PATH" ]]; then
    echo "Error: Certificate file '$CERT_PATH' not found."
    exit 1
fi

# Check dependencies
for cmd in certutil update-ca-certificates; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: '$cmd' is required but not installed."
        [[ "$cmd" == "certutil" ]] && echo "   Install with: sudo apt install libnss3-tools"
        exit 1
    fi
done

# --- Extract CN from certificate ---
CERT_CN=$(openssl x509 -noout -subject -in "$CERT_PATH" | sed -n 's/^.*CN=\([^,\/]*\).*$/\1/p')
if [[ -z "$CERT_CN" ]]; then
    echo "[-] Failed to extract CN from certificate, using default name."
    CERT_CN="Custom_Internal_CA"
fi

# --- Install into NSS DB (for Electron/Chromium apps) ---
NSS_DB="$HOME/.pki/nssdb"

# 1. Ensure NSS DB exists
mkdir -p "$NSS_DB"
certutil -d "sql:${NSS_DB}" -N --empty-password 2>/dev/null || true

# 2. Import CA into NSS DB (Electron/Chromium apps)
if certutil -d "sql:${NSS_DB}" -L | grep -q "$CERT_CN"; then
    echo "[*] CA '$CERT_CN' already in NSS DB"
else
    certutil -d "sql:${NSS_DB}" -A -t "C,," -n "$CERT_CN" -i "$CERT_PATH"
    echo "[+] Added '$CERT_CN' to NSS DB"
fi

# 3. Add CA to system trust store if not already present
SYSTEM_CA_PATH="/usr/local/share/ca-certificates/${CERT_CN}.crt"
if [[ ! -f "$SYSTEM_CA_PATH" ]]; then
    echo "[*] Adding CA to system trust store..."
    sudo cp "$CERT_PATH" "$SYSTEM_CA_PATH"
    sudo update-ca-certificates
else
    echo "[*] CA already exists in system trust store"
fi

echo "[+] Internal CA installed for both system and Electron (NSS)"
