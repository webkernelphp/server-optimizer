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
#  Script : server-perf-report  (performance diagnostic)
#  https://github.com/webkernelphp/server-optimizer
#
#  Target  : Webkernel OF (Debian family deb12/13, Ubuntu 20.04+) + HestiaCP
#  License : EPL-2.0
#  Usage   : sudo bash server-perf-report.sh [OPTIONS]
#
#  Options:
#    --test                   Run HTTP simulation against https://test.webkernelphp.com/
#    --test="https://url"     Run HTTP simulation against given URL
#    --artisan                Run Laravel cache warm-up on detected Webkernel projects
#    --no-color               Disable terminal colors
#    -h, --help               Show this help
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

# ------------------------------------------------------------------------------
# Issue collector -- populated throughout the script, printed at top of report
# after all sections run (two-pass: collect then summarize)
# ------------------------------------------------------------------------------
# Each entry format: "SEVERITY|LABEL|FIX_COMMAND_OR_EXPLANATION"
declare -a ISSUES_CRITICAL=()
declare -a ISSUES_WARNING=()
declare -a ISSUES_OK=()

issue_critical() { ISSUES_CRITICAL+=("${1}|${2}|${3}"); }
issue_warning()  { ISSUES_WARNING+=("${1}|${2}|${3}"); }
issue_ok()       { ISSUES_OK+=("${1}"); }

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
REPORT_DIR="/root/sysadmin/webkernel-reports"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_FILE="${REPORT_DIR}/server-perf-report_${TIMESTAMP}.txt"
# Detail is written to a temp file during execution.
# At the end: SUMMARY is prepended and the result becomes REPORT_FILE.
DETAIL_FILE=$(mktemp /tmp/w-perf-detail.XXXXXX)
RUN_TEST=0
TEST_URL="https://test.webkernelphp.com/"
RUN_ARTISAN=0
HESTIA_BIN="${HESTIA:-/usr/local/hestia}/bin"

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --test)
            RUN_TEST=1
            ;;
        --test=*)
            RUN_TEST=1
            TEST_URL="${arg#--test=}"
            ;;
        --artisan)
            RUN_ARTISAN=1
            ;;
        --no-color)
            C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
            C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE="" C_GRAY=""
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
# Helpers
# ------------------------------------------------------------------------------
log_info()  { echo "${C_CYAN}${SYM_INFO}  ${*}${C_RESET}"; }
log_ok()    { echo "${C_GREEN}${SYM_OK} ${*}${C_RESET}"; }
log_warn()  { echo "${C_YELLOW}${SYM_WARN} ${*}${C_RESET}"; }
log_err()   { echo "${C_RED}${SYM_ERR} ${*}${C_RESET}"; }
log_run()   { echo "${C_GRAY}${SYM_RUN} ${*}${C_RESET}"; }
log_skip()  { echo "${C_DIM}${SYM_SKIP} ${*}${C_RESET}"; }
log_head()  { echo "${C_BOLD}${C_WHITE}${*}${C_RESET}"; }
log_dim()   { echo "${C_DIM}${*}${C_RESET}"; }

die() { log_err "${*}"; exit 1; }

# Write to both terminal and DETAIL_FILE (summary prepended at end)
tee_line() {
    local clean
    clean=$(echo "${*}" | sed 's/\x1b\[[0-9;]*m//g')
    echo "${*}"
    echo "${clean}" >> "${DETAIL_FILE}"
}

section() {
    local title="${*}"
    local bar
    bar=$(printf '%0.s-' {1..78})
    tee_line ""
    tee_line "${C_BOLD}${C_BLUE}## ${title}${C_RESET}"
    tee_line "${C_DIM}${bar}${C_RESET}"
}

subsection() {
    tee_line ""
    tee_line "${C_BOLD}${C_CYAN}### ${*}${C_RESET}"
}

# Capture command output into detail file
capture() {
    local label="${1}"
    shift
    local output
    tee_line "${C_GRAY}${SYM_RUN} ${label}${C_RESET}"
    if output=$("$@" 2>&1); then
        echo "${output}"
        echo "${output}" >> "${DETAIL_FILE}"
    else
        tee_line "${C_YELLOW}${SYM_WARN} Command returned non-zero or not available: $*${C_RESET}"
    fi
}

# Safe capture -- never aborts on failure
safe_capture() {
    local label="${1}"
    shift
    tee_line "${C_GRAY}${SYM_RUN} ${label}${C_RESET}"
    local output
    output=$("$@" 2>&1 || true)
    echo "${output}"
    echo "${output}" >> "${DETAIL_FILE}"
}

cmd_exists() { command -v "${1}" &>/dev/null; }

hestia_cmd() {
    local cmd="${HESTIA_BIN}/${1}"
    if [[ -x "${cmd}" ]]; then
        shift
        "${cmd}" "$@" 2>&1 || true
    else
        echo "(hestia command not found: ${1})"
    fi
}

# ------------------------------------------------------------------------------
# Setup report directory
# ------------------------------------------------------------------------------
mkdir -p "${REPORT_DIR}"

# Write detail header into temp file (summary will be prepended at the end)
{
    echo "=============================================================="
    echo "  Webkernel OS -- server-perf-report  (full detail)"
    echo "  Generated : ${TIMESTAMP}"
    echo "  Hostname  : $(hostname -f 2>/dev/null || hostname)"
    echo "  Kernel    : $(uname -r)"
    echo "  User      : $(id)"
    echo "=============================================================="
} >> "${DETAIL_FILE}"

log_head ""
log_head "  Webkernel OS -- server-perf-report"
log_head "  Report   : ${REPORT_FILE}"
log_head "  Started  : ${TIMESTAMP}"
log_head ""

# ==============================================================================
# SECTION 1 -- SYSTEM OVERVIEW
# ==============================================================================
section "SYSTEM OVERVIEW"

subsection "OS / Kernel"
safe_capture "OS release" cat /etc/os-release
safe_capture "Kernel" uname -a
safe_capture "Uptime / load" uptime
safe_capture "Load average raw" cat /proc/loadavg

subsection "CPU"
safe_capture "CPU info" lscpu
safe_capture "CPU cores" nproc

subsection "Memory"
safe_capture "Memory (free -m)" free -m
safe_capture "Memory (vmstat)" vmstat -s

subsection "Disk"
safe_capture "Disk usage (df -h)" df -h
safe_capture "Inodes (df -i)" df -i
if cmd_exists iostat; then
    safe_capture "IO stats (iostat -xz 1 3)" iostat -xz 1 3
else
    tee_line "${C_YELLOW}${SYM_WARN} iostat not found -- install sysstat for IO metrics${C_RESET}"
fi

subsection "Top Processes by CPU"
safe_capture "ps top CPU" ps -eo pid,ppid,user,cmd,%mem,%cpu --sort=-%cpu --no-headers | head -n 30

subsection "Top Processes by RAM"
safe_capture "ps top RAM" ps -eo pid,ppid,user,cmd,%mem,%cpu --sort=-%mem --no-headers | head -n 30

# ==============================================================================
# SECTION 2 -- NETWORK
# ==============================================================================
section "NETWORK"

safe_capture "Network interfaces (ip a)" ip a
safe_capture "Listening sockets (ss -tlnp)" ss -tlnp
safe_capture "Active connections count" ss -s
safe_capture "TIME_WAIT count" ss -tan | grep -c TIME_WAIT || true
safe_capture "ESTABLISHED count" ss -tan | grep -c ESTABLISHED || true

if cmd_exists netstat; then
    safe_capture "netstat connection states" netstat -an | awk '{print $6}' | sort | uniq -c | sort -rn
fi

# ==============================================================================
# SECTION 3 -- HESTIACP
# ==============================================================================
section "HESTIACP"

if [[ -d "${HESTIA_BIN}" ]]; then
    tee_line "${C_GREEN}${SYM_OK} HestiaCP bin directory found: ${HESTIA_BIN}${C_RESET}"

    subsection "HestiaCP System Configuration"
    safe_capture "v-list-sys-config" "${HESTIA_BIN}/v-list-sys-config"

    subsection "HestiaCP Services"
    safe_capture "v-list-sys-services" "${HESTIA_BIN}/v-list-sys-services"

    subsection "HestiaCP System Info"
    safe_capture "v-list-sys-info" "${HESTIA_BIN}/v-list-sys-info"

    subsection "HestiaCP CPU Status"
    safe_capture "v-list-sys-cpu-status" "${HESTIA_BIN}/v-list-sys-cpu-status"

    subsection "HestiaCP Memory Status"
    safe_capture "v-list-sys-memory-status" "${HESTIA_BIN}/v-list-sys-memory-status"

    subsection "HestiaCP Disk Status"
    safe_capture "v-list-sys-disk-status" "${HESTIA_BIN}/v-list-sys-disk-status"

    subsection "HestiaCP Network Status"
    safe_capture "v-list-sys-network-status" "${HESTIA_BIN}/v-list-sys-network-status"

    subsection "HestiaCP Web Status"
    safe_capture "v-list-sys-web-status" "${HESTIA_BIN}/v-list-sys-web-status"

    subsection "HestiaCP DB Status"
    safe_capture "v-list-sys-db-status" "${HESTIA_BIN}/v-list-sys-db-status"

    subsection "HestiaCP Mail Status"
    safe_capture "v-list-sys-mail-status" "${HESTIA_BIN}/v-list-sys-mail-status"

    subsection "HestiaCP DNS Status"
    safe_capture "v-list-sys-dns-status" "${HESTIA_BIN}/v-list-sys-dns-status"

    subsection "HestiaCP Available PHP Versions"
    safe_capture "v-list-sys-php" "${HESTIA_BIN}/v-list-sys-php"

    subsection "HestiaCP Default PHP"
    safe_capture "v-list-default-php" "${HESTIA_BIN}/v-list-default-php"

    subsection "HestiaCP PHP Config"
    safe_capture "v-list-sys-php-config" "${HESTIA_BIN}/v-list-sys-php-config"

    subsection "HestiaCP Nginx Config"
    safe_capture "v-list-sys-nginx-config" "${HESTIA_BIN}/v-list-sys-nginx-config"

    subsection "HestiaCP MySQL Config"
    safe_capture "v-list-sys-mysql-config" "${HESTIA_BIN}/v-list-sys-mysql-config"

    subsection "HestiaCP Web Templates"
    safe_capture "v-list-web-templates" "${HESTIA_BIN}/v-list-web-templates"

    subsection "HestiaCP Backend Templates"
    safe_capture "v-list-web-templates-backend" "${HESTIA_BIN}/v-list-web-templates-backend"

    subsection "HestiaCP Proxy Templates"
    safe_capture "v-list-web-templates-proxy" "${HESTIA_BIN}/v-list-web-templates-proxy"

    subsection "HestiaCP Users"
    safe_capture "v-list-users" "${HESTIA_BIN}/v-list-users"

    subsection "HestiaCP Available Updates"
    safe_capture "v-list-sys-hestia-updates" "${HESTIA_BIN}/v-list-sys-hestia-updates"

    # Per-user web domains
    subsection "HestiaCP Web Domains per User"
    while IFS= read -r huser; do
        [[ -z "${huser}" ]] && continue
        tee_line "${C_DIM}  -- User: ${huser}${C_RESET}"
        safe_capture "v-list-web-domains ${huser}" "${HESTIA_BIN}/v-list-web-domains" "${huser}"
    done < <("${HESTIA_BIN}/v-list-users" 2>/dev/null | awk 'NR>1 {print $1}' || true)

else
    tee_line "${C_YELLOW}${SYM_WARN} HestiaCP not found at ${HESTIA_BIN} -- skipping HestiaCP section${C_RESET}"
fi

# ==============================================================================
# SECTION 4 -- NGINX
# ==============================================================================
section "NGINX"

if cmd_exists nginx; then
    safe_capture "nginx version" nginx -v
    safe_capture "nginx config test" nginx -t
    safe_capture "nginx config dump (first 300 lines)" bash -c 'nginx -T 2>&1 | head -n 300'

    subsection "Nginx error log (last 100 lines)"
    for logpath in /var/log/nginx/error.log /var/log/hestia/nginx/error.log; do
        if [[ -f "${logpath}" ]]; then
            safe_capture "nginx error log: ${logpath}" tail -n 100 "${logpath}"
        fi
    done

    subsection "Nginx access log -- slow/5xx sample"
    for logpath in /var/log/nginx/access.log; do
        if [[ -f "${logpath}" ]]; then
            tee_line "${C_GRAY}${SYM_INFO} 5xx errors in ${logpath}:${C_RESET}"
            grep -E ' 5[0-9]{2} ' "${logpath}" | tail -n 50 >> "${REPORT_FILE}" 2>/dev/null || true
        fi
    done

    subsection "Nginx active connections"
    if cmd_exists curl; then
        local_stub="http://127.0.0.1/nginx_status"
        result=$(curl -sf --connect-timeout 3 "${local_stub}" 2>/dev/null || echo "(nginx_status not accessible at ${local_stub})")
        tee_line "${result}"
    fi
else
    tee_line "${C_YELLOW}${SYM_WARN} nginx not found${C_RESET}"
fi

# ==============================================================================
# SECTION 5 -- APACHE2
# ==============================================================================
section "APACHE2"

if cmd_exists apache2; then
    safe_capture "apache2 version" apache2 -v
    safe_capture "apache2 config test" apache2ctl configtest 2>&1 || true
    safe_capture "apache2 modules" apache2ctl -M 2>&1 || true

    subsection "Apache error log (last 100 lines)"
    for logpath in /var/log/apache2/error.log; do
        [[ -f "${logpath}" ]] && safe_capture "apache error log" tail -n 100 "${logpath}"
    done
else
    tee_line "${SYM_SKIP} apache2 not found"
fi

# ==============================================================================
# SECTION 6 -- PHP-FPM
# ==============================================================================
section "PHP-FPM"

subsection "Installed PHP versions"
safe_capture "php binaries" find /usr/bin /usr/sbin -maxdepth 1 -name 'php*' 2>/dev/null | sort

PHP_VERSIONS=()
for phpbin in /usr/bin/php*; do
    if [[ -x "${phpbin}" ]] && [[ "${phpbin}" =~ php[0-9] ]]; then
        ver=$("${phpbin}" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
        [[ -n "${ver}" ]] && PHP_VERSIONS+=("${ver}")
    fi
done
# Deduplicate
mapfile -t PHP_VERSIONS < <(printf '%s\n' "${PHP_VERSIONS[@]}" | sort -uV)

tee_line "${C_DIM}  Detected PHP versions: ${PHP_VERSIONS[*]:-none}${C_RESET}"

for ver in "${PHP_VERSIONS[@]}"; do
    subsection "PHP ${ver}"

    phpbin="/usr/bin/php${ver}"
    [[ ! -x "${phpbin}" ]] && phpbin="/usr/bin/php"

    safe_capture "php${ver} -i (key values)" "${phpbin}" -r '
        $keys = ["memory_limit","max_execution_time","upload_max_filesize","post_max_size",
                 "opcache.enable","opcache.memory_consumption","opcache.max_accelerated_files",
                 "opcache.validate_timestamps","opcache.revalidate_freq","opcache.jit",
                 "opcache.jit_buffer_size","realpath_cache_size","realpath_cache_ttl",
                 "session.gc_maxlifetime","display_errors","error_reporting","expose_php"];
        foreach ($keys as $k) {
            $v = ini_get($k);
            echo str_pad($k, 45) . " = " . ($v === false ? "(not set)" : $v) . "\n";
        }
    ' 2>/dev/null || true

    safe_capture "php${ver} loaded extensions" "${phpbin}" -m 2>/dev/null | sort | tr '\n' ' '

    # FPM config
    fpm_conf="/etc/php/${ver}/fpm/php-fpm.conf"
    pool_dir="/etc/php/${ver}/fpm/pool.d"
    [[ -f "${fpm_conf}" ]] && safe_capture "fpm.conf ${ver}" cat "${fpm_conf}"

    if [[ -d "${pool_dir}" ]]; then
        for pool_file in "${pool_dir}"/*.conf; do
            [[ -f "${pool_file}" ]] && safe_capture "pool: ${pool_file}" cat "${pool_file}"
        done
    fi

    # FPM status
    fpm_service="php${ver}-fpm"
    safe_capture "systemctl status ${fpm_service}" systemctl status "${fpm_service}" --no-pager -l 2>/dev/null || true

    # FPM error log
    fpm_log="/var/log/php${ver}-fpm.log"
    [[ -f "${fpm_log}" ]] && safe_capture "fpm log (last 80): ${fpm_log}" tail -n 80 "${fpm_log}"

    # OPcache status via PHP
    opcache_status=$("${phpbin}" -r '
        if (function_exists("opcache_get_status")) {
            $s = opcache_get_status(false);
            if ($s === false) { echo "OPcache not active in CLI SAPI\n"; }
            else {
                echo "enabled              : " . ($s["opcache_enabled"] ? "yes" : "no") . "\n";
                echo "full                 : " . ($s["cache_full"] ? "YES (CRITICAL)" : "no") . "\n";
                echo "used_memory_MB       : " . round($s["memory_usage"]["used_memory"]/1048576,2) . "\n";
                echo "free_memory_MB       : " . round($s["memory_usage"]["free_memory"]/1048576,2) . "\n";
                echo "wasted_memory_pct    : " . round($s["memory_usage"]["current_wasted_percentage"],2) . "\n";
                echo "cached_scripts       : " . $s["opcache_statistics"]["num_cached_scripts"] . "\n";
                echo "max_cached_files     : " . $s["opcache_statistics"]["max_cached_keys"] . "\n";
                echo "hits                 : " . $s["opcache_statistics"]["hits"] . "\n";
                echo "misses               : " . $s["opcache_statistics"]["misses"] . "\n";
                $total = $s["opcache_statistics"]["hits"] + $s["opcache_statistics"]["misses"];
                if ($total > 0) echo "hit_ratio_pct        : " . round($s["opcache_statistics"]["hits"]/$total*100,2) . "\n";
            }
        } else { echo "opcache_get_status() not available\n"; }
    ' 2>/dev/null || echo "(could not retrieve OPcache status)")
    tee_line "${C_CYAN}${SYM_INFO} OPcache status for php${ver}:${C_RESET}"
    tee_line "${opcache_status}"
done

# ==============================================================================
# SECTION 7 -- MYSQL / MARIADB
# ==============================================================================
section "MYSQL / MARIADB"

for mysql_bin in mysql mariadb; do
    if cmd_exists "${mysql_bin}"; then
        safe_capture "${mysql_bin} version" "${mysql_bin}" --version
        break
    fi
done

for cnf in /etc/mysql/my.cnf /etc/mysql/mariadb.conf.d/50-server.cnf /etc/mysql/mysql.conf.d/mysqld.cnf; do
    [[ -f "${cnf}" ]] && safe_capture "MySQL config: ${cnf}" cat "${cnf}"
done

safe_capture "MySQL service status" systemctl status mysql --no-pager -l 2>/dev/null || \
    safe_capture "MariaDB service status" systemctl status mariadb --no-pager -l 2>/dev/null || true

subsection "MySQL performance variables"
if cmd_exists mysql; then
    mysql_vars=$(mysql -e "SHOW GLOBAL VARIABLES WHERE Variable_name IN (
        'innodb_buffer_pool_size','innodb_log_file_size','innodb_flush_log_at_trx_commit',
        'query_cache_size','query_cache_type','query_cache_limit',
        'max_connections','max_allowed_packet','wait_timeout','interactive_timeout',
        'slow_query_log','slow_query_log_file','long_query_time',
        'key_buffer_size','thread_cache_size','table_open_cache',
        'tmp_table_size','max_heap_table_size','join_buffer_size','sort_buffer_size'
    );" 2>/dev/null || echo "(could not connect to MySQL -- check credentials)")
    tee_line "${mysql_vars}"

    subsection "MySQL status counters"
    mysql_status=$(mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
        'Threads_connected','Threads_running','Threads_created','Connections',
        'Aborted_connects','Aborted_clients',
        'Qcache_hits','Qcache_inserts','Qcache_not_cached','Qcache_free_memory',
        'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
        'Slow_queries','Questions','Uptime'
    );" 2>/dev/null || echo "(could not retrieve status)")
    tee_line "${mysql_status}"
fi

subsection "MySQL slow query log (last 50 lines)"
for slq in /var/log/mysql/mysql-slow.log /var/log/mysql/slow.log; do
    [[ -f "${slq}" ]] && safe_capture "slow query log: ${slq}" tail -n 50 "${slq}"
done

# ==============================================================================
# SECTION 8 -- REDIS
# ==============================================================================
section "REDIS"

if cmd_exists redis-cli; then
    safe_capture "redis-cli ping" redis-cli ping 2>/dev/null || true
    safe_capture "redis info" redis-cli info 2>/dev/null || true
    safe_capture "redis config get maxmemory" redis-cli config get maxmemory 2>/dev/null || true
    safe_capture "redis config get maxmemory-policy" redis-cli config get maxmemory-policy 2>/dev/null || true
    safe_capture "redis keyspace" redis-cli info keyspace 2>/dev/null || true
else
    tee_line "${SYM_SKIP} redis-cli not found -- Redis not installed or not in PATH"
fi

for redis_conf in /etc/redis/redis.conf /etc/redis.conf; do
    [[ -f "${redis_conf}" ]] && safe_capture "redis config: ${redis_conf}" grep -Ev '^#|^$' "${redis_conf}"
done

# ==============================================================================
# SECTION 9 -- SUPERVISOR / QUEUE WORKERS
# ==============================================================================
section "SUPERVISOR / QUEUE WORKERS"

if cmd_exists supervisorctl; then
    safe_capture "supervisorctl status" supervisorctl status 2>/dev/null || true
    for spvd in /etc/supervisor/conf.d/*.conf /etc/supervisord.d/*.conf; do
        [[ -f "${spvd}" ]] && safe_capture "supervisor conf: ${spvd}" cat "${spvd}"
    done
else
    tee_line "${SYM_SKIP} supervisorctl not found"
fi

# Laravel queue workers running in background
subsection "Laravel artisan queue:work processes"
safe_capture "queue workers" ps -eo pid,user,cmd | grep -E 'artisan queue' | grep -v grep || true

# ==============================================================================
# SECTION 10 -- SYSTEMD SERVICES (RELEVANT)
# ==============================================================================
section "SYSTEMD SERVICES"

relevant_services=(
    nginx apache2 php-fpm
    mysql mariadb redis supervisor
    cron hestia
)

for svc in "${relevant_services[@]}"; do
    # Match any variant (e.g. php8.2-fpm, php7.4-fpm)
    mapfile -t matched < <(systemctl list-units --type=service --all --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -E "^${svc}" || true)
    for m in "${matched[@]}"; do
        safe_capture "systemctl: ${m}" systemctl status "${m}" --no-pager -l 2>/dev/null || true
    done
done

# ==============================================================================
# SECTION 11 -- CRON JOBS
# ==============================================================================
section "CRON JOBS"

safe_capture "root crontab" crontab -l 2>/dev/null || true
safe_capture "/etc/cron.d contents" ls -la /etc/cron.d/ 2>/dev/null || true
for f in /etc/cron.d/*; do
    [[ -f "${f}" ]] && safe_capture "cron.d: ${f}" cat "${f}"
done
safe_capture "/etc/crontab" cat /etc/crontab 2>/dev/null || true

# ==============================================================================
# SECTION 12 -- WEBKERNEL / LARAVEL PROJECTS
# ==============================================================================
section "WEBKERNEL / LARAVEL PROJECTS"

subsection "Detecting projects under /home/*/web/*/public_html/"

declare -a W_PROJECTS=()

while IFS= read -r pubhtml; do
    dir=$(dirname "${pubhtml}")
    # Check for artisan (Laravel project indicator)
    if [[ -f "${pubhtml}/artisan" ]]; then
        W_PROJECTS+=("${pubhtml}")
        tee_line "${C_GREEN}${SYM_OK} Laravel/Webkernel project: ${pubhtml}${C_RESET}"

        # Detect owner
        owner=$(stat -c '%U' "${pubhtml}" 2>/dev/null || echo "unknown")
        tee_line "${C_DIM}  Owner: ${owner}${C_RESET}"

        # Check .env
        if [[ -f "${pubhtml}/.env" ]]; then
            tee_line "${C_GREEN}${SYM_OK} .env found${C_RESET}"
            env_app_env=$(grep -E '^APP_ENV=' "${pubhtml}/.env" | head -n1 || echo "APP_ENV not set")
            env_app_debug=$(grep -E '^APP_DEBUG=' "${pubhtml}/.env" | head -n1 || echo "APP_DEBUG not set")
            env_cache_driver=$(grep -E '^CACHE_DRIVER=' "${pubhtml}/.env" | head -n1 || echo "CACHE_DRIVER not set")
            env_queue_driver=$(grep -E '^QUEUE_CONNECTION=' "${pubhtml}/.env" | head -n1 || echo "QUEUE_CONNECTION not set")
            env_session_driver=$(grep -E '^SESSION_DRIVER=' "${pubhtml}/.env" | head -n1 || echo "SESSION_DRIVER not set")
            env_db_conn=$(grep -E '^DB_CONNECTION=' "${pubhtml}/.env" | head -n1 || echo "DB_CONNECTION not set")
            tee_line "  ${env_app_env}"
            tee_line "  ${env_app_debug}"
            tee_line "  ${env_cache_driver}"
            tee_line "  ${env_queue_driver}"
            tee_line "  ${env_session_driver}"
            tee_line "  ${env_db_conn}"
        else
            tee_line "${C_RED}${SYM_ERR} .env not found in ${pubhtml}${C_RESET}"
        fi

        # Check bootstrap/cache
        if [[ -d "${pubhtml}/bootstrap/cache" ]]; then
            tee_line "${C_DIM}  bootstrap/cache/ contents:${C_RESET}"
            ls -lh "${pubhtml}/bootstrap/cache/" 2>/dev/null | tee -a "${REPORT_FILE}" || true
        fi

        # Check storage permissions
        storage_dir="${pubhtml}/storage"
        if [[ -d "${storage_dir}" ]]; then
            bad_perms=$(find "${storage_dir}" ! -user "${owner}" 2>/dev/null | head -n 5 || true)
            if [[ -n "${bad_perms}" ]]; then
                tee_line "${C_YELLOW}${SYM_WARN} Storage permission issues:${C_RESET}"
                tee_line "${bad_perms}"
            else
                tee_line "${C_GREEN}${SYM_OK} Storage permissions look correct${C_RESET}"
            fi
        fi

        # Detect Webkernel installer-guard
        if [[ -f "${pubhtml}/bootstrap/webkernel/installer-guard.php" ]]; then
            tee_line "${C_CYAN}${SYM_INFO} Webkernel installer-guard.php detected${C_RESET}"
        fi

        # composer.json presence + scripts
        if [[ -f "${pubhtml}/composer.json" ]]; then
            tee_line "${C_DIM}  composer.json scripts available:${C_RESET}"
            grep -E '"w-clear"|"ws-clear"|"w-cache"' "${pubhtml}/composer.json" \
                | sed 's/^/    /' | tee -a "${REPORT_FILE}" || true
        fi

        # Laravel log tail
        laravel_log="${pubhtml}/storage/logs/laravel.log"
        if [[ -f "${laravel_log}" ]]; then
            tee_line "${C_CYAN}${SYM_INFO} Laravel log tail (last 80 lines):${C_RESET}"
            tail -n 80 "${laravel_log}" | tee -a "${REPORT_FILE}" || true
        else
            tee_line "${C_DIM}${SYM_SKIP} No laravel.log found${C_RESET}"
        fi

        # Horizon
        if [[ -f "${pubhtml}/artisan" ]]; then
            if grep -qr 'horizon' "${pubhtml}/composer.json" 2>/dev/null; then
                tee_line "${C_CYAN}${SYM_INFO} Laravel Horizon detected in composer.json${C_RESET}"
                safe_capture "horizon status" ps -eo pid,user,cmd | grep -E 'artisan horizon' | grep -v grep || true
            fi
        fi

    fi
done < <(find /home/*/web/*/public_html -maxdepth 0 -type d 2>/dev/null | sort)

if [[ ${#W_PROJECTS[@]} -eq 0 ]]; then
    tee_line "${SYM_SKIP} No Laravel/Webkernel projects found under /home/*/web/*/public_html/"
fi

# ==============================================================================
# SECTION 13 -- ARTISAN CACHE WARM-UP (optional, --artisan flag)
# ==============================================================================
section "ARTISAN CACHE WARM-UP"

if [[ "${RUN_ARTISAN}" -eq 1 ]]; then
    if [[ ${#W_PROJECTS[@]} -eq 0 ]]; then
        tee_line "${C_YELLOW}${SYM_WARN} No projects found -- nothing to warm up${C_RESET}"
    fi

    for project in "${W_PROJECTS[@]}"; do
        tee_line ""
        tee_line "${C_BOLD}${C_CYAN}  Project: ${project}${C_RESET}"

        owner=$(stat -c '%U' "${project}" 2>/dev/null || echo "www-data")
        phpbin=$(command -v php 2>/dev/null || echo "php")

        # Use installer-guard if available, else run artisan directly
        guard="${project}/bootstrap/webkernel/installer-guard.php"

        run_artisan_cmd() {
            local art_cmd="${*}"
            if [[ -f "${guard}" ]]; then
                sudo -u "${owner}" "${phpbin}" "${guard}" run-as-owner artisan ${art_cmd} 2>&1 || true
            else
                sudo -u "${owner}" "${phpbin}" "${project}/artisan" ${art_cmd} --no-interaction 2>&1 || true
            fi
        }

        tee_line "${C_GRAY}${SYM_RUN} Clearing all caches (w-clear equivalent)...${C_RESET}"
        for cmd_line in \
            "cache:clear" \
            "config:clear" \
            "route:clear" \
            "view:clear" \
            "event:clear" \
            "clear-compiled" \
            "optimize:clear" \
            "schedule:clear-cache" \
            "queue:clear"
        do
            result=$(run_artisan_cmd "${cmd_line}")
            tee_line "    artisan ${cmd_line}: ${result}"
        done

        # dump-autoload
        if [[ -f "${project}/composer.json" ]]; then
            tee_line "${C_GRAY}${SYM_RUN} composer dump-autoload${C_RESET}"
            cd "${project}"
            sudo -u "${owner}" composer dump-autoload --no-interaction 2>&1 | tee -a "${REPORT_FILE}" || true
            cd - > /dev/null
        fi

        tee_line "${C_GRAY}${SYM_RUN} Warming up caches (w-cache equivalent)...${C_RESET}"
        for cmd_line in \
            "config:cache" \
            "route:cache" \
            "view:cache" \
            "event:cache" \
            "optimize" \
            "queue:restart"
        do
            result=$(run_artisan_cmd "${cmd_line}")
            tee_line "    artisan ${cmd_line}: ${result}"
        done

        # Filament / icons if available
        for cmd_line in \
            "filament:cache-components" \
            "filament:optimize" \
            "icons:cache"
        do
            result=$(run_artisan_cmd "${cmd_line}" 2>/dev/null || true)
            [[ -n "${result}" ]] && tee_line "    artisan ${cmd_line}: ${result}"
        done

        tee_line "${C_GREEN}${SYM_OK} Artisan warm-up complete for ${project}${C_RESET}"
    done
else
    tee_line "${SYM_SKIP} Skipped (pass --artisan to run cache warm-up on detected projects)"
fi

# ==============================================================================
# SECTION 14 -- HTTP SIMULATION (optional, --test flag)
# ==============================================================================
section "HTTP SIMULATION"

if [[ "${RUN_TEST}" -eq 1 ]]; then
    if ! cmd_exists curl; then
        tee_line "${C_RED}${SYM_ERR} curl not found -- cannot run HTTP simulation${C_RESET}"
    else
        tee_line "${C_CYAN}${SYM_INFO} Target URL: ${TEST_URL}${C_RESET}"

        # Resolve domain to find local project path if URL is given
        domain_from_url=$(echo "${TEST_URL}" | sed -E 's|https?://([^/]+).*|\1|')
        local_project_path=$(find /home/*/web -maxdepth 2 -type d -name "${domain_from_url}" 2>/dev/null | head -n1 || true)
        if [[ -n "${local_project_path}" ]]; then
            tee_line "${C_GREEN}${SYM_OK} Local project path resolved: ${local_project_path}/public_html${C_RESET}"
        fi

        subsection "Single cold request (no cache headers)"
        safe_capture "curl cold request" curl -o /dev/null -s -w \
            "  http_code       : %{http_code}\n  time_namelookup : %{time_namelookup}s\n  time_connect    : %{time_connect}s\n  time_appconnect : %{time_appconnect}s\n  time_pretransfer: %{time_pretransfer}s\n  time_redirect   : %{time_redirect}s\n  time_starttransfer: %{time_starttransfer}s\n  time_total      : %{time_total}s\n  size_download   : %{size_download} bytes\n  speed_download  : %{speed_download} bytes/s\n" \
            --max-time 30 --connect-timeout 10 \
            -H "Cache-Control: no-cache, no-store" \
            -H "Pragma: no-cache" \
            -H "User-Agent: webkernel-perf-report/1.0" \
            "${TEST_URL}"

        subsection "Warm request (simulating browser with Accept headers)"
        safe_capture "curl warm request" curl -o /dev/null -s -w \
            "  http_code       : %{http_code}\n  time_total      : %{time_total}s\n  time_starttransfer: %{time_starttransfer}s\n" \
            --max-time 30 --connect-timeout 10 \
            -H "Accept: text/html,application/xhtml+xml" \
            -H "Accept-Encoding: gzip, deflate, br" \
            -H "User-Agent: webkernel-perf-report/1.0" \
            "${TEST_URL}"

        subsection "Response headers inspection"
        safe_capture "curl response headers" curl -I -s --max-time 30 --connect-timeout 10 "${TEST_URL}"

        subsection "Sequential requests (5x -- latency consistency check)"
        for i in 1 2 3 4 5; do
            t=$(curl -o /dev/null -s -w "%{time_total}" --max-time 30 --connect-timeout 10 \
                -H "User-Agent: webkernel-perf-report/1.0" \
                "${TEST_URL}" 2>/dev/null || echo "error")
            tee_line "  Request ${i}: ${t}s"
        done

        # ab / Apache Bench if available (light load test)
        if cmd_exists ab; then
            subsection "Apache Bench mini load test (20 requests, concurrency 5)"
            safe_capture "ab load test" ab -n 20 -c 5 -H "User-Agent: webkernel-perf-report/1.0" "${TEST_URL}"
        else
            tee_line "${SYM_SKIP} ab (Apache Bench) not found -- install apache2-utils for load testing"
        fi
    fi
else
    tee_line "${SYM_SKIP} Skipped (pass --test or --test=\"https://url\" to run HTTP simulation)"
fi

# ==============================================================================
# SECTION 15 -- OOM / KERNEL MESSAGES
# ==============================================================================
section "KERNEL / OOM MESSAGES"

subsection "Recent kernel messages (dmesg, last 100)"
safe_capture "dmesg tail" dmesg --time-format reltime 2>/dev/null | tail -n 100 || \
    safe_capture "dmesg tail fallback" dmesg | tail -n 100

subsection "OOM kill events"
safe_capture "OOM events" dmesg 2>/dev/null | grep -i 'oom\|killed process\|out of memory' | tail -n 30 || true

subsection "Journal errors (last 100 PHP/Nginx/MySQL entries)"
if cmd_exists journalctl; then
    safe_capture "journal nginx errors" journalctl -u nginx --no-pager -n 50 -p err..crit 2>/dev/null || true
    for ver in "${PHP_VERSIONS[@]}"; do
        safe_capture "journal php${ver}-fpm errors" journalctl -u "php${ver}-fpm" --no-pager -n 50 -p err..crit 2>/dev/null || true
    done
    safe_capture "journal mysql errors" journalctl -u mysql --no-pager -n 50 -p err..crit 2>/dev/null || \
        safe_capture "journal mariadb errors" journalctl -u mariadb --no-pager -n 50 -p err..crit 2>/dev/null || true
fi

# ==============================================================================
# SECTION 16 -- FILE DESCRIPTOR / LIMITS
# ==============================================================================
section "FILE DESCRIPTORS / SYSTEM LIMITS"

safe_capture "sysctl fs.file-max" sysctl fs.file-max
safe_capture "sysctl fs.file-nr" sysctl fs.file-nr
safe_capture "ulimit -a (root)" bash -c 'ulimit -a'
safe_capture "/proc/sys/net/core/somaxconn" cat /proc/sys/net/core/somaxconn
safe_capture "net.ipv4.tcp_fin_timeout" sysctl net.ipv4.tcp_fin_timeout
safe_capture "net.ipv4.tcp_tw_reuse" sysctl net.ipv4.tcp_tw_reuse
safe_capture "vm.swappiness" sysctl vm.swappiness
safe_capture "vm.overcommit_memory" sysctl vm.overcommit_memory

subsection "Swap usage"
safe_capture "swap (swapon -s)" swapon -s
safe_capture "swap in vmstat" vmstat 1 3

# ==============================================================================
# SECTION 17 -- AUTOMATED CHECKS (results collected, printed in summary below)
# ==============================================================================
section "RUNNING AUTOMATED CHECKS"

tee_line "${C_DIM}  Checks run here -- EXECUTIVE SUMMARY with fixes printed at end of terminal${C_RESET}"
tee_line "${C_DIM}  and prepended to the report file so it appears at the top.${C_RESET}"

# -- Load average --
cpu_cores=$(nproc 2>/dev/null || echo 1)
load_1min=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
load_int=${load_1min%.*}
if [[ "${load_int}" -ge "${cpu_cores}" ]]; then
    issue_critical "CPU overload: load=${load_1min} on ${cpu_cores} cores" \
        "Server CPU-bound -- requests queue behind saturated cores" \
        "ps -eo pid,user,cmd,%cpu --sort=-%cpu | head -20  (find runaway process)"
else
    issue_ok "Load average ${load_1min} OK for ${cpu_cores} cores"
fi

# -- Swap --
swap_used=$(free -m | awk '/Swap/{print $3}' 2>/dev/null || echo 0)
if [[ "${swap_used}" -gt 200 ]]; then
    issue_critical "Swap in use: ${swap_used}MB" \
        "Server is swapping to disk -- disk latency replaces RAM latency (10-1000x slower)" \
        "Reduce innodb_buffer_pool_size, lower pm.max_children, or add RAM"
elif [[ "${swap_used}" -gt 50 ]]; then
    issue_warning "Swap in use: ${swap_used}MB" \
        "Light swapping -- watch for growth under load" \
        "watch -n1 free -m"
else
    issue_ok "Swap: ${swap_used}MB"
fi

# -- OPcache per PHP version --
for ver in "${PHP_VERSIONS[@]}"; do
    phpbin="/usr/bin/php${ver}"
    [[ ! -x "${phpbin}" ]] && phpbin="/usr/bin/php"

    opcache_on=$("${phpbin}" -r 'echo ini_get("opcache.enable");' 2>/dev/null || echo "0")
    if [[ "${opcache_on}" != "1" ]]; then
        issue_critical "OPcache DISABLED for PHP ${ver}" \
            "Every request recompiles all PHP files from disk -- biggest single performance killer" \
            "echo 'opcache.enable=1' >> /etc/php/${ver}/fpm/php.ini && systemctl restart php${ver}-fpm"
    else
        opcache_mem=$("${phpbin}" -r '
            $s = @opcache_get_status(false);
            if ($s && isset($s["memory_usage"])) {
                $used = $s["memory_usage"]["used_memory"];
                $free = $s["memory_usage"]["free_memory"];
                $total = $used + $free;
                echo ($total > 0) ? round($used/$total*100) : -1;
            } else { echo -1; }
        ' 2>/dev/null || echo -1)
        if [[ "${opcache_mem}" -ge 90 ]]; then
            issue_critical "OPcache memory ${opcache_mem}% full (PHP ${ver})" \
                "Cache full = new files not cached = performance drops to zero-cache level" \
                "Increase opcache.memory_consumption to 256 or 512 in /etc/php/${ver}/fpm/php.ini"
        elif [[ "${opcache_mem}" -ge 75 ]]; then
            issue_warning "OPcache memory ${opcache_mem}% full (PHP ${ver})" \
                "Approaching full -- increase before it saturates under load" \
                "Increase opcache.memory_consumption in /etc/php/${ver}/fpm/php.ini"
        else
            issue_ok "OPcache enabled, ${opcache_mem}% used (PHP ${ver})"
        fi

        opcache_validate=$("${phpbin}" -r 'echo ini_get("opcache.validate_timestamps");' 2>/dev/null || echo "1")
        if [[ "${opcache_validate}" == "1" ]]; then
            issue_warning "opcache.validate_timestamps=1 (PHP ${ver})" \
                "PHP stats every file on each request to check for changes -- pure overhead in production" \
                "Set opcache.validate_timestamps=0 in /etc/php/${ver}/fpm/php.ini && systemctl restart php${ver}-fpm"
        fi

        realpath_size=$("${phpbin}" -r 'echo ini_get("realpath_cache_size");' 2>/dev/null || echo "")
        if [[ "${realpath_size}" == "16K" ]] || [[ "${realpath_size}" == "16384" ]]; then
            issue_warning "realpath_cache_size=16K (PHP ${ver})" \
                "Laravel has 500+ files -- tiny realpath cache forces repeated stat() on every request" \
                "Set realpath_cache_size=4096K realpath_cache_ttl=600 in /etc/php/${ver}/fpm/php.ini"
        fi
    fi
done

# -- PHP-FPM pool checks --
for ver in "${PHP_VERSIONS[@]}"; do
    pool_dir="/etc/php/${ver}/fpm/pool.d"
    [[ ! -d "${pool_dir}" ]] && continue
    for pool_file in "${pool_dir}"/*.conf; do
        [[ ! -f "${pool_file}" ]] && continue
        pool_name=$(basename "${pool_file}" .conf)
        max_children=$(grep -E '^pm\.max_children' "${pool_file}" | awk -F= '{print $2}' | tr -d ' ' || echo "")
        pm_mode=$(grep -E '^pm\s*=' "${pool_file}" | awk -F= '{print $2}' | tr -d ' ' || echo "")
        listen_val=$(grep -E '^listen\s*=' "${pool_file}" | awk -F= '{print $2}' | tr -d ' ' || echo "")

        if [[ -n "${max_children}" ]] && [[ "${max_children}" -lt 5 ]]; then
            issue_critical "PHP ${ver} [${pool_name}] pm.max_children=${max_children}" \
                "Only ${max_children} concurrent PHP workers -- requests queue instantly under any real load" \
                "Increase pm.max_children in ${pool_file} -- formula: floor((RAM_MB - 512) / avg_worker_MB)"
        elif [[ -n "${max_children}" ]]; then
            issue_ok "PHP ${ver} [${pool_name}] pm.max_children=${max_children}"
        fi

        if echo "${listen_val}" | grep -qE '^127\.[0-9]|:[0-9]+$'; then
            issue_warning "PHP ${ver} [${pool_name}] FPM on TCP: ${listen_val}" \
                "Unix socket is faster than TCP loopback for nginx->fpm on same machine" \
                "Set listen = /run/php/php${ver}-fpm-${pool_name}.sock in ${pool_file} and update nginx vhost upstream"
        elif [[ -n "${listen_val}" ]]; then
            issue_ok "PHP ${ver} [${pool_name}] uses unix socket"
        fi

        if [[ "${pm_mode}" == "ondemand" ]]; then
            issue_warning "PHP ${ver} [${pool_name}] pm=ondemand" \
                "Workers spawn per request = cold-start latency added on every burst" \
                "Switch to pm=dynamic pm.min_spare_servers=2 pm.max_spare_servers=4 in ${pool_file}"
        fi
    done
done

# -- Nginx vhost checks --
while IFS= read -r nginx_conf; do
    [[ ! -f "${nginx_conf}" ]] && continue
    domain_label=$(basename "${nginx_conf}")

    if grep -q 'fastcgi_cache ' "${nginx_conf}" 2>/dev/null; then
        issue_ok "FastCGI cache active in ${domain_label}"
    else
        issue_warning "No FastCGI cache in ${domain_label}" \
            "Every request -- even identical repeated ones -- hits PHP-FPM" \
            "v-add-fastcgi-cache USER DOMAIN 30m yes   (HestiaCP CLI, replace USER/DOMAIN)"
    fi

    if ! grep -qE 'gzip\s+on' "${nginx_conf}" 2>/dev/null; then
        issue_warning "gzip not enabled in ${domain_label}" \
            "Responses sent uncompressed -- high transfer time from EU/distant clients" \
            "Add to vhost: gzip on; gzip_types text/plain text/css application/json application/javascript text/xml;"
    fi

    fpm_pass=$(grep 'fastcgi_pass' "${nginx_conf}" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -n1 || echo "")
    if echo "${fpm_pass}" | grep -qE '^127\.[0-9]'; then
        issue_warning "Nginx ${domain_label} -> FPM via TCP (${fpm_pass})" \
            "Unnecessary TCP overhead on loopback -- use unix socket" \
            "Change fastcgi_pass to unix:/run/php/php<VER>-fpm-<POOL>.sock in vhost"
    fi

done < <(find /etc/nginx/conf.d /home/*/conf/web -maxdepth 2 -name '*.conf' 2>/dev/null | sort)

# -- Global nginx: sendfile on KVM --
for nginx_main in /etc/nginx/nginx.conf /etc/nginx/hestia.conf; do
    [[ ! -f "${nginx_main}" ]] && continue
    if grep -q 'sendfile on' "${nginx_main}" 2>/dev/null; then
        issue_warning "sendfile on in ${nginx_main} (Contabo KVM VPS)" \
            "sendfile is broken on many KVM hypervisors -- causes stalled/slow file transfers" \
            "Add 'sendfile off;' inside http{} block in ${nginx_main} then: systemctl reload nginx"
    fi
    worker_proc=$(grep -E '^\s*worker_processes' "${nginx_main}" 2>/dev/null | awk '{print $2}' | tr -d ';' | head -n1 || echo "")
    if [[ "${worker_proc}" == "1" ]]; then
        issue_warning "nginx worker_processes=1 in ${nginx_main}" \
            "Single nginx worker -- cannot parallelize across CPU cores" \
            "Set worker_processes auto; in ${nginx_main}"
    fi
done

# -- DNS resolution latency --
dns_resolvers=$(grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' || echo "")
for resolver in ${dns_resolvers}; do
    if cmd_exists dig; then
        dns_ms=$(dig @"${resolver}" google.com +time=2 +tries=1 2>/dev/null \
            | grep 'Query time' | awk '{print $4}' || echo "")
        if [[ -n "${dns_ms}" ]]; then
            if [[ "${dns_ms}" -gt 100 ]]; then
                issue_critical "DNS resolver ${resolver} latency: ${dns_ms}ms" \
                    "Every DB hostname / Redis / external HTTP call in PHP adds ${dns_ms}ms overhead" \
                    "Add 'nameserver 1.1.1.1' to /etc/resolv.conf  OR: apt install unbound"
            elif [[ "${dns_ms}" -gt 30 ]]; then
                issue_warning "DNS resolver ${resolver} latency: ${dns_ms}ms" \
                    "Moderate DNS latency accumulates across multiple service calls per request" \
                    "apt install unbound  (local caching resolver, <1ms after first lookup)"
            else
                issue_ok "DNS resolver ${resolver}: ${dns_ms}ms"
            fi
        fi
    fi
done

# -- DB_HOST / REDIS_HOST using hostname instead of IP --
for project in "${W_PROJECTS[@]}"; do
    env_file="${project}/.env"
    [[ ! -f "${env_file}" ]] && continue
    short_proj=$(basename "$(dirname "${project}")")

    db_host=$(grep -E '^DB_HOST=' "${env_file}" | cut -d= -f2 | tr -d '"' || echo "127.0.0.1")
    redis_host=$(grep -E '^REDIS_HOST=' "${env_file}" | cut -d= -f2 | tr -d '"' || echo "127.0.0.1")

    if [[ "${db_host}" != "127.0.0.1" ]] && [[ "${db_host}" != "localhost" ]]; then
        issue_warning "DB_HOST=${db_host} uses hostname [${short_proj}]" \
            "Hostname adds DNS lookup overhead on each reconnect" \
            "Set DB_HOST=127.0.0.1 in ${env_file}"
    else
        issue_ok "DB_HOST=${db_host} (loopback) [${short_proj}]"
    fi

    if [[ "${redis_host}" != "127.0.0.1" ]] && [[ "${redis_host}" != "localhost" ]]; then
        issue_warning "REDIS_HOST=${redis_host} uses hostname [${short_proj}]" \
            "DNS overhead on Redis connection" \
            "Set REDIS_HOST=127.0.0.1 in ${env_file}"
    fi

    # APP_ENV / DEBUG / drivers
    debug_val=$(grep -E '^APP_DEBUG=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
    env_val=$(grep -E '^APP_ENV=' "${env_file}" | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "")
    cache_drv=$(grep -E '^CACHE_DRIVER=' "${env_file}" | cut -d= -f2 | tr -d '"' || echo "file")
    session_drv=$(grep -E '^SESSION_DRIVER=' "${env_file}" | cut -d= -f2 | tr -d '"' || echo "file")
    queue_conn=$(grep -E '^QUEUE_CONNECTION=' "${env_file}" | cut -d= -f2 | tr -d '"' || echo "sync")

    [[ "${debug_val}" == "true" ]] && \
        issue_warning "APP_DEBUG=true [${short_proj}]" \
            "Debugbar + query logging + stack traces active -- adds 50-200ms per request" \
            "sed -i 's/APP_DEBUG=true/APP_DEBUG=false/' ${env_file} && php artisan config:cache"

    [[ "${env_val}" != "production" ]] && \
        issue_warning "APP_ENV=${env_val} [${short_proj}]" \
            "Non-production env skips Laravel optimizations and enables extra logging" \
            "sed -i 's/APP_ENV=${env_val}/APP_ENV=production/' ${env_file} && php artisan config:cache"

    [[ "${cache_drv}" == "file" ]] && \
        issue_critical "CACHE_DRIVER=file [${short_proj}]" \
            "Every cache read/write is a disk I/O operation -- 10-100x slower than Redis in-memory" \
            "Set CACHE_DRIVER=redis in ${env_file} (requires: apt install redis-server)"

    [[ "${session_drv}" == "file" ]] && \
        issue_warning "SESSION_DRIVER=file [${short_proj}]" \
            "File session locking causes request serialization under concurrent load" \
            "Set SESSION_DRIVER=redis in ${env_file}"

    [[ "${queue_conn}" == "sync" ]] && \
        issue_warning "QUEUE_CONNECTION=sync [${short_proj}]" \
            "Jobs (mail, events, notifications) execute inline during the HTTP request" \
            "Set QUEUE_CONNECTION=redis && php artisan queue:work --daemon"

    [[ ! -f "${project}/bootstrap/cache/config.php" ]] && \
        issue_critical "Config cache missing [${short_proj}]" \
            "Laravel parses and merges all config/*.php files on every single request" \
            "cd ${project} && composer w-cache"

    ls "${project}/bootstrap/cache/routes"*.php &>/dev/null 2>&1 || \
        issue_warning "Route cache missing [${short_proj}]" \
            "Route tree rebuilt from all route files on every request" \
            "cd ${project} && php artisan route:cache"
done

# -- Redis --
if ! cmd_exists redis-cli; then
    issue_critical "Redis not installed" \
        "No in-memory store available -- cache/session forced to file I/O" \
        "apt install redis-server && systemctl enable --now redis"
else
    redis_ping=$(redis-cli ping 2>/dev/null || echo "FAIL")
    if [[ "${redis_ping}" != "PONG" ]]; then
        issue_critical "Redis installed but not responding" \
            "CACHE_DRIVER=redis apps will error or fall back to file" \
            "systemctl start redis && systemctl enable redis"
    else
        issue_ok "Redis responding"
        redis_policy=$(redis-cli config get maxmemory-policy 2>/dev/null | tail -n1 || echo "")
        [[ "${redis_policy}" == "noeviction" ]] && \
            issue_warning "Redis maxmemory-policy=noeviction" \
                "Redis returns errors instead of evicting old keys when full" \
                "redis-cli config set maxmemory-policy allkeys-lru"
    fi
fi

# -- MySQL slow query log --
if cmd_exists mysql; then
    slow_log_enabled=$(mysql -e "SHOW VARIABLES LIKE 'slow_query_log';" 2>/dev/null \
        | awk '/slow_query_log/{print $2}' || echo "")
    long_query_time=$(mysql -e "SHOW VARIABLES LIKE 'long_query_time';" 2>/dev/null \
        | awk '/long_query_time/{print $2}' || echo "")
    if [[ "${slow_log_enabled}" == "OFF" ]]; then
        issue_warning "MySQL slow query log OFF" \
            "Cannot identify slow queries contributing to 4-8s response times" \
            "mysql -e \"SET GLOBAL slow_query_log=ON; SET GLOBAL long_query_time=1;\""
    else
        issue_ok "MySQL slow query log ON (threshold=${long_query_time}s)"
    fi
fi

# -- TCP keepalive --
tcp_keepalive=$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo 7200)
if [[ "${tcp_keepalive}" -gt 600 ]]; then
    issue_warning "net.ipv4.tcp_keepalive_time=${tcp_keepalive}s" \
        "Dead connections held open for ${tcp_keepalive}s -- ties up FPM workers" \
        "echo 'net.ipv4.tcp_keepalive_time=60' >> /etc/sysctl.conf && sysctl -p"
fi

# -- Disk I/O scheduler (KVM/Contabo) --
for block_dev in vda sda; do
    sched_file="/sys/block/${block_dev}/queue/scheduler"
    [[ ! -f "${sched_file}" ]] && continue
    disk_scheduler=$(cat "${sched_file}" 2>/dev/null || echo "")
    if echo "${disk_scheduler}" | grep -q '\[cfq\]'; then
        issue_warning "Disk I/O scheduler: CFQ on /dev/${block_dev}" \
            "CFQ designed for physical drives -- mq-deadline is faster on KVM VPS" \
            "echo mq-deadline > /sys/block/${block_dev}/queue/scheduler"
    else
        issue_ok "Disk scheduler /dev/${block_dev}: ${disk_scheduler}"
    fi
done

# ==============================================================================
# ==============================================================================
# FOOTER (written to DETAIL_FILE before the final merge)
# ==============================================================================
END_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
{
    echo ""
    echo "=============================================================="
    echo "  END OF DETAIL REPORT"
    echo "  Finished : ${END_TIMESTAMP}"
    echo "=============================================================="
} >> "${DETAIL_FILE}"

# ==============================================================================
# EXECUTIVE SUMMARY -- built from collected issues, printed to terminal,
# then prepended to DETAIL_FILE to produce the final REPORT_FILE
# ==============================================================================
SUMMARY_FILE=$(mktemp /tmp/w-perf-summary.XXXXXX)

{
    printf '%s\n' "=============================================================="
    printf '%s\n' "  EXECUTIVE SUMMARY -- WHAT IS WRONG AND WHAT TO DO"
    printf '  Generated : %s\n' "${TIMESTAMP}"
    printf '  Host      : %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf '%s\n' "=============================================================="
    printf '\n'

    if [[ ${#ISSUES_CRITICAL[@]} -gt 0 ]]; then
        printf '%s\n' "  CRITICAL -- fix these first (most likely root causes):"
        printf '%s\n' "  ------------------------------------------------------"
        for entry in "${ISSUES_CRITICAL[@]}"; do
            IFS='|' read -r lbl detail fix <<< "${entry}"
            printf '  [X] %s\n'       "${lbl}"
            printf '      WHY : %s\n' "${detail}"
            printf '      FIX : %s\n' "${fix}"
            printf '\n'
        done
    else
        printf '%s\n' "  No critical issues detected."
        printf '\n'
    fi

    if [[ ${#ISSUES_WARNING[@]} -gt 0 ]]; then
        printf '%s\n' "  WARNINGS -- address after criticals:"
        printf '%s\n' "  ------------------------------------"
        for entry in "${ISSUES_WARNING[@]}"; do
            IFS='|' read -r lbl detail fix <<< "${entry}"
            printf '  [!] %s\n'       "${lbl}"
            printf '      WHY : %s\n' "${detail}"
            printf '      FIX : %s\n' "${fix}"
            printf '\n'
        done
    fi

    if [[ ${#ISSUES_OK[@]} -gt 0 ]]; then
        printf '%s\n' "  OK (passing checks):"
        printf '%s\n' "  --------------------"
        for entry in "${ISSUES_OK[@]}"; do
            printf '  [OK] %s\n' "${entry}"
        done
        printf '\n'
    fi

    printf '%s\n' "=============================================================="
    printf '  %d critical  /  %d warnings  /  %d OK\n' \
        "${#ISSUES_CRITICAL[@]}" "${#ISSUES_WARNING[@]}" "${#ISSUES_OK[@]}"
    printf '  Full detail below this summary.\n'
    printf '%s\n' "=============================================================="
    printf '\n'
} > "${SUMMARY_FILE}"

# Print summary to terminal
cat "${SUMMARY_FILE}"

# Assemble final report: SUMMARY on top, DETAIL below
cat "${SUMMARY_FILE}" "${DETAIL_FILE}" > "${REPORT_FILE}"

# Cleanup temp files
rm -f "${SUMMARY_FILE}" "${DETAIL_FILE}"

echo ""
echo "[OK] Report written to: ${REPORT_FILE}"
