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
#  Webkernel OS — PHP Server Optimizer
#  https://github.com/webkernelphp/server-optimizer
#
#  Target  : Debian family (Debian 11/12, Ubuntu 20.04+)
#  License : MIT
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Terminal colors + symbols
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_RED="\033[1;31m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_BLUE="\033[1;34m"
    C_CYAN="\033[1;36m"
    C_WHITE="\033[1;37m"
    C_GRAY="\033[0;37m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN=""
    C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE="" C_GRAY=""
fi

SYM_OK="✔"
SYM_WARN="⚠"
SYM_ERR="✖"
SYM_INFO="›"
SYM_SKIP="⊘"
SYM_RUN="⟳"

# ------------------------------------------------------------------------------
# Defaults (overridden by CLI flags or --mode)
# ------------------------------------------------------------------------------
OPT_SWAP=""                  # e.g. 64G  (empty = skip)
OPT_SESSION_TMPFS="512M"
OPT_PHP_VERSIONS="all"       # all | 8.1,8.2,8.3 | none
OPT_COMPOSER="global"        # global | users=user1,user2 | skip
OPT_OPCACHE=true
OPT_FPM=true
OPT_KERNEL=true
OPT_MODE=""                  # numerimondes-webkernel | custom
OPT_DRY_RUN=false
OPT_FORCE=false

LOG_FILE="/var/log/webkernel-optimizer.log"
COMPOSER_PHAR="/usr/local/share/composer/composer.phar"
COMPOSER_BIN="/usr/local/bin/composer"
SYSCTL_CONF="/etc/sysctl.d/99-webkernel.conf"
SESSION_TMPFS_PATH="/run/php/sessions"
SCRIPT_START=$(date +%s)

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
_ts()   { date -u +"%H:%M:%S"; }
_tlog() { echo "[${C_DIM}$(_ts)${C_RESET}] $*" | tee -a "$LOG_FILE"; }

log()  { _tlog "  ${C_BLUE}${SYM_INFO}${C_RESET}  $*"; }
ok()   { _tlog "  ${C_GREEN}${SYM_OK}${C_RESET}  $*"; }
warn() { _tlog "  ${C_YELLOW}${SYM_WARN}${C_RESET}  $*"; }
skip() { _tlog "  ${C_GRAY}${SYM_SKIP}${C_RESET}  ${C_DIM}$*${C_RESET}"; }
run()  { _tlog "  ${C_CYAN}${SYM_RUN}${C_RESET}  $*"; }
die()  {
    echo ""
    _tlog "  ${C_RED}${SYM_ERR} FATAL${C_RESET}  $*"
    echo ""
    exit 1
}

section() {
    echo ""
    echo -e "  ${C_BOLD}${C_WHITE}▐ $* ${C_RESET}"
    echo -e "  ${C_DIM}$(printf '─%.0s' {1..54})${C_RESET}"
}

elapsed() {
    local now; now=$(date +%s)
    local diff=$(( now - SCRIPT_START ))
    printf "%dm%02ds" $(( diff / 60 )) $(( diff % 60 ))
}

estimate() {
    # $1 = label  $2 = estimated seconds
    log "${C_DIM}$1${C_RESET} ${C_GRAY}~${2}s estimated${C_RESET}"
}

progress_bar() {
    # progress_bar "label" current total
    local label="$1" cur="$2" tot="$3"
    local width=40
    local filled=$(( cur * width / tot ))
    local empty=$(( width - filled ))
    local bar
    bar="${C_GREEN}$(printf '█%.0s' $(seq 1 $filled))${C_RESET}${C_DIM}$(printf '░%.0s' $(seq 1 $empty))${C_RESET}"
    printf "\r  %b  %-30s [%b] %3d%%" \
        "${C_CYAN}${SYM_RUN}${C_RESET}" \
        "$label" \
        "$bar" \
        $(( cur * 100 / tot ))
}

progress_done() { echo ""; }

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
cat << EOF

$(echo -e "${C_BOLD}${C_WHITE}Webkernel OS — PHP Server Optimizer${C_RESET}")
$(echo -e "${C_DIM}https://github.com/webkernelphp/server-optimizer${C_RESET}")

$(echo -e "${C_BOLD}Usage:${C_RESET}")
  sudo bash server-optimizer.sh [OPTIONS]

$(echo -e "${C_BOLD}Modes:${C_RESET}")
  --mode=numerimondes-webkernel   Apply Numerimondes production defaults
                                   (swap=64G, all PHP versions, composer global,
                                    opcache+fpm+kernel tuning)

$(echo -e "${C_BOLD}Options:${C_RESET}")
  --swap=SIZE                     Add swap file (e.g. 4G, 16G, 64G)
                                   Skipped if not enough free disk space
  --session-tmpfs=SIZE            Sessions tmpfs size (default: 512M)
  --php-versions=SPEC             PHP versions to tune:
                                     all         — all installed versions (default)
                                     8.1,8.2     — specific versions only
                                     none        — skip PHP tuning
  --composer=MODE                 Composer installation mode:
                                     global                    — /usr/local/bin/composer
                                     users=user1,user2         — per-user ~/bin/composer
                                     skip                      — do not install
  --no-opcache                    Skip OPcache configuration
  --no-fpm                        Skip PHP-FPM pool tuning
  --no-kernel                     Skip sysctl / kernel tuning
  --log=PATH                      Log file path (default: /var/log/webkernel-optimizer.log)
  --dry-run                       Show what would be done, make no changes
  --force                         Skip confirmation prompts
  -h, --help                      Show this help

$(echo -e "${C_BOLD}Examples:${C_RESET}")
  sudo bash server-optimizer.sh --mode=numerimondes-webkernel
  sudo bash server-optimizer.sh --swap=8G --php-versions=8.2,8.3 --composer=global
  sudo bash server-optimizer.sh --swap=32G --composer=users=alice,bob --no-kernel
  sudo bash server-optimizer.sh --dry-run --mode=numerimondes-webkernel

EOF
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --mode=*)             OPT_MODE="${arg#*=}" ;;
            --swap=*)             OPT_SWAP="${arg#*=}" ;;
            --session-tmpfs=*)    OPT_SESSION_TMPFS="${arg#*=}" ;;
            --php-versions=*)     OPT_PHP_VERSIONS="${arg#*=}" ;;
            --composer=*)         OPT_COMPOSER="${arg#*=}" ;;
            --no-opcache)         OPT_OPCACHE=false ;;
            --no-fpm)             OPT_FPM=false ;;
            --no-kernel)          OPT_KERNEL=false ;;
            --log=*)              LOG_FILE="${arg#*=}" ;;
            --dry-run)            OPT_DRY_RUN=true ;;
            --force)              OPT_FORCE=true ;;
            -h|--help)            usage; exit 0 ;;
            *) die "Unknown option: $arg  (use --help)" ;;
        esac
    done

    # Apply mode presets (can be overridden by explicit flags after --mode)
    if [[ "$OPT_MODE" == "numerimondes-webkernel" ]]; then
        [[ -z "$OPT_SWAP" ]]               && OPT_SWAP="64G"
        [[ "$OPT_PHP_VERSIONS" == "all" ]] && OPT_PHP_VERSIONS="all"
        [[ "$OPT_COMPOSER" == "global" ]]  && OPT_COMPOSER="global"
        OPT_OPCACHE=true
        OPT_FPM=true
        OPT_KERNEL=true
    fi
}

# ------------------------------------------------------------------------------
# Guards
# ------------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "Must run as root:  sudo bash $0 --help"
}

require_debian() {
    [[ -f /etc/debian_version ]] || die "This script targets Debian/Ubuntu only"
}

dry() {
    # Wrap a command: print it in dry-run, execute otherwise
    if [[ "$OPT_DRY_RUN" == true ]]; then
        log "${C_YELLOW}[DRY-RUN]${C_RESET} would run: ${C_DIM}$*${C_RESET}"
        return 0
    fi
    "$@"
}

confirm() {
    [[ "$OPT_FORCE" == true ]] && return 0
    [[ "$OPT_DRY_RUN" == true ]] && return 0
    echo ""
    echo -e "  ${C_YELLOW}${SYM_WARN}  $1${C_RESET}"
    echo -ne "  ${C_BOLD}Continue? [y/N]${C_RESET} "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
}

# ------------------------------------------------------------------------------
# Detect installed PHP versions
# ------------------------------------------------------------------------------
detect_php_versions() {
    if [[ "$OPT_PHP_VERSIONS" == "none" ]]; then
        ACTIVE_PHP_VERSIONS=()
        return
    fi

    if [[ "$OPT_PHP_VERSIONS" == "all" ]]; then
        mapfile -t ACTIVE_PHP_VERSIONS < <(
            find /etc/php -maxdepth 1 -mindepth 1 -type d \
            | grep -oP '\d+\.\d+' | sort -V
        )
    else
        IFS=',' read -ra ACTIVE_PHP_VERSIONS <<< "$OPT_PHP_VERSIONS"
    fi

    if [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]]; then
        warn "No PHP versions found under /etc/php/"
    else
        log "Detected PHP versions: ${C_CYAN}${ACTIVE_PHP_VERSIONS[*]}${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# Plan summary before execution
# ------------------------------------------------------------------------------
print_plan() {
    echo ""
    echo -e "  ${C_BOLD}${C_WHITE}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}║        Webkernel Server Optimizer            ║${C_RESET}"
    echo -e "  ${C_BOLD}${C_WHITE}╚══════════════════════════════════════════════╝${C_RESET}"
    echo ""
    [[ -n "$OPT_MODE" ]] && \
        echo -e "  ${C_CYAN}Mode${C_RESET}            ${C_BOLD}$OPT_MODE${C_RESET}"
    echo -e "  ${C_CYAN}Swap${C_RESET}            ${OPT_SWAP:-${C_DIM}skip${C_RESET}}"
    echo -e "  ${C_CYAN}Session tmpfs${C_RESET}   $OPT_SESSION_TMPFS"
    echo -e "  ${C_CYAN}PHP versions${C_RESET}    $OPT_PHP_VERSIONS"
    echo -e "  ${C_CYAN}Composer${C_RESET}        $OPT_COMPOSER"
    echo -e "  ${C_CYAN}OPcache${C_RESET}         $OPT_OPCACHE"
    echo -e "  ${C_CYAN}FPM tuning${C_RESET}      $OPT_FPM"
    echo -e "  ${C_CYAN}Kernel tuning${C_RESET}   $OPT_KERNEL"
    echo -e "  ${C_CYAN}Log${C_RESET}             $LOG_FILE"
    [[ "$OPT_DRY_RUN" == true ]] && \
        echo -e "\n  ${C_YELLOW}${SYM_WARN}  DRY-RUN MODE — no changes will be made${C_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# 1. SWAP
# ------------------------------------------------------------------------------
setup_swap() {
    [[ -z "$OPT_SWAP" ]] && { skip "Swap — skipped (not requested)"; return; }

    section "SWAP"

    local swap_file="/swapfile"
    local swap_size="$OPT_SWAP"

    # Convert human size to bytes for disk check
    local size_num; size_num=$(echo "$swap_size" | grep -oP '^\d+')
    local size_unit; size_unit=$(echo "$swap_size" | grep -oP '[A-Za-z]+$' | tr '[:lower:]' '[:upper:]')
    local size_bytes
    case "$size_unit" in
        G|GB|GIB) size_bytes=$(( size_num * 1024 * 1024 * 1024 )) ;;
        M|MB|MIB) size_bytes=$(( size_num * 1024 * 1024 )) ;;
        T|TB|TIB) size_bytes=$(( size_num * 1024 * 1024 * 1024 * 1024 )) ;;
        *) die "Unrecognised swap size unit: $size_unit (use G, M, T)" ;;
    esac

    # Check free disk space — require at least swap_size + 2G safety margin
    local free_bytes; free_bytes=$(df --output=avail -B1 / | tail -1)
    local safety=$(( 2 * 1024 * 1024 * 1024 ))
    local required=$(( size_bytes + safety ))

    log "Disk free: ${C_CYAN}$(( free_bytes / 1024 / 1024 / 1024 ))G${C_RESET}  — required: ${C_CYAN}$(( required / 1024 / 1024 / 1024 ))G${C_RESET} (swap + 2G margin)"

    if (( free_bytes < required )); then
        warn "Not enough free disk space for ${swap_size} swap + 2G margin"
        warn "Available: $(( free_bytes / 1024 / 1024 / 1024 ))G — skipping swap creation"
        return
    fi

    if swapon --show 2>/dev/null | grep -q "$swap_file"; then
        skip "Swap already active on $swap_file"
        return
    fi

    if [[ -f "$swap_file" ]]; then
        warn "$swap_file exists but is not active — re-formatting"
    else
        estimate "Allocating ${swap_size} swap file" "$(( size_num * 1 ))"
        run "fallocate -l ${swap_size} $swap_file"
        dry fallocate -l "$swap_size" "$swap_file"
    fi

    dry chmod 600 "$swap_file"

    run "Formatting swap..."
    dry mkswap "$swap_file"

    run "Activating swap..."
    dry swapon "$swap_file"

    if ! grep -q "$swap_file" /etc/fstab; then
        dry bash -c "echo '$swap_file none swap sw 0 0' >> /etc/fstab"
        dry systemctl daemon-reload
        ok "fstab updated + daemon reloaded"
    fi

    if [[ "$OPT_DRY_RUN" == false ]]; then
        ok "Swap active: $(swapon --show --noheadings | awk '{print $1, $3}')"
    fi
}

# ------------------------------------------------------------------------------
# 2. SESSION TMPFS
# ------------------------------------------------------------------------------
setup_session_tmpfs() {
    section "SESSION TMPFS"

    local path="$SESSION_TMPFS_PATH"
    local size="$OPT_SESSION_TMPFS"

    dry mkdir -p "$path"

    if mount 2>/dev/null | grep -q "$path"; then
        skip "tmpfs already mounted on $path"
    else
        estimate "Mounting tmpfs ${size} on $path" "1"
        run "Mounting tmpfs ${size} → $path"
        dry mount -t tmpfs -o "size=${size},mode=1777" tmpfs "$path"
        ok "tmpfs mounted (${size} in RAM)"
    fi

    if ! grep -q "$path" /etc/fstab 2>/dev/null; then
        dry bash -c "echo 'tmpfs $path tmpfs size=${size},mode=1777 0 0' >> /etc/fstab"
        dry systemctl daemon-reload
        ok "fstab updated + daemon reloaded"
    else
        skip "fstab entry already present"
    fi
}

# ------------------------------------------------------------------------------
# 3. COMPOSER
# ------------------------------------------------------------------------------
setup_composer() {
    [[ "$OPT_COMPOSER" == "skip" ]] && { skip "Composer — skipped"; return; }

    section "COMPOSER"

    dry mkdir -p /usr/local/share/composer

    if [[ -f "$COMPOSER_PHAR" && "$OPT_FORCE" == false ]]; then
        skip "composer.phar already exists — skipping download (use --force to reinstall)"
    else
        estimate "Downloading composer installer" "3"
        run "Fetching installer from getcomposer.org..."
        dry curl --silent --show-error --fail \
            -o /tmp/composer-setup.php \
            https://getcomposer.org/installer
        ok "Installer downloaded"

        run "Fetching installer signature..."
        if [[ "$OPT_DRY_RUN" == false ]]; then
            EXPECTED_SIG=$(curl --silent --show-error --fail https://composer.github.io/installer.sig)
            ACTUAL_SIG=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
            [[ "$EXPECTED_SIG" == "$ACTUAL_SIG" ]] || die "Composer installer signature mismatch"
        fi
        ok "Signature verified"

        estimate "Installing composer.phar" "3"
        run "Running installer..."
        dry php /tmp/composer-setup.php \
            --quiet \
            --install-dir=/usr/local/share/composer \
            --filename=composer.phar
        dry rm -f /tmp/composer-setup.php
        dry chmod 644 "$COMPOSER_PHAR"
        ok "composer.phar installed"
    fi

    # --- Global wrapper ---
    if [[ "$OPT_COMPOSER" == "global" ]]; then
        run "Writing universal wrapper → $COMPOSER_BIN"
        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat > "$COMPOSER_BIN" << 'WRAPPER'
#!/usr/bin/env bash
# Webkernel — Composer universal wrapper
# Override PHP: PHP_BIN=/usr/bin/php8.1 composer install
PHAR="/usr/local/share/composer/composer.phar"
if   [[ -n "${PHP_BIN:-}" ]];        then PHP="$PHP_BIN"
elif command -v php &>/dev/null;      then PHP=$(command -v php)
else echo "ERROR: No PHP binary found in PATH" >&2; exit 1
fi
exec "$PHP" "$PHAR" "$@"
WRAPPER
            chmod +x "$COMPOSER_BIN"
        fi
        ok "Global wrapper → $COMPOSER_BIN"
        log "Override PHP:  ${C_CYAN}PHP_BIN=/usr/bin/php8.3 composer install${C_RESET}"

    # --- Per-user wrapper ---
    elif [[ "$OPT_COMPOSER" == users=* ]]; then
        local user_list="${OPT_COMPOSER#users=}"
        IFS=',' read -ra TARGET_USERS <<< "$user_list"

        for u in "${TARGET_USERS[@]}"; do
            local home_bin
            home_bin=$(eval echo "~${u}/bin")
            run "Installing composer wrapper for user ${C_CYAN}${u}${C_RESET} → ${home_bin}/composer"
            if [[ "$OPT_DRY_RUN" == false ]]; then
                mkdir -p "$home_bin"
                cat > "${home_bin}/composer" << WRAPPER
#!/usr/bin/env bash
# Webkernel — Composer wrapper for ${u}
PHAR="$COMPOSER_PHAR"
PHP=\${PHP_BIN:-\$(command -v php)}
exec "\$PHP" "\$PHAR" "\$@"
WRAPPER
                chmod +x "${home_bin}/composer"
                chown "${u}:${u}" "${home_bin}/composer" 2>/dev/null || true
            fi
            ok "Wrapper installed for ${u}"
        done
    fi
}

# ------------------------------------------------------------------------------
# 4. OPCACHE
# ------------------------------------------------------------------------------
configure_opcache() {
    [[ "$OPT_OPCACHE" == false ]] && { skip "OPcache — skipped (--no-opcache)"; return; }
    [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]] && { skip "OPcache — no PHP versions to configure"; return; }

    section "OPCACHE"

    local total=${#ACTIVE_PHP_VERSIONS[@]}
    local i=0

    for VERSION in "${ACTIVE_PHP_VERSIONS[@]}"; do
        (( i++ )) || true
        progress_bar "OPcache PHP ${VERSION}" "$i" "$total"

        local conf_file="/etc/php/${VERSION}/mods-available/opcache.ini"
        [[ -f "$conf_file" ]] || { progress_done; warn "No opcache.ini for PHP ${VERSION} — skipping"; continue; }

        dry cp "$conf_file" "${conf_file}.bak.$(date +%s)" 2>/dev/null || true

        local major; major=$(echo "$VERSION" | cut -d. -f1)
        local jit_lines=""
        (( major >= 8 )) && jit_lines="opcache.jit_buffer_size=128M
opcache.jit=tracing"

        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat > "$conf_file" << INIEOF
; Webkernel — OPcache production config — PHP ${VERSION}
; Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
zend_extension=opcache.so

opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.max_wasted_percentage=10
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.fast_shutdown=1
opcache.save_comments=1
opcache.consistency_checks=0
opcache.huge_code_pages=1
${jit_lines}
INIEOF
        fi

        if systemctl is-active --quiet "php${VERSION}-fpm" 2>/dev/null; then
            dry systemctl reload "php${VERSION}-fpm"
        fi
    done

    progress_done
    ok "OPcache configured for: ${C_CYAN}${ACTIVE_PHP_VERSIONS[*]}${C_RESET}"
}

# ------------------------------------------------------------------------------
# 5. PHP-FPM POOLS
# ------------------------------------------------------------------------------
tune_fpm_pools() {
    [[ "$OPT_FPM" == false ]] && { skip "PHP-FPM — skipped (--no-fpm)"; return; }
    [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]] && { skip "PHP-FPM — no PHP versions to configure"; return; }

    section "PHP-FPM POOLS"

    local ram_mb; ram_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    local avg_mb=60
    local max_children=$(( ram_mb / avg_mb ))
    (( max_children < 5 )) && max_children=5

    log "Available RAM: ${C_CYAN}${ram_mb}M${C_RESET}  — pm.max_children: ${C_CYAN}${max_children}${C_RESET} (${ram_mb}M ÷ ${avg_mb}M/worker)"

    local total=${#ACTIVE_PHP_VERSIONS[@]}
    local i=0

    for VERSION in "${ACTIVE_PHP_VERSIONS[@]}"; do
        (( i++ )) || true
        progress_bar "FPM pool PHP ${VERSION}" "$i" "$total"

        local pool_conf="/etc/php/${VERSION}/fpm/pool.d/www.conf"
        [[ -f "$pool_conf" ]] || { progress_done; warn "No pool.d/www.conf for PHP ${VERSION} — skipping"; continue; }

        dry cp "$pool_conf" "${pool_conf}.bak.$(date +%s)"

        if [[ "$OPT_DRY_RUN" == false ]]; then
            sed -i 's/^pm = .*/pm = dynamic/'                                             "$pool_conf"
            sed -i "s/^pm\.max_children = .*/pm.max_children = ${max_children}/"         "$pool_conf"
            sed -i 's/^pm\.start_servers = .*/pm.start_servers = 10/'                    "$pool_conf"
            sed -i 's/^pm\.min_spare_servers = .*/pm.min_spare_servers = 5/'             "$pool_conf"
            sed -i 's/^pm\.max_spare_servers = .*/pm.max_spare_servers = 20/'            "$pool_conf"

            if grep -q '^;pm\.max_requests' "$pool_conf"; then
                sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 500/' "$pool_conf"
            elif grep -q '^pm\.max_requests' "$pool_conf"; then
                sed -i 's/^pm\.max_requests = .*/pm.max_requests = 500/'  "$pool_conf"
            else
                echo "pm.max_requests = 500" >> "$pool_conf"
            fi

            if grep -q 'session\.save_path' "$pool_conf"; then
                sed -i "s|.*session\.save_path.*|php_value[session.save_path] = ${SESSION_TMPFS_PATH}|" "$pool_conf"
            else
                echo "php_value[session.save_path] = ${SESSION_TMPFS_PATH}" >> "$pool_conf"
            fi
        fi

        if systemctl is-active --quiet "php${VERSION}-fpm" 2>/dev/null; then
            dry systemctl reload "php${VERSION}-fpm"
        fi
    done

    progress_done
    ok "FPM pools tuned for: ${C_CYAN}${ACTIVE_PHP_VERSIONS[*]}${C_RESET}"
}

# ------------------------------------------------------------------------------
# 6. KERNEL / SYSCTL
# ------------------------------------------------------------------------------
tune_kernel() {
    [[ "$OPT_KERNEL" == false ]] && { skip "Kernel tuning — skipped (--no-kernel)"; return; }

    section "KERNEL / SYSCTL"

    run "Writing $SYSCTL_CONF..."

    if [[ "$OPT_DRY_RUN" == false ]]; then
        cat > "$SYSCTL_CONF" << 'EOF'
# =============================================================================
# Webkernel OS — Kernel tuning for PHP application server
# =============================================================================

# --- Memory pressure ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# --- Huge pages (OPcache benefit) ---
vm.nr_hugepages = 128

# --- TCP / concurrent connections ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3

# --- File descriptors ---
fs.file-max = 2097152
fs.nr_open = 2097152
EOF
        sysctl --system > /dev/null 2>&1
    fi
    ok "sysctl applied → $SYSCTL_CONF"

    run "Updating /etc/security/limits.conf..."
    if ! grep -q "webkernel" /etc/security/limits.conf 2>/dev/null; then
        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat >> /etc/security/limits.conf << 'EOF'

# Webkernel — PHP server open file limits
*    soft    nofile    65535
*    hard    nofile    65535
root soft    nofile    65535
root hard    nofile    65535
EOF
        fi
        ok "limits.conf updated"
    else
        skip "limits.conf already patched"
    fi
}

# ------------------------------------------------------------------------------
# 7. FINAL REPORT
# ------------------------------------------------------------------------------
print_report() {
    section "VERIFICATION REPORT"

    echo ""
    echo -e "  ${C_BOLD}Memory${C_RESET}"
    free -h | sed 's/^/    /'

    echo ""
    echo -e "  ${C_BOLD}Swap${C_RESET}"
    swapon --show 2>/dev/null | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo -e "  ${C_BOLD}Session tmpfs${C_RESET}"
    mount 2>/dev/null | grep "php/sessions" | sed 's/^/    /' || echo "    (none)"

    echo ""
    echo -e "  ${C_BOLD}OPcache per PHP version${C_RESET}"
    for v in /usr/bin/php[0-9]*.[0-9]*; do
        [[ -x "$v" ]] || continue
        VER=$("$v" -r 'echo PHP_VERSION;' 2>/dev/null) || continue
        STATUS=$("$v" -r 'echo ini_get("opcache.enable") ? "ON" : "OFF";' 2>/dev/null || echo "?")
        JIT=$("$v" -r 'echo ini_get("opcache.jit_buffer_size") ?: "-";' 2>/dev/null || echo "-")
        COLOR=$([[ "$STATUS" == "ON" ]] && echo "$C_GREEN" || echo "$C_YELLOW")
        echo -e "    PHP ${VER}  opcache=${COLOR}${STATUS}${C_RESET}  jit_buffer=${JIT}"
    done

    echo ""
    echo -e "  ${C_BOLD}Composer${C_RESET}"
    if command -v composer &>/dev/null; then
        echo "    $(composer --version 2>/dev/null || echo 'installed')"
    else
        echo "    not in PATH"
    fi

    echo ""
    echo -e "  ${C_BOLD}PHP-FPM services${C_RESET}"
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        color=$([[ "$state" == "active" ]] && echo "$C_GREEN" || echo "$C_YELLOW")
        echo -e "    ${color}${svc}${C_RESET}  ${C_DIM}${state}${C_RESET}"
    done < <(systemctl list-units --type=service --state=active --no-legend 2>/dev/null \
             | grep -oP 'php\S+-fpm\.service' || true)

    local total_elapsed; total_elapsed=$(elapsed)
    echo ""
    echo -e "  ${C_DIM}Log file : $LOG_FILE${C_RESET}"
    echo -e "  ${C_DIM}Duration : ${total_elapsed}${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}${C_GREEN}${SYM_OK}  Optimization complete.${C_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# Entrypoint
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"

    require_root
    require_debian

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    print_plan
    detect_php_versions

    [[ "$OPT_FORCE" == false && "$OPT_DRY_RUN" == false ]] && \
        confirm "This will modify system configuration on $(hostname)."

    setup_swap
    setup_session_tmpfs
    setup_composer
    configure_opcache
    tune_fpm_pools
    tune_kernel
    print_report
}

main "$@"
