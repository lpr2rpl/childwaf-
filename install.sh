#!/bin/bash
# childwaf – Installation Script
#
# Usage: sudo ./install.sh [--uninstall]
#
# Installs childwaf to a Devuan (sysvinit) Linux system.
# Existing configuration in /etc/childwaf/ is never overwritten.

set -euo pipefail

INSTALL_BIN=/usr/local/sbin
INSTALL_LIB=/usr/local/lib/childwaf
INSTALL_CONF=/etc/childwaf
INSTALL_INITD=/etc/init.d
SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${GREEN}──${NC} $*"; }

# ─── Root check ───────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || error "This script must be run as root (sudo ./install.sh)"

# ─── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
    step "Uninstalling childwaf"
    if [[ -x "${INSTALL_INITD}/childwaf" ]]; then
        "${INSTALL_INITD}/childwaf" stop 2>/dev/null || true
        update-rc.d childwaf remove 2>/dev/null || true
        rm -f "${INSTALL_INITD}/childwaf"
    fi
    rm -f "${INSTALL_BIN}/childwaf"
    rm -rf "${INSTALL_LIB}"
    warn "Configuration kept at ${INSTALL_CONF} – remove manually if desired."
    info "Uninstall complete."
    exit 0
fi

# ─── Dependency check ─────────────────────────────────────────────────────────
step "Checking dependencies"
MISSING=()
for pkg in iptables ipset dnsmasq; do
    if command -v "${pkg}" &>/dev/null; then
        info "${pkg} found: $(command -v "${pkg}")"
    else
        warn "${pkg} not found"
        MISSING+=("${pkg}")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "Missing packages: ${MISSING[*]}"
    read -r -p "Install missing packages with apt-get? [Y/n] " answer
    answer="${answer:-Y}"
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        apt-get install -y "${MISSING[@]}"
    else
        error "Cannot continue without required packages."
    fi
fi

# ─── Install binary ───────────────────────────────────────────────────────────
step "Installing binary"
install -m 0755 "${SOURCE_DIR}/bin/childwaf" "${INSTALL_BIN}/childwaf"
info "Installed: ${INSTALL_BIN}/childwaf"

# ─── Install libraries ────────────────────────────────────────────────────────
step "Installing libraries"
install -d -m 0755 "${INSTALL_LIB}"
for lib in "${SOURCE_DIR}/lib/"*.sh; do
    install -m 0644 "${lib}" "${INSTALL_LIB}/"
    info "Installed: ${INSTALL_LIB}/$(basename "${lib}")"
done

# ─── Install configuration (never overwrite existing) ────────────────────────
step "Installing configuration"
install -d -m 0755 "${INSTALL_CONF}"
install -d -m 0755 "${INSTALL_CONF}/children"
install -d -m 0755 "${INSTALL_CONF}/blocklists"
install -d -m 0755 "${INSTALL_CONF}/allowlists"

# Main config
if [[ ! -f "${INSTALL_CONF}/childwaf.conf" ]]; then
    install -m 0640 "${SOURCE_DIR}/conf/childwaf.conf" "${INSTALL_CONF}/childwaf.conf"
    info "Installed: ${INSTALL_CONF}/childwaf.conf"
else
    warn "Keeping existing: ${INSTALL_CONF}/childwaf.conf"
fi

# Example child profile
if [[ ! -f "${INSTALL_CONF}/children/example.conf" ]]; then
    install -m 0640 "${SOURCE_DIR}/conf/children/example.conf" \
        "${INSTALL_CONF}/children/example.conf"
    info "Installed: ${INSTALL_CONF}/children/example.conf"
fi

# Blocklists (install new lists, keep customised existing ones)
for list in "${SOURCE_DIR}/conf/blocklists/"*.list; do
    dest="${INSTALL_CONF}/blocklists/$(basename "${list}")"
    if [[ ! -f "${dest}" ]]; then
        install -m 0644 "${list}" "${dest}"
        info "Installed: ${dest}"
    else
        warn "Keeping existing: ${dest}"
    fi
done

# Allowlists
for list in "${SOURCE_DIR}/conf/allowlists/"*.list; do
    dest="${INSTALL_CONF}/allowlists/$(basename "${list}")"
    if [[ ! -f "${dest}" ]]; then
        install -m 0644 "${list}" "${dest}"
        info "Installed: ${dest}"
    else
        warn "Keeping existing: ${dest}"
    fi
done

# ─── Ensure dnsmasq.d directory exists ────────────────────────────────────────
if [[ ! -d /etc/dnsmasq.d ]]; then
    install -d -m 0755 /etc/dnsmasq.d
    # Also enable conf-dir in dnsmasq.conf if present
    if [[ -f /etc/dnsmasq.conf ]] && \
       ! grep -q "conf-dir=/etc/dnsmasq.d" /etc/dnsmasq.conf; then
        echo "conf-dir=/etc/dnsmasq.d/,*.conf" >> /etc/dnsmasq.conf
        info "Added conf-dir to /etc/dnsmasq.conf"
    fi
fi

# ─── Install init.d service ───────────────────────────────────────────────────
step "Installing init.d service"
install -m 0755 "${SOURCE_DIR}/init.d/childwaf" "${INSTALL_INITD}/childwaf"
info "Installed: ${INSTALL_INITD}/childwaf"

if command -v update-rc.d &>/dev/null; then
    update-rc.d childwaf defaults
    info "Registered with update-rc.d (starts at runlevels 2-5)"
else
    warn "update-rc.d not found – enable service manually"
fi

# ─── Enable IP forwarding ─────────────────────────────────────────────────────
step "Enabling IP forwarding"
if ! grep -q "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    info "IP forwarding enabled (added to /etc/sysctl.conf)"
else
    info "IP forwarding already enabled in /etc/sysctl.conf"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  childwaf installed successfully"
echo "════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit main config:       ${INSTALL_CONF}/childwaf.conf"
echo "     → Set LAN_INTERFACE and WAN_INTERFACE for your network"
echo ""
echo "  2. Create a child profile:"
echo "     cp ${INSTALL_CONF}/children/example.conf \\"
echo "        ${INSTALL_CONF}/children/alice.conf"
echo "     → Set NAME, IP, BLOCK_CATEGORIES, and schedule"
echo ""
echo "  3. Start the filter:       childwaf start"
echo "     Or via init.d:          service childwaf start"
echo ""
echo "  4. Check status:           childwaf status"
echo "     Check dependencies:     childwaf check"
echo ""
