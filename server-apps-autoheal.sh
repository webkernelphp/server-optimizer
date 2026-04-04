#!/usr/bin/env bash
# ==============================================================================
#
#  ██╗    ██╗███████╗██████╗ ██╗  ██╗███████╗██████╗ ███╗   ██╗███████╗██╗
#  ██║    ██║██╔════╝██╔══██╗██║ ██╔╝██╔════╝██╔══██╗████╗  ██║██╔════╝██║
#  ██║ █╗ ██║█████╗  ██████╔╝█████╔╝ █████╗  ██████╔╝██╔██╗ ██║█████╗  ██║
#  ██║███╗██║██╔══╝  ██╔══██╗██╔═██╗ ██╔══╝  ██╔══██╗██║╚██╗██║██╔══╝  ██║
#  ╚███╔███╔╝███████╗██████╔╝██║  ██╗███████╗██║  ██║██║ ╚████║███████╗███████╗
#   ╚══╝╚══╝ ╚══════╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
#
#  Webkernel OS -- PHP Server Optimizer
#  Script : w-autoheal  (automated remediation)
#  https://github.com/webkernelphp/server-optimizer
#
#  Target  : Webkernel OF (Debian family deb12/13, Ubuntu 20.04+) + HestiaCP
#  License : EPL-2.0
#  Usage   : sudo bash server-apps-autoheal.sh [OPTIONS]
#
#  Options:
#    --dry-run     Show what would be done without applying anything
#    --yes         Skip confirmation prompts for SAFE actions (dangerous always prompt)
#    --only=SLUG   Run only a specific fix by slug (see list below)
#    --list        List all available fix slugs
#    -h, --help    Show this help
#
#  Fix slugs (use with --only=):
#    redis-install         Install and enable Redis
#    fpm-dynamic           Switch all ondemand pools to dynamic
#    fpm-dummy-children    Raise dummy pool max_children from 4 to sane default
#    opcache-tune          Set validate_timestamps=0, realpath_cache, memory
#    laravel-cache         Run composer w-cache on all detected Webkernel projects
#    mysql-slowlog         Enable MySQL slow query log
#    env-production        Set APP_ENV=production on projects still in local/dev
#    env-debug-off         Set APP_DEBUG=false on projects with debug on
#    env-cache-redis       Set CACHE_DRIVER + SESSION_DRIVER to redis (requires Redis)
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# Root guard
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "[X] This script must be run as root or via sudo." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Terminal colors
# ------------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
    C_RESET=$(printf '\033[0m')
    C_BOLD=$(printf '\033[1m')
    C_DIM=$(printf '\033[2m')
    C_RED=$(printf '\033[1;31m')
    C_GREEN=$(printf '\033[1;32m')
    C_YELLOW=$(printf '\033[1;33m')
    C_BLUE=$(printf '\033[1;34m')
    C_CYAN=$(printf '\033[1;36m')
    C_WHITE=$(printf '\033[1;37m')
    C_GRAY=$(printf '\033[0;37m')
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE="" C_GRAY=""
fi

SYM_OK="[OK]"
SYM_WARN="[!]"
SYM_ERR="[X]"
SYM_INFO=">"
SYM_SKIP="[-]"
SYM_RUN="[~]"
SYM_FIX="[FIX]"
SYM_DRY="[DRY]"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
DRY_RUN=0
AUTO_YES=0
ONLY_SLUG=""
REPORT_DIR="/root/sysadmin/webkernel-reports"
HEAL_LOG="${REPORT_DIR}/w-autoheal_$(date +%Y-%m-%d_%H-%M-%S).log"
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --dry-run)   DRY_RUN=1 ;;
        --yes)       AUTO_YES=1 ;;
        --only=*)    ONLY_SLUG="${arg#--only=}" ;;
        --list)
            echo "Available fix slugs:"
            grep -E '^#    [a-z].*[A-Za-z]$' "${BASH_SOURCE[0]}" | sed 's/^#    /  /'
            exit 0
            ;;
        -h|--help)
            grep '^#  ' "${BASH_SOURCE[0]}" | sed 's/^#  //'
            exit 0
            ;;
        *)
            echo "${C_YELLOW}${SYM_WARN} Unknown argument: ${arg}${C_RESET}" >&2
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------
mkdir -p "${REPORT_DIR}"
: > "${HEAL_LOG}"

log()    { echo "${*}"; echo "${*}" | sed 's/\x1b\[[0-9;]*m//g' >> "${HEAL_LOG}"; }
log_ok() { log "${C_GREEN}${SYM_OK} ${*}${C_RESET}"; }
log_warn(){ log "${C_YELLOW}${SYM_WARN} ${*}${C_RESET}"; }
log_err(){ log "${C_RED}${SYM_ERR} ${*}${C_RESET}"; }
log_fix(){ log "${C_CYAN}${SYM_FIX} ${*}${C_RESET}"; }
log_dry(){ log "${C_DIM}${SYM_DRY} (dry-run) ${*}${C_RESET}"; }
log_run(){ log "${C_GRAY}${SYM_RUN} ${*}${C_RESET}"; }
log_skip(){ log "${C_DIM}${SYM_SKIP} Skipped: ${*}${C_RESET}"; }

cmd_exists() { command -v "${1}" &>/dev/null; }

# Run a command, respecting dry-run mode
run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_dry "$*"
        return 0
    fi
    log_run "$*"
    eval "$*" >> "${HEAL_LOG}" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_err "Command failed (exit ${rc}): $*"
    fi
    return $rc
}

# Prompt for dangerous actions -- always interactive regardless of --yes
confirm_dangerous() {
    local label="${1}"
    local detail="${2}"
    echo ""
    echo "${C_RED}${C_BOLD}  [DANGEROUS] ${label}${C_RESET}"
    echo "${C_DIM}  ${detail}${C_RESET}"
    echo ""
    printf "  Apply this fix? [y/N] "
    local ans
    read -r ans
    [[ "${ans}" =~ ^[Yy]$ ]]
}

# Prompt for safe actions -- skipped if --yes
confirm_safe() {
    local label="${1}"
    if [[ "${AUTO_YES}" -eq 1 ]]; then
        log_fix "Auto-applying (--yes): ${label}"
        return 0
    fi
    echo ""
    echo "${C_CYAN}${C_BOLD}  [SAFE] ${label}${C_RESET}"
    printf "  Apply? [Y/n] "
    local ans
    read -r ans
    [[ -z "${ans}" ]] || [[ "${ans}" =~ ^[Yy]$ ]]
}

# Check if a slug should run
slug_enabled() {
    [[ -z "${ONLY_SLUG}" ]] || [[ "${ONLY_SLUG}" == "${1}" ]]
}

# Detect all Webkernel/Laravel projects
detect_projects() {
    find /home/*/web/*/public_html -maxdepth 0 -type d 2>/dev/null | while read -r d; do
        [[ -f "${d}/artisan" ]] && echo "${d}"
    done | sort
}

# Detect PHP versions
detect_php_versions() {
    find /usr/bin -maxdepth 1 -name 'php[0-9].[0-9]' 2>/dev/null \
        | sed 's|.*/php||' | sort -uV
}

# Banner
echo ""
echo "${C_BOLD}${C_WHITE}  Webkernel OS -- w-autoheal${C_RESET}"
echo "${C_DIM}  Log: ${HEAL_LOG}${C_RESET}"
[[ "${DRY_RUN}" -eq 1 ]] && echo "${C_YELLOW}  DRY-RUN mode -- no changes will be applied${C_RESET}"
echo ""

# redis-install removed -- phpredis extension not present on this server.
# Redis requires apt install php8.4-redis before any CACHE_STORE/SESSION_DRIVER change.

# ==============================================================================
# FIX: fpm-dynamic
# Switches all ondemand pools to pm=dynamic
# Safe: just config + graceful restart, no data loss
# ==============================================================================
if slug_enabled "fpm-dynamic"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- PHP-FPM: Switch ondemand pools to dynamic --${C_RESET}"

    total_ram_mb=$(free -m | awk '/Mem:/{print $2}')
    php_versions=$(detect_php_versions)
    needs_restart=()

    for ver in ${php_versions}; do
        pool_dir="/etc/php/${ver}/fpm/pool.d"
        [[ ! -d "${pool_dir}" ]] && continue

        for pool_file in "${pool_dir}"/*.conf; do
            [[ ! -f "${pool_file}" ]] && continue
            pool_name=$(basename "${pool_file}" .conf)
            pm_mode=$(grep -E '^pm\s*=' "${pool_file}" | awk -F= '{print $2}' | tr -d ' ' || echo "")

            [[ "${pm_mode}" != "ondemand" ]] && continue

            # Skip HestiaCP dummy pools
            if [[ "${pool_name}" == "dummy" ]]; then
                log_skip "dummy pool ${pool_file} (HestiaCP placeholder, leave as-is)"
                continue
            fi

            log_warn "Found ondemand pool: php${ver} [${pool_name}]"

            if confirm_safe "Switch php${ver} [${pool_name}] from ondemand to dynamic (pm.min_spare_servers=1 pm.max_spare_servers=3)"; then
                if [[ "${DRY_RUN}" -eq 0 ]]; then
                    # Backup
                    cp "${pool_file}" "${pool_file}.bak.$(date +%Y%m%d%H%M%S)"
                    # Replace pm line
                    sed -i 's/^pm\s*=.*/pm = dynamic/' "${pool_file}"
                    # Add/replace spare server settings
                    if grep -q 'pm.min_spare_servers' "${pool_file}"; then
                        sed -i 's/^pm\.min_spare_servers\s*=.*/pm.min_spare_servers = 1/' "${pool_file}"
                    else
                        echo "pm.min_spare_servers = 1" >> "${pool_file}"
                    fi
                    if grep -q 'pm.max_spare_servers' "${pool_file}"; then
                        sed -i 's/^pm\.max_spare_servers\s*=.*/pm.max_spare_servers = 3/' "${pool_file}"
                    else
                        echo "pm.max_spare_servers = 3" >> "${pool_file}"
                    fi
                    if grep -q 'pm.start_servers' "${pool_file}"; then
                        sed -i 's/^pm\.start_servers\s*=.*/pm.start_servers = 2/' "${pool_file}"
                    else
                        echo "pm.start_servers = 2" >> "${pool_file}"
                    fi
                    log_fix "php${ver} [${pool_name}] -> dynamic (backup: ${pool_file}.bak.*)"
                    needs_restart+=("php${ver}-fpm")
                else
                    log_dry "Would patch ${pool_file} and restart php${ver}-fpm"
                fi
            else
                log_skip "fpm-dynamic for php${ver} [${pool_name}]"
            fi
        done
    done

    # Restart FPM services that were modified
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        declare -A restarted
        for svc in "${needs_restart[@]:-}"; do
            [[ -z "${svc}" ]] && continue
            [[ -n "${restarted[${svc}]:-}" ]] && continue
            restarted["${svc}"]=1
            run "systemctl restart ${svc}"
            sleep 1
            if systemctl is-active --quiet "${svc}"; then
                log_ok "${svc} restarted successfully"
            else
                log_err "${svc} failed to restart -- check: journalctl -u ${svc} -n 20"
            fi
        done
    fi
fi

# ==============================================================================
# FIX: fpm-dummy-children
# Raises dummy pool max_children from the default 4 to a sane value
# Safe: dummy pools serve no real traffic in HestiaCP
# ==============================================================================
if slug_enabled "fpm-dummy-children"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- PHP-FPM: Fix dummy pool max_children --${C_RESET}"

    php_versions=$(detect_php_versions)
    for ver in ${php_versions}; do
        dummy_conf="/etc/php/${ver}/fpm/pool.d/dummy.conf"
        [[ ! -f "${dummy_conf}" ]] && continue

        cur_max=$(grep -E '^pm\.max_children' "${dummy_conf}" | awk -F= '{print $2}' | tr -d ' ' || echo "0")
        if [[ "${cur_max}" -lt 5 ]]; then
            log_warn "php${ver} dummy pool: pm.max_children=${cur_max}"
            if confirm_safe "Set php${ver} dummy pool pm.max_children=10 and pm=dynamic"; then
                if [[ "${DRY_RUN}" -eq 0 ]]; then
                    cp "${dummy_conf}" "${dummy_conf}.bak.$(date +%Y%m%d%H%M%S)"
                    sed -i 's/^pm\.max_children\s*=.*/pm.max_children = 10/' "${dummy_conf}"
                    sed -i 's/^pm\s*=.*/pm = dynamic/' "${dummy_conf}"
                    grep -q 'pm.min_spare_servers' "${dummy_conf}" \
                        && sed -i 's/^pm\.min_spare_servers.*/pm.min_spare_servers = 1/' "${dummy_conf}" \
                        || echo "pm.min_spare_servers = 1" >> "${dummy_conf}"
                    grep -q 'pm.start_servers' "${dummy_conf}" \
                        && sed -i 's/^pm\.start_servers.*/pm.start_servers = 2/' "${dummy_conf}" \
                        || echo "pm.start_servers = 2" >> "${dummy_conf}"
                    grep -q 'pm.max_spare_servers' "${dummy_conf}" \
                        && sed -i 's/^pm\.max_spare_servers.*/pm.max_spare_servers = 5/' "${dummy_conf}" \
                        || echo "pm.max_spare_servers = 5" >> "${dummy_conf}"
                    run "systemctl restart php${ver}-fpm"
                    log_fix "php${ver} dummy pool patched and restarted"
                else
                    log_dry "Would patch ${dummy_conf}"
                fi
            else
                log_skip "fpm-dummy-children for php${ver}"
            fi
        else
            log_ok "php${ver} dummy pm.max_children=${cur_max} (OK)"
        fi
    done
fi

# ==============================================================================
# FIX: opcache-tune
# Sets validate_timestamps=0, realpath_cache_size=4096K, memory_consumption=256
# Safe in production -- requires php-fpm restart (graceful)
# ==============================================================================
if slug_enabled "opcache-tune"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- OPcache tuning --${C_RESET}"

    php_versions=$(detect_php_versions)
    for ver in ${php_versions}; do
        ini_file="/etc/php/${ver}/fpm/php.ini"
        [[ ! -f "${ini_file}" ]] && continue

        needs_tune=0
        validate_ts=$(grep -E '^opcache\.validate_timestamps' "${ini_file}" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "1")
        realpath_sz=$(grep -E '^realpath_cache_size' "${ini_file}" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "16K")
        mem_cons=$(grep -E '^opcache\.memory_consumption' "${ini_file}" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "128")

        [[ "${validate_ts}" == "1" ]] && { log_warn "php${ver}: opcache.validate_timestamps=1"; needs_tune=1; }
        [[ "${realpath_sz}" == "16K" || "${realpath_sz}" == "16384" ]] && { log_warn "php${ver}: realpath_cache_size=16K"; needs_tune=1; }
        [[ "${mem_cons}" -lt 200 ]] 2>/dev/null && { log_warn "php${ver}: opcache.memory_consumption=${mem_cons}"; needs_tune=1; }

        if [[ "${needs_tune}" -eq 1 ]]; then
            if confirm_safe "Apply OPcache tuning for php${ver} (validate_timestamps=0, realpath_cache=4096K, memory=256)"; then
                if [[ "${DRY_RUN}" -eq 0 ]]; then
                    cp "${ini_file}" "${ini_file}.bak.$(date +%Y%m%d%H%M%S)"

                    # Apply each setting: update if present, append if not
                    apply_ini_setting() {
                        local file="${1}" key="${2}" val="${3}"
                        if grep -qE "^${key}\s*=" "${file}"; then
                            sed -i "s|^${key}\s*=.*|${key} = ${val}|" "${file}"
                        else
                            echo "${key} = ${val}" >> "${file}"
                        fi
                    }

                    apply_ini_setting "${ini_file}" "opcache.validate_timestamps" "0"
                    apply_ini_setting "${ini_file}" "realpath_cache_size" "4096K"
                    apply_ini_setting "${ini_file}" "realpath_cache_ttl" "600"
                    apply_ini_setting "${ini_file}" "opcache.memory_consumption" "256"
                    apply_ini_setting "${ini_file}" "opcache.max_accelerated_files" "20000"
                    apply_ini_setting "${ini_file}" "opcache.interned_strings_buffer" "16"

                    run "systemctl restart php${ver}-fpm"
                    sleep 1
                    if systemctl is-active --quiet "php${ver}-fpm"; then
                        log_fix "php${ver} OPcache tuned and FPM restarted"
                    else
                        log_err "php${ver}-fpm failed to restart -- restoring backup"
                        cp "${ini_file}.bak."* "${ini_file}" 2>/dev/null || true
                        systemctl restart "php${ver}-fpm" || true
                    fi
                else
                    log_dry "Would tune OPcache in ${ini_file} and restart php${ver}-fpm"
                fi
            else
                log_skip "opcache-tune for php${ver}"
            fi
        else
            log_ok "php${ver} OPcache settings already tuned"
        fi
    done
fi

# ==============================================================================
# FIX: mysql-slowlog
# Enables slow query log at runtime (no restart needed, purely additive)
# Safe: only adds logging, cannot break anything
# ==============================================================================
if slug_enabled "mysql-slowlog"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- MySQL slow query log --${C_RESET}"

    if ! cmd_exists mysql; then
        log_skip "mysql not found"
    else
        slow_log=$(mysql -e "SHOW VARIABLES LIKE 'slow_query_log';" 2>/dev/null \
            | awk '/slow_query_log/{print $2}' || echo "")
        if [[ "${slow_log}" == "ON" ]]; then
            log_ok "MySQL slow query log already ON"
        else
            if confirm_safe "Enable MySQL slow query log (long_query_time=1s, runtime only -- persists until restart)"; then
                run "mysql -e \"SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 1;\""
                log_fix "MySQL slow query log enabled (runtime). Add to /etc/mysql/my.cnf to persist."
                log_warn "To persist: add slow_query_log=1 and long_query_time=1 under [mysqld] in /etc/mysql/my.cnf"
            else
                log_skip "mysql-slowlog"
            fi
        fi
    fi
fi

# ==============================================================================
# FIX: env-debug-off
# Sets APP_DEBUG=false on all projects that have it true
# DANGEROUS: could hide errors on dev projects -- always prompts per-project
# ==============================================================================
if slug_enabled "env-debug-off"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- Laravel APP_DEBUG=false --${C_RESET}"

    while IFS= read -r project; do
        env_file="${project}/.env"
        [[ ! -f "${env_file}" ]] && continue
        domain=$(basename "$(dirname "${project}")")
        owner=$(stat -c '%U' "${project}" 2>/dev/null || echo "www-data")

        debug_val=$(grep -E '^APP_DEBUG=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
        [[ "${debug_val}" != "true" ]] && { log_ok "APP_DEBUG already off [${domain}]"; continue; }

        log_warn "APP_DEBUG=true in [${domain}]"
        if confirm_dangerous \
            "Set APP_DEBUG=false in ${domain}" \
            "This disables the Debugbar, query logging and stack traces. Do NOT apply if this is actively used for debugging."; then

            if [[ "${DRY_RUN}" -eq 0 ]]; then
                cp "${env_file}" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
                sed -i 's/^APP_DEBUG=true/APP_DEBUG=false/' "${env_file}"
                # Clear config cache so Laravel picks up the change
                phpbin=$(command -v "php$(grep -E '^php_version' "/home/$(echo "${project}" | cut -d/ -f3)/conf/web/"*".conf" 2>/dev/null | head -n1 | awk '{print $3}')" 2>/dev/null || command -v php)
                sudo -u "${owner}" "${phpbin}" "${project}/artisan" config:clear --no-interaction >> "${HEAL_LOG}" 2>&1 || true
                log_fix "APP_DEBUG=false set for [${domain}]"
            else
                log_dry "Would set APP_DEBUG=false in ${env_file}"
            fi
        else
            log_skip "env-debug-off for ${domain}"
        fi
    done < <(detect_projects)
fi

# ==============================================================================
# FIX: env-production
# Sets APP_ENV=production on projects still on local/dev/staging
# DANGEROUS: could break dev workflows -- always prompts per-project
# ==============================================================================
if slug_enabled "env-production"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- Laravel APP_ENV=production --${C_RESET}"

    while IFS= read -r project; do
        env_file="${project}/.env"
        [[ ! -f "${env_file}" ]] && continue
        domain=$(basename "$(dirname "${project}")")
        owner=$(stat -c '%U' "${project}" 2>/dev/null || echo "www-data")

        env_val=$(grep -E '^APP_ENV=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
        [[ "${env_val}" == "production" ]] && { log_ok "APP_ENV=production [${domain}]"; continue; }

        log_warn "APP_ENV=${env_val} in [${domain}]"
        if confirm_dangerous \
            "Set APP_ENV=production in ${domain} (currently: ${env_val})" \
            "This enables production optimizations and disables dev-only features. Do NOT apply to genuine dev/staging environments."; then

            if [[ "${DRY_RUN}" -eq 0 ]]; then
                cp "${env_file}" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
                sed -i "s/^APP_ENV=${env_val}/APP_ENV=production/" "${env_file}"
                phpbin=$(command -v php)
                sudo -u "${owner}" "${phpbin}" "${project}/artisan" config:clear --no-interaction >> "${HEAL_LOG}" 2>&1 || true
                log_fix "APP_ENV=production set for [${domain}]"
            else
                log_dry "Would set APP_ENV=production in ${env_file}"
            fi
        else
            log_skip "env-production for ${domain}"
        fi
    done < <(detect_projects)
fi

# env-cache-redis removed -- requires phpredis extension (php8.x-redis) installed first.
# To enable Redis cache: apt install php8.4-redis, then edit .env manually.

# ==============================================================================
# FIX: laravel-500
# Diagnoses and repairs a 500 on a Laravel project by clearing all caches
# and checking for common causes (wrong .env values, missing storage links, etc.)
# SAFE: only clears caches, never modifies app code or .env
# ==============================================================================
if slug_enabled "laravel-500"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- Laravel 500 diagnosis and repair --${C_RESET}"

    while IFS= read -r project; do
        domain=$(basename "$(dirname "${project}")")
        owner=$(stat -c '%U' "${project}" 2>/dev/null || echo "www-data")
        phpbin=$(command -v php)
        env_file="${project}/.env"

        # Quick HTTP check
        app_url=$(grep -E '^APP_URL=' "${env_file}" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
        http_code=""
        if [[ -n "${app_url}" ]] && cmd_exists curl; then
            http_code=$(curl -o /dev/null -sk -w "%{http_code}" --max-time 5 "${app_url}/" 2>/dev/null || echo "000")
        fi

        if [[ "${http_code}" != "500" ]] && [[ "${http_code}" != "000" ]]; then
            log_ok "[${domain}] HTTP ${http_code} -- no 500 detected"
            continue
        fi

        log_warn "[${domain}] HTTP ${http_code} detected"

        # Show last Laravel error
        laravel_log="${project}/storage/logs/laravel.log"
        if [[ -f "${laravel_log}" ]]; then
            echo ""
            echo "${C_RED}  Last error in ${laravel_log}:${C_RESET}"
            grep -A 5 'ERROR\|CRITICAL\|exception' "${laravel_log}" | tail -n 20 | sed 's/^/  /'
            echo ""
        fi

        if confirm_safe "Clear all caches for [${domain}] (safe fix for stale bootstrap cache)"; then
            if [[ "${DRY_RUN}" -eq 0 ]]; then
                for artisan_cmd in cache:clear config:clear route:clear view:clear event:clear optimize:clear; do
                    result=$(sudo -u "${owner}" "${phpbin}" "${project}/artisan" ${artisan_cmd} --no-interaction 2>&1 || true)
                    log_fix "  artisan ${artisan_cmd}: ${result}"
                done

                # Fix storage permissions
                if [[ -d "${project}/storage" ]]; then
                    find "${project}/storage" -type d ! -perm 755 -exec chmod 755 {} \; 2>/dev/null || true
                    find "${project}/storage" -type f ! -perm 644 -exec chmod 644 {} \; 2>/dev/null || true
                    chown -R "${owner}:${owner}" "${project}/storage" 2>/dev/null || true
                    log_fix "Storage permissions fixed for [${domain}]"
                fi

                # Re-check
                sleep 1
                if [[ -n "${app_url}" ]] && cmd_exists curl; then
                    new_code=$(curl -o /dev/null -sk -w "%{http_code}" --max-time 5 "${app_url}/" 2>/dev/null || echo "000")
                    if [[ "${new_code}" == "500" ]]; then
                        log_err "[${domain}] Still 500 after cache clear -- check laravel.log manually:"
                        log_err "  tail -n 50 ${laravel_log}"
                    else
                        log_ok "[${domain}] HTTP ${new_code} -- resolved"
                    fi
                fi
            else
                log_dry "Would clear all caches and fix storage perms for ${project}"
            fi
        else
            log_skip "laravel-500 for ${domain}"
        fi
    done < <(detect_projects)
fi


# Runs composer w-cache on all Webkernel projects (or php artisan cache sequence)
# SAFE: purely additive caching, no data modification
# ==============================================================================
if slug_enabled "laravel-cache"; then
    echo ""
    echo "${C_BOLD}${C_BLUE}-- Laravel cache warm-up --${C_RESET}"

    while IFS= read -r project; do
        domain=$(basename "$(dirname "${project}")")
        owner=$(stat -c '%U' "${project}" 2>/dev/null || echo "www-data")
        phpbin=$(command -v php)

        # Check APP_DEBUG -- warn if still true before caching
        debug_val=$(grep -E '^APP_DEBUG=' "${project}/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
        if [[ "${debug_val}" == "true" ]]; then
            log_warn "[${domain}] APP_DEBUG=true -- run env-debug-off before caching for best results"
        fi

        if confirm_safe "Run cache warm-up on [${domain}] as user ${owner}"; then
            log_fix "Warming up [${domain}]..."
            if [[ "${DRY_RUN}" -eq 0 ]]; then
                # Clear first
                for artisan_cmd in cache:clear config:clear route:clear view:clear event:clear optimize:clear; do
                    sudo -u "${owner}" "${phpbin}" "${project}/artisan" ${artisan_cmd} --no-interaction >> "${HEAL_LOG}" 2>&1 || true
                done

                # Check if w-cache composer script exists
                if [[ -f "${project}/composer.json" ]] && grep -q '"w-cache"' "${project}/composer.json"; then
                    log_fix "Running composer w-cache for [${domain}]"
                    (cd "${project}" && sudo -u "${owner}" composer w-cache --no-interaction >> "${HEAL_LOG}" 2>&1) || \
                        log_err "composer w-cache failed for [${domain}] -- check ${HEAL_LOG}"
                else
                    # Fallback: manual artisan sequence
                    for artisan_cmd in config:cache route:cache view:cache event:cache optimize; do
                        sudo -u "${owner}" "${phpbin}" "${project}/artisan" ${artisan_cmd} --no-interaction >> "${HEAL_LOG}" 2>&1 || true
                    done
                    log_fix "Artisan cache built for [${domain}] (no w-cache composer script found)"
                fi

                # Verify config cache was created
                if [[ -f "${project}/bootstrap/cache/config.php" ]]; then
                    log_ok "Config cache verified for [${domain}]"
                else
                    log_err "Config cache not found after warm-up for [${domain}]"
                fi
            else
                log_dry "Would run composer w-cache in ${project}"
            fi
        else
            log_skip "laravel-cache for ${domain}"
        fi
    done < <(detect_projects)
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "${C_BOLD}${C_WHITE}=============================================================="
echo "  w-autoheal complete"
echo "  Log: ${HEAL_LOG}"
echo "==============================================================${C_RESET}"
echo ""
echo "${C_DIM}  Recommended order:"
echo "    1. --only=opcache-tune"
echo "    2. --only=fpm-dummy-children"
echo "    3. --only=fpm-dynamic"
echo "    4. --only=mysql-slowlog"
echo "    5. --only=env-debug-off         (dangerous, per-project prompt)"
echo "    6. --only=env-production         (dangerous, per-project prompt)"
echo "    7. --only=laravel-cache${C_RESET}"
echo ""
echo "${C_DIM}  Or run safe actions automatically:"
echo "    sudo bash server-apps-autoheal.sh --yes${C_RESET}"
echo ""
