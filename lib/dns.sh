#!/bin/bash
# childwaf - DNS filtering module
#
# Uses dnsmasq for two purposes:
#
#   1. ipset directives  – when dnsmasq resolves a blocked domain it adds the
#      resulting IP(s) to the corresponding childwaf_cat_<category> ipset.
#      iptables then drops connections from child devices to those IPs.
#
#   2. Hard-block addresses – per-child BLOCK_DOMAINS entries return NXDOMAIN
#      (dnsmasq address=/<domain>/# syntax) for all clients routed through
#      our DNS.
#
# Generated files (in /etc/dnsmasq.d/ by default):
#   childwaf-ipsets.conf   – ipset= directives for category lists
#   childwaf-blocks.conf   – address= directives for hard-blocked domains

: "${DNSMASQ_CONF_D:=/etc/dnsmasq.d}"
CHILDWAF_DNS_IPSETS="${DNSMASQ_CONF_D}/childwaf-ipsets.conf"
CHILDWAF_DNS_BLOCKS="${DNSMASQ_CONF_D}/childwaf-blocks.conf"

# ─── Config generation ────────────────────────────────────────────────────────

_gen_ipset_conf() {
    local blocklist_dir="${CHILDWAF_CONF}/blocklists"

    {
        echo "# childwaf-ipsets.conf  –  AUTO-GENERATED, do not edit"
        echo "# Regenerate with: childwaf reload"
        echo ""

        for list in "${blocklist_dir}"/*.list; do
            [[ -f "${list}" ]] || continue
            local category
            category=$(basename "${list}" .list)
            local set_name="childwaf_cat_${category}"

            echo "# ── category: ${category} ──"
            while IFS= read -r line || [[ -n "${line}" ]]; do
                # Strip comments and blank lines
                line="${line%%#*}"
                line="${line//[[:space:]]/}"
                [[ -z "${line}" ]] && continue
                echo "ipset=/${line}/${set_name}"
            done < "${list}"
            echo ""
        done
    } > "${CHILDWAF_DNS_IPSETS}"

    log_debug "Generated: ${CHILDWAF_DNS_IPSETS}"
}

_gen_block_conf() {
    {
        echo "# childwaf-blocks.conf  –  AUTO-GENERATED, do not edit"
        echo "# Regenerate with: childwaf reload"
        echo ""

        _gen_child_blocks() {
            local child_id="$1" conf="$2"
            load_child_config "${conf}"
            [[ "${DNS_FILTER}" == "yes" ]] || return 0
            [[ -n "${BLOCK_DOMAINS}" ]]    || return 0

            echo "# Child: ${NAME:-${child_id}}"
            for domain in ${BLOCK_DOMAINS}; do
                # address=/<domain>/# → NXDOMAIN for all querying clients
                echo "address=/${domain}/#"
            done
            echo ""
        }
        each_child _gen_child_blocks

    } > "${CHILDWAF_DNS_BLOCKS}"

    log_debug "Generated: ${CHILDWAF_DNS_BLOCKS}"
}

generate_dnsmasq_config() {
    [[ -d "${DNSMASQ_CONF_D}" ]] || \
        log_error "dnsmasq config dir not found: ${DNSMASQ_CONF_D}. Is dnsmasq installed?"
    _gen_ipset_conf
    _gen_block_conf
    log_info "dnsmasq config generated."
}

# ─── dnsmasq reload ───────────────────────────────────────────────────────────

reload_dnsmasq() {
    if command -v service &>/dev/null; then
        service dnsmasq force-reload 2>/dev/null && return
    fi
    if command -v systemctl &>/dev/null; then
        systemctl reload-or-restart dnsmasq 2>/dev/null && return
    fi
    # Fallback: SIGHUP causes dnsmasq to re-read its config
    pkill -HUP dnsmasq 2>/dev/null || \
        log_warn "Could not reload dnsmasq – please restart it manually"
    log_debug "dnsmasq signalled."
}

# ─── Module lifecycle ─────────────────────────────────────────────────────────

module_dns_start() {
    require_root
    log_info "Configuring DNS filtering..."
    generate_dnsmasq_config
    reload_dnsmasq
    log_info "DNS filtering active."
}

module_dns_stop() {
    require_root
    log_info "Removing DNS filtering..."
    rm -f "${CHILDWAF_DNS_IPSETS}" "${CHILDWAF_DNS_BLOCKS}"
    reload_dnsmasq
    log_info "DNS filtering removed."
}

module_dns_reload() {
    require_root
    log_info "Reloading DNS filtering config..."
    generate_dnsmasq_config
    reload_dnsmasq
    log_info "DNS filtering reloaded."
}
