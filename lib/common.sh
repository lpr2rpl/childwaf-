#!/bin/bash
# childwaf - Common utilities and configuration loading
# Sourced by the main childwaf script and all modules.

# ─── Logging ──────────────────────────────────────────────────────────────────
: "${LOG_FILE:=/var/log/childwaf.log}"
: "${LOG_LEVEL:=info}"

_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="${ts} [${level}] $*"
    echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    echo "${line}" >&2
}

log_debug() { [[ "${LOG_LEVEL}" == "debug" ]] && _log DEBUG "$@" || true; }
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; exit 1; }

# ─── Root check ───────────────────────────────────────────────────────────────
require_root() {
    [[ "${EUID}" -eq 0 ]] || log_error "childwaf must be run as root"
}

# ─── Main config loading ──────────────────────────────────────────────────────
load_config() {
    local conf="${CHILDWAF_CONF_MAIN:-/etc/childwaf/childwaf.conf}"
    [[ -f "${conf}" ]] || log_error "Main config not found: ${conf}"
    # shellcheck source=/dev/null
    source "${conf}"
    CHILDWAF_CONF="${CONF_DIR:-/etc/childwaf}"
    log_debug "Loaded main config: ${conf}"
}

# ─── Child config loading ─────────────────────────────────────────────────────
# Resets all child variables to safe defaults, then sources the child config.
load_child_config() {
    local child_conf="$1"

    # Reset to defaults (inherit global module settings where applicable)
    NAME=""
    IP=""
    MAC=""
    DNS_FILTER="${MODULE_DNS:-yes}"
    SCHEDULE_ENABLED="${MODULE_SCHEDULE:-yes}"
    BLOCK_CATEGORIES=""
    BLOCK_DOMAINS=""
    ALLOW_DOMAINS=""
    SCHEDULE_MON="always"
    SCHEDULE_TUE="always"
    SCHEDULE_WED="always"
    SCHEDULE_THU="always"
    SCHEDULE_FRI="always"
    SCHEDULE_SAT="always"
    SCHEDULE_SUN="always"
    DAILY_LIMIT_MIN=0
    BLOCK_HTTPS_BYPASS=no

    # shellcheck source=/dev/null
    source "${child_conf}"

    [[ -n "${IP}" ]] || log_error "Child config '${child_conf}' has no IP defined"
}

# ─── Child iteration ──────────────────────────────────────────────────────────
# Calls CALLBACK child_id conf_path for every non-example child profile found.
each_child() {
    local callback="$1"
    local child_dir="${CHILDWAF_CONF}/children"
    [[ -d "${child_dir}" ]] || return 0

    local found=0
    for conf in "${child_dir}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        local child_id
        child_id=$(basename "${conf}" .conf)
        [[ "${child_id}" == "example" ]] && continue   # skip the example profile
        "${callback}" "${child_id}" "${conf}"
        found=1
    done
    [[ "${found}" -eq 1 ]] || log_warn "No child profiles found in ${child_dir}"
}

# ─── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in iptables ipset dnsmasq; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}. Run 'childwaf check' for details."
    fi
}
