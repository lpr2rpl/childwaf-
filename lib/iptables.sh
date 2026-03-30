#!/bin/bash
# childwaf - iptables / ipset rules management
#
# Design overview
# ───────────────
# One ipset per child:    childwaf_child_<id>   (hash:net  – child device IPs)
# One ipset per category: childwaf_cat_<name>   (hash:ip   – IPs resolved by dnsmasq)
#
# filter table
#   FORWARD → CHILDWAF_FILTER
#   CHILDWAF_FILTER → CHILDWAF_CHILD_<id>  (only for traffic from that child's ipset)
#
#   CHILDWAF_CHILD_<id>:
#     1. DROP  connections to blocked categories (ipsets populated by dnsmasq)
#     2. DROP  forwarded DNS (prevent bypass to external resolvers)
#     3. DROP  DNS-over-TLS (port 853)
#     4. ACCEPT within allowed schedule windows (iptables time module)
#     5. DROP  (default – outside schedule or all day if schedule=never)
#
# nat table
#   PREROUTING → CHILDWAF_NAT
#   CHILDWAF_NAT: REDIRECT child DNS queries to local port (forces use of our dnsmasq)

# ─── ipset helpers ────────────────────────────────────────────────────────────

_ipset_ensure() {
    local name="$1" type="$2" opts="${3:-}"
    if ! ipset list "${name}" &>/dev/null; then
        # shellcheck disable=SC2086
        ipset create "${name}" "${type}" ${opts}
        log_debug "ipset created: ${name} (${type})"
    fi
}

ipset_setup_child() {
    local child_id="$1"
    _ipset_ensure "childwaf_child_${child_id}" hash:net "hashsize 64 maxelem 256"
}

ipset_populate_child() {
    local child_id="$1" child_conf="$2"
    load_child_config "${child_conf}"
    local set="childwaf_child_${child_id}"
    ipset flush "${set}"
    for addr in ${IP}; do
        ipset add "${set}" "${addr}" 2>/dev/null || \
            log_warn "Could not add ${addr} to ipset ${set}"
        log_debug "  ${set} += ${addr}"
    done
}

ipset_setup_category() {
    local category="$1"
    local list="${CHILDWAF_CONF}/blocklists/${category}.list"

    # doh-providers and any list that starts with a CIDR (contains /) uses
    # hash:net so it can store IP ranges.  All other categories use hash:ip
    # (populated dynamically by dnsmasq).
    if head -20 "${list}" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'; then
        _ipset_ensure "childwaf_cat_${category}" hash:net "hashsize 1024 maxelem 16384"
        # Pre-populate static CIDR ranges from the list
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%%#*}"; line="${line//[[:space:]]/}"
            [[ -z "${line}" ]] && continue
            ipset add "childwaf_cat_${category}" "${line}" 2>/dev/null || true
        done < "${list}"
    else
        _ipset_ensure "childwaf_cat_${category}" hash:ip "hashsize 4096 maxelem 65536"
    fi
}

ipset_destroy_all() {
    while IFS= read -r set; do
        ipset destroy "${set}" 2>/dev/null && log_debug "ipset destroyed: ${set}" || true
    done < <(ipset list -n 2>/dev/null | grep "^childwaf_" || true)
}

# ─── iptables chain helpers ───────────────────────────────────────────────────

_chain_exists() { iptables -t "${1}" -n -L "${2}" &>/dev/null; }

chain_ensure() {
    local table="$1" chain="$2"
    _chain_exists "${table}" "${chain}" || iptables -t "${table}" -N "${chain}"
}

chain_flush() {
    local table="$1" chain="$2"
    iptables -t "${table}" -F "${chain}" 2>/dev/null || true
}

chain_delete() {
    local table="$1" chain="$2"
    iptables -t "${table}" -F "${chain}" 2>/dev/null || true
    iptables -t "${table}" -X "${chain}" 2>/dev/null || true
}

# Append a jump rule only if not already present
_jump_append() {
    local table="$1" parent="$2" chain="$3"
    shift 3
    # "$@" = extra match options (may be empty)
    if ! iptables -t "${table}" -C "${parent}" "$@" -j "${chain}" &>/dev/null; then
        iptables -t "${table}" -A "${parent}" "$@" -j "${chain}"
    fi
}

_jump_remove() {
    local table="$1" parent="$2" chain="$3"
    shift 3
    iptables -t "${table}" -D "${parent}" "$@" -j "${chain}" 2>/dev/null || true
}

# ─── Per-child chain setup ────────────────────────────────────────────────────

_child_chain_name() { echo "CHILDWAF_C_${1}"; }  # max 28 chars; id <= 16 chars

_build_child_chain() {
    local child_id="$1" child_conf="$2"
    load_child_config "${child_conf}"

    local chain
    chain=$(_child_chain_name "${child_id}")
    local child_set="childwaf_child_${child_id}"

    chain_ensure filter "${chain}"
    chain_flush   filter "${chain}"

    # ── 0. Pass through already-established connections ───────────────────────
    # Allows ongoing sessions to continue uninterrupted. Move this rule below
    # the schedule rules if you want hard session cutoffs at schedule boundaries.
    iptables -A "${chain}" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j RETURN

    # ── 1. Category-based destination blocks ──────────────────────────────────
    for category in ${BLOCK_CATEGORIES}; do
        local cat_set="childwaf_cat_${category}"
        if ipset list "${cat_set}" &>/dev/null; then
            iptables -A "${chain}" \
                -m set --match-set "${cat_set}" dst \
                -j DROP
            log_debug "  [${child_id}] block category: ${category}"
        else
            log_warn "Category ipset missing: ${cat_set} (run 'childwaf reload' after DNS resolves)"
        fi
    done

    # ── 2. Prevent DNS bypass to external resolvers ───────────────────────────
    if [[ "${DNS_FILTER}" == "yes" && "${DNS_BLOCK_BYPASS:-yes}" == "yes" ]]; then
        local lan_ip
        lan_ip=$(ip -4 addr show "${LAN_INTERFACE:-eth0}" 2>/dev/null \
                  | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        : "${lan_ip:=127.0.0.1}"

        # Block forwarded UDP/TCP DNS (to any host other than this machine)
        iptables -A "${chain}" \
            ! -d "${lan_ip}" -p udp --dport 53 -j DROP
        iptables -A "${chain}" \
            ! -d "${lan_ip}" -p tcp --dport 53 -j DROP

        # Block DNS-over-TLS (port 853)
        iptables -A "${chain}" -p tcp --dport 853 -j DROP
        iptables -A "${chain}" -p udp --dport 853 -j DROP

        log_debug "  [${child_id}] DNS bypass prevention active (LAN IP: ${lan_ip})"
    fi

    # ── 2b. Block common VPN ports (prevents tunnelling out of filter) ────────
    if [[ "${BLOCK_VPN_PORTS:-yes}" == "yes" ]]; then
        iptables -A "${chain}" -p udp --dport 1194 -j DROP   # OpenVPN UDP
        iptables -A "${chain}" -p tcp --dport 1194 -j DROP   # OpenVPN TCP
        iptables -A "${chain}" -p udp --dport 51820 -j DROP  # WireGuard
        iptables -A "${chain}" -p tcp --dport 1723 -j DROP   # PPTP
        iptables -A "${chain}" -p udp --dport 500  -j DROP   # IKE/IPsec
        iptables -A "${chain}" -p udp --dport 4500 -j DROP   # IKE NAT-T
        log_debug "  [${child_id}] VPN port blocks applied"
    fi

    # ── 3. Schedule: ACCEPT within allowed windows ────────────────────────────
    if [[ "${SCHEDULE_ENABLED}" == "yes" ]]; then
        local -A day_map=(
            [MON]=Mon [TUE]=Tue [WED]=Wed [THU]=Thu
            [FRI]=Fri [SAT]=Sat [SUN]=Sun
        )
        for day in MON TUE WED THU FRI SAT SUN; do
            local sched_var="SCHEDULE_${day}"
            local sched="${!sched_var:-always}"
            local wd="${day_map[${day}]}"

            if [[ "${sched}" == "always" ]]; then
                iptables -A "${chain}" \
                    -m time --weekdays "${wd}" --kerneltz \
                    -j ACCEPT
            elif [[ "${sched}" == "never" ]]; then
                : # no ACCEPT rule → default DROP below applies all day
            else
                local start="${sched%-*}" end="${sched#*-}"
                iptables -A "${chain}" \
                    -m time --timestart "${start}" --timestop "${end}" \
                    --weekdays "${wd}" --kerneltz \
                    -j ACCEPT
                log_debug "  [${child_id}] schedule ${wd}: ${start}-${end}"
            fi
        done
    else
        # Schedule module disabled → allow all traffic (only category blocks apply)
        iptables -A "${chain}" -j ACCEPT
        return
    fi

    # ── 4. Default DROP (outside schedule windows) ────────────────────────────
    iptables -A "${chain}" -j DROP
    log_info "  Chain ${chain} built for ${NAME:-${child_id}} (${IP})"
}

_wire_child_into_filter() {
    local child_id="$1" child_conf="$2"
    local chain
    chain=$(_child_chain_name "${child_id}")
    local child_set="childwaf_child_${child_id}"

    # Jump into per-child chain only for traffic originating from this child
    _jump_append filter CHILDWAF_FILTER "${chain}" \
        -m set --match-set "${child_set}" src
}

# ─── DNS redirect (NAT) ───────────────────────────────────────────────────────

_apply_dns_redirect() {
    local child_id="$1" child_conf="$2"
    load_child_config "${child_conf}"

    [[ "${DNS_FILTER}" == "yes" ]]             || return 0
    [[ "${DNS_REDIRECT_CHILDREN:-yes}" == "yes" ]] || return 0

    local child_set="childwaf_child_${child_id}"
    local port="${DNS_LOCAL_PORT:-53}"

    for proto in udp tcp; do
        iptables -t nat -A CHILDWAF_NAT \
            -m set --match-set "${child_set}" src \
            -p "${proto}" --dport 53 \
            -j REDIRECT --to-port "${port}"
    done
    log_debug "  [${child_id}] DNS redirect → localhost:${port}"
}

# ─── Module lifecycle ─────────────────────────────────────────────────────────

module_iptables_start() {
    require_root
    check_deps
    log_info "Applying iptables rules..."

    # Top-level chains
    chain_ensure filter CHILDWAF_FILTER
    chain_ensure nat    CHILDWAF_NAT
    _jump_append filter FORWARD    CHILDWAF_FILTER
    _jump_append nat    PREROUTING CHILDWAF_NAT

    # Category ipsets (populated later by dnsmasq resolution)
    for list in "${CHILDWAF_CONF}/blocklists/"*.list; do
        [[ -f "${list}" ]] || continue
        local cat
        cat=$(basename "${list}" .list)
        ipset_setup_category "${cat}"
    done

    # Per-child setup
    _start_child() {
        local child_id="$1" conf="$2"
        log_info "  Configuring: ${child_id}"
        ipset_setup_child    "${child_id}"
        ipset_populate_child "${child_id}" "${conf}"
        _apply_dns_redirect  "${child_id}" "${conf}"
        _build_child_chain   "${child_id}" "${conf}"
        _wire_child_into_filter "${child_id}" "${conf}"
    }
    each_child _start_child

    log_info "iptables rules applied."
}

module_iptables_stop() {
    require_root
    log_info "Removing iptables rules..."

    # Detach from main chains first
    _jump_remove filter FORWARD    CHILDWAF_FILTER
    _jump_remove nat    PREROUTING CHILDWAF_NAT

    # Remove per-child chains
    _stop_child() {
        local child_id="$1"
        chain_delete filter "$(_child_chain_name "${child_id}")"
    }
    # We may not have a loaded config here, iterate directly
    if [[ -d "${CHILDWAF_CONF}/children" ]]; then
        for conf in "${CHILDWAF_CONF}/children/"*.conf; do
            [[ -f "${conf}" ]] || continue
            local cid
            cid=$(basename "${conf}" .conf)
            [[ "${cid}" == "example" ]] && continue
            chain_delete filter "$(_child_chain_name "${cid}")"
        done
    fi

    chain_delete filter CHILDWAF_FILTER
    chain_delete nat    CHILDWAF_NAT

    ipset_destroy_all
    log_info "iptables rules removed."
}

module_iptables_reload() {
    require_root
    log_info "Reloading iptables rules..."

    # Flush per-child chains and top-level chains (keep chain objects)
    chain_flush filter CHILDWAF_FILTER
    chain_flush nat    CHILDWAF_NAT

    if [[ -d "${CHILDWAF_CONF}/children" ]]; then
        for conf in "${CHILDWAF_CONF}/children/"*.conf; do
            [[ -f "${conf}" ]] || continue
            local cid
            cid=$(basename "${conf}" .conf)
            [[ "${cid}" == "example" ]] && continue
            chain_flush filter "$(_child_chain_name "${cid}")"
        done
    fi

    # Ensure new categories have ipsets
    for list in "${CHILDWAF_CONF}/blocklists/"*.list; do
        [[ -f "${list}" ]] || continue
        ipset_setup_category "$(basename "${list}" .list)"
    done

    _reload_child() {
        local child_id="$1" conf="$2"
        ipset_setup_child    "${child_id}"
        ipset_populate_child "${child_id}" "${conf}"
        _apply_dns_redirect  "${child_id}" "${conf}"
        _build_child_chain   "${child_id}" "${conf}"
        _wire_child_into_filter "${child_id}" "${conf}"
    }
    each_child _reload_child

    log_info "iptables rules reloaded."
}
