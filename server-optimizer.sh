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
#  Target  : Webkernel OF (Debian family deb12/13, deb20.04+)
#  License : EPL-2.0 license
# ==============================================================================

set -euo pipefail
# NOTE: IFS is intentionally left at default (space/tab/newline).
# Changing it globally breaks "${array[*]}" joins with spaces.

# ------------------------------------------------------------------------------
# Terminal colors
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
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
# Quotes -- shown randomly during long operations
# ------------------------------------------------------------------------------
QUOTES=(
    "Premature optimization is the root of all evil. -- Knuth"
    "Make it work, make it right, make it fast. -- Beck"
    "The best performance improvement is the transition from nonworking to working. -- Smith"
    "Any fool can write code a computer understands. Good programmers write code humans understand. -- Fowler"
    "It works on my machine. -- Every developer, ever"
    "rm -rf / is not a valid optimization strategy."
    "Swap is not slow RAM. It is fast storage. Plan accordingly."
    "OPcache: because parsing PHP on every request is for the brave."
    "A server without monitoring is a server without a future."
    "Measure twice, fallocate once."
)

random_quote() {
    local idx=$(( RANDOM % ${#QUOTES[@]} ))
    printf "\n%b\n" "  ${C_DIM}  \"${QUOTES[$idx]}\"${C_RESET}"
}

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
OPT_SWAP=""
OPT_SESSION_TMPFS="512M"
OPT_PHP_VERSIONS="all"
OPT_COMPOSER="global"
OPT_DEFAULT_PHP=""
OPT_OPCACHE=true
OPT_FPM=true
OPT_KERNEL=true
OPT_MODE=""
OPT_DRY_RUN=false
OPT_FORCE=false

LOG_FILE="/var/log/webkernel-optimizer.log"
COMPOSER_PHAR="/usr/local/share/composer/composer.phar"
COMPOSER_BIN="/usr/local/bin/composer"
SYSCTL_CONF="/etc/sysctl.d/99-webkernel.conf"
SESSION_TMPFS_PATH="/run/php/sessions"
SCRIPT_START=$(date +%s)
ACTIVE_PHP_VERSIONS=()

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
_ts()         { date -u +"%H:%M:%S"; }
_strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

_tlog() {
    local msg="${C_DIM}[$(_ts)]${C_RESET} $*"
    printf "%b\n" "$msg"
    printf "%b\n" "$msg" | _strip_ansi >> "$LOG_FILE"
}

log()  { _tlog "  ${C_BLUE}${SYM_INFO}${C_RESET}  $*"; }
ok()   { _tlog "  ${C_GREEN}${SYM_OK}${C_RESET}  $*"; }
warn() { _tlog "  ${C_YELLOW}${SYM_WARN}${C_RESET}  $*"; }
skip() { _tlog "  ${C_GRAY}${SYM_SKIP}${C_RESET}  ${C_DIM}$*${C_RESET}"; }
run()  { _tlog "  ${C_CYAN}${SYM_RUN}${C_RESET}  $*"; }

die() {
    printf "\n"
    _tlog "  ${C_RED}${SYM_ERR} FATAL${C_RESET}  $*"
    printf "\n"
    exit 1
}

section() {
    printf "\n"
    printf "%b\n" "  ${C_BOLD}${C_WHITE}==> $* ${C_RESET}"
    printf "%b\n" "  ${C_DIM}------------------------------------------------------${C_RESET}"
    printf "\n"
}

elapsed() {
    local now; now=$(date +%s)
    local diff=$(( now - SCRIPT_START ))
    printf "%dm%02ds" $(( diff / 60 )) $(( diff % 60 ))
}

# ------------------------------------------------------------------------------
# Spinner -- background animated indicator for blocking operations
# ------------------------------------------------------------------------------
_SPINNER_PID=""

spinner_start() {
    local msg="$1"
    (
        local frames=('|' '/' '-' '\')
        local i=0
        while true; do
            printf "\r  %b%s%b  %s   " \
                "${C_CYAN}" "${frames[$((i % 4))]}" "${C_RESET}" "$msg"
            (( i++ )) || true
            sleep 0.12
        done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    if [[ -n "$_SPINNER_PID" ]]; then
        kill "$_SPINNER_PID" 2>/dev/null || true
        wait "$_SPINNER_PID" 2>/dev/null || true
        _SPINNER_PID=""
        # clear spinner line
        printf "\r%80s\r" ""
    fi
}

trap 'spinner_stop' EXIT

# ------------------------------------------------------------------------------
# Progress bar (for loops with known count)
# ------------------------------------------------------------------------------
progress_bar() {
    local label="$1" cur="$2" tot="$3"
    local width=38
    local filled=$(( cur * width / tot ))
    local empty=$(( width - filled ))
    local bar_f bar_e
    bar_f=$(printf '%0.s#' $(seq 1 "$filled"))
    bar_e=$(printf '%0.s-' $(seq 1 "$empty"))
    printf "\r  %b%s%b  %-26s [%b%s%b%b%s%b] %3d%%" \
        "${C_CYAN}" "${SYM_RUN}" "${C_RESET}" \
        "$label" \
        "${C_GREEN}" "$bar_f" "${C_RESET}" \
        "${C_DIM}"   "$bar_e" "${C_RESET}" \
        $(( cur * 100 / tot ))
}

progress_done() { printf "\n"; }

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    printf "\n"
    printf "%b\n" "${C_BOLD}${C_WHITE}Webkernel OS -- PHP Server Optimizer${C_RESET}"
    printf "%b\n" "${C_DIM}https://github.com/webkernelphp/server-optimizer${C_RESET}"
    printf "\n"
    printf "%b\n" "${C_BOLD}Usage:${C_RESET}"
    printf "  sudo bash server-optimizer.sh [OPTIONS]\n"
    printf "\n"
    printf "%b\n" "${C_BOLD}Modes:${C_RESET}"
    printf "  --mode=numerimondes-webkernel   Numerimondes production defaults\n"
    printf "                                   swap=64G, all PHP, composer global,\n"
    printf "                                   opcache + fpm + kernel tuning\n"
    printf "\n"
    printf "%b\n" "${C_BOLD}Options:${C_RESET}"
    printf "  --swap=SIZE                     Swap file size (e.g. 4G, 16G, 64G)\n"
    printf "                                   Skipped automatically if disk is too full\n"
    printf "  --session-tmpfs=SIZE            Sessions tmpfs size (default: 512M)\n"
    printf "  --php-versions=SPEC             Versions to tune:\n"
    printf "                                     all         -- all installed (default)\n"
    printf "                                     8.1,8.2     -- specific versions\n"
    printf "                                     none        -- skip PHP tuning\n"
    printf "  --default-php=VERSION           Set system default PHP binary (e.g. 8.3)\n"
    printf "                                   Asked interactively if not provided\n"
    printf "  --composer=MODE                 Composer setup:\n"
    printf "                                     global             -- /usr/local/bin/composer\n"
    printf "                                     users=user1,user2  -- per-user ~/bin/composer\n"
    printf "                                     skip               -- do not install\n"
    printf "  --no-opcache                    Skip OPcache configuration\n"
    printf "  --no-fpm                        Skip PHP-FPM pool tuning\n"
    printf "  --no-kernel                     Skip sysctl / kernel tuning\n"
    printf "  --log=PATH                      Log file (default: /var/log/webkernel-optimizer.log)\n"
    printf "  --dry-run                       Preview all actions, make no changes\n"
    printf "  --force                         Skip all prompts, overwrite existing files\n"
    printf "  -h, --help                      Show this help\n"
    printf "\n"
    printf "%b\n" "${C_BOLD}Examples:${C_RESET}"
    printf "  sudo bash server-optimizer.sh --mode=numerimondes-webkernel --force\n"
    printf "  sudo bash server-optimizer.sh --swap=8G --php-versions=8.2,8.3 --default-php=8.3\n"
    printf "  sudo bash server-optimizer.sh --composer=users=alice,bob --no-kernel\n"
    printf "  sudo bash server-optimizer.sh --dry-run --mode=numerimondes-webkernel\n"
    printf "\n"
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
            --default-php=*)      OPT_DEFAULT_PHP="${arg#*=}" ;;
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

    if [[ "$OPT_MODE" == "numerimondes-webkernel" ]]; then
        [[ -z "$OPT_SWAP" ]] && OPT_SWAP="64G"
        OPT_PHP_VERSIONS="all"
        OPT_COMPOSER="global"
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
    if [[ "$OPT_DRY_RUN" == true ]]; then
        log "${C_YELLOW}[DRY-RUN]${C_RESET} would run: ${C_DIM}$*${C_RESET}"
        return 0
    fi
    "$@"
}

confirm() {
    [[ "$OPT_FORCE" == true ]] && return 0
    [[ "$OPT_DRY_RUN" == true ]] && return 0
    printf "\n"
    printf "%b\n" "  ${C_YELLOW}${SYM_WARN}  $1${C_RESET}"
    printf "%b"   "  ${C_BOLD}Continue? [y/N]${C_RESET} "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { printf "  Aborted.\n"; exit 0; }
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
            find /etc/php -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
            | grep -oP '\d+\.\d+' | sort -V
        )
    else
        # Split on commas without touching global IFS
        readarray -t ACTIVE_PHP_VERSIONS < <(tr ',' '\n' <<< "$OPT_PHP_VERSIONS")
    fi

    if [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]]; then
        warn "No PHP versions found under /etc/php/"
    else
        # Join with spaces -- safe because IFS is default
        log "Detected PHP versions: ${C_CYAN}${ACTIVE_PHP_VERSIONS[*]}${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# Ask for default PHP version interactively
# ------------------------------------------------------------------------------
ask_default_php() {
    [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]] && return
    [[ -n "$OPT_DEFAULT_PHP" ]]            && return
    [[ "$OPT_FORCE" == true ]]             && return
    [[ "$OPT_DRY_RUN" == true ]]           && return

    printf "\n"
    printf "%b\n" "  ${C_BOLD}Which PHP version should be the system default?${C_RESET}"
    printf "%b\n" "  ${C_DIM}This sets /usr/bin/php via update-alternatives.${C_RESET}"
    printf "\n"

    local i=1
    for v in "${ACTIVE_PHP_VERSIONS[@]}"; do
        printf "    %b%d)%b  php%s\n" "${C_CYAN}" "$i" "${C_RESET}" "$v"
        (( i++ )) || true
    done
    printf "    %bN)%b  Keep current default -- no change\n" "${C_CYAN}" "${C_RESET}"
    printf "\n"
    printf "%b" "  ${C_BOLD}Choice [1-${#ACTIVE_PHP_VERSIONS[@]}/N]:${C_RESET} "
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] \
        && (( choice >= 1 && choice <= ${#ACTIVE_PHP_VERSIONS[@]} )); then
        OPT_DEFAULT_PHP="${ACTIVE_PHP_VERSIONS[$((choice - 1))]}"
        log "Default PHP will be set to: ${C_CYAN}php${OPT_DEFAULT_PHP}${C_RESET}"
    else
        log "Keeping current system PHP default"
    fi
    printf "\n"
}

# ------------------------------------------------------------------------------
# Apply default PHP
# ------------------------------------------------------------------------------
apply_default_php() {
    [[ -z "$OPT_DEFAULT_PHP" ]] && return

    section "DEFAULT PHP"

    local target="/usr/bin/php${OPT_DEFAULT_PHP}"
    if [[ ! -x "$target" ]]; then
        warn "php${OPT_DEFAULT_PHP} binary not found at $target -- skipping"
        return
    fi

    run "Switching system default PHP to ${C_CYAN}php${OPT_DEFAULT_PHP}${C_RESET}..."

    if [[ "$OPT_DRY_RUN" == false ]]; then
        if update-alternatives --list php &>/dev/null; then
            update-alternatives --set php "$target"
        else
            ln -sf "$target" /usr/bin/php
        fi
    fi

    ok "System default PHP is now: ${C_CYAN}php${OPT_DEFAULT_PHP}${C_RESET}"
    log "Verify anytime with: ${C_DIM}php --version${C_RESET}"
}

# ------------------------------------------------------------------------------
# Plan summary
# ------------------------------------------------------------------------------
print_plan() {
    local v_display="${OPT_PHP_VERSIONS}"
    if [[ ${#ACTIVE_PHP_VERSIONS[@]} -gt 0 ]]; then
        v_display="${ACTIVE_PHP_VERSIONS[*]}"
    fi

    printf "\n"
    printf "%b\n" "  ${C_BOLD}${C_WHITE}+------------------------------------------------+${C_RESET}"
    printf "%b\n" "  ${C_BOLD}${C_WHITE}|       Webkernel Server Optimizer               |${C_RESET}"
    printf "%b\n" "  ${C_BOLD}${C_WHITE}+------------------------------------------------+${C_RESET}"
    printf "\n"
    [[ -n "$OPT_MODE" ]] && \
        printf "%b\n" "  ${C_CYAN}Mode          ${C_RESET}${C_BOLD}${OPT_MODE}${C_RESET}"
    printf "%b\n" "  ${C_CYAN}Swap          ${C_RESET}${OPT_SWAP:-${C_DIM}skip${C_RESET}}"
    printf "%b\n" "  ${C_CYAN}Session tmpfs ${C_RESET}${OPT_SESSION_TMPFS}"
    printf "%b\n" "  ${C_CYAN}PHP versions  ${C_RESET}${C_CYAN}${v_display}${C_RESET}"
    printf "%b\n" "  ${C_CYAN}Default PHP   ${C_RESET}${OPT_DEFAULT_PHP:-${C_DIM}ask interactively${C_RESET}}"
    printf "%b\n" "  ${C_CYAN}Composer      ${C_RESET}${OPT_COMPOSER}"
    printf "%b\n" "  ${C_CYAN}OPcache       ${C_RESET}${OPT_OPCACHE}"
    printf "%b\n" "  ${C_CYAN}FPM tuning    ${C_RESET}${OPT_FPM}"
    printf "%b\n" "  ${C_CYAN}Kernel tuning ${C_RESET}${OPT_KERNEL}"
    printf "%b\n" "  ${C_CYAN}Log           ${C_RESET}${LOG_FILE}"
    [[ "$OPT_DRY_RUN" == true ]] && \
        printf "\n%b\n" "  ${C_YELLOW}${SYM_WARN}  DRY-RUN MODE -- no changes will be made${C_RESET}"
    printf "\n"
}

# ------------------------------------------------------------------------------
# 1. SWAP
# ------------------------------------------------------------------------------
setup_swap() {
    [[ -z "$OPT_SWAP" ]] && { skip "Swap -- skipped (not requested)"; return; }

    section "SWAP"

    local swap_file="/swapfile"
    local swap_size="$OPT_SWAP"

    local size_num; size_num=$(printf '%s' "$swap_size" | grep -oP '^\d+')
    local size_unit; size_unit=$(printf '%s' "$swap_size" | grep -oP '[A-Za-z]+$' | tr '[:lower:]' '[:upper:]')
    local size_bytes
    case "$size_unit" in
        G|GB|GIB) size_bytes=$(( size_num * 1024 * 1024 * 1024 )) ;;
        M|MB|MIB) size_bytes=$(( size_num * 1024 * 1024 )) ;;
        T|TB|TIB) size_bytes=$(( size_num * 1024 * 1024 * 1024 * 1024 )) ;;
        *) die "Unrecognised swap size unit: $size_unit  (use G, M, or T)" ;;
    esac

    local free_bytes; free_bytes=$(df --output=avail -B1 / | tail -1)
    local safety=$(( 2 * 1024 * 1024 * 1024 ))
    local required=$(( size_bytes + safety ))
    local free_gb=$(( free_bytes / 1024 / 1024 / 1024 ))
    local req_gb=$(( required / 1024 / 1024 / 1024 ))

    log "Disk free: ${C_CYAN}${free_gb}G${C_RESET}  --  required: ${C_CYAN}${req_gb}G${C_RESET} (swap + 2G safety margin)"

    if (( free_bytes < required )); then
        warn "Not enough disk space for ${swap_size} swap + 2G safety margin"
        warn "Available: ${free_gb}G  --  needed: ${req_gb}G  --  skipping swap creation"
        return
    fi

    if swapon --show 2>/dev/null | grep -q "$swap_file"; then
        skip "Swap already active on $swap_file"
        return
    fi

    if [[ -f "$swap_file" ]]; then
        warn "$swap_file already exists but is inactive -- will re-format it"
    else
        run "Allocating ${swap_size} swap file at $swap_file..."
        log "This may take up to ${size_num} second(s) depending on disk speed"
        random_quote
        spinner_start "Allocating ${swap_size} swap file -- please wait..."
        dry fallocate -l "$swap_size" "$swap_file"
        spinner_stop
        ok "Swap file allocated"
    fi

    dry chmod 600 "$swap_file"
    run "Formatting swap..."
    dry mkswap "$swap_file"

    run "Activating swap..."
    dry swapon "$swap_file"

    if ! grep -q "$swap_file" /etc/fstab; then
        dry bash -c "echo '$swap_file none swap sw 0 0' >> /etc/fstab"
        dry systemctl daemon-reload
        ok "fstab entry added + daemon reloaded"
    fi

    [[ "$OPT_DRY_RUN" == false ]] && \
        ok "Swap active: $(swapon --show --noheadings | awk '{print $1, $3}')"
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
        run "Mounting ${size} tmpfs at $path  (PHP sessions stored in RAM)"
        dry mount -t tmpfs -o "size=${size},mode=1777" tmpfs "$path"
        ok "tmpfs mounted -- ${size} of RAM reserved for sessions"
    fi

    if ! grep -q "$path" /etc/fstab 2>/dev/null; then
        dry bash -c "echo 'tmpfs $path tmpfs size=${size},mode=1777 0 0' >> /etc/fstab"
        dry systemctl daemon-reload
        ok "fstab entry added + daemon reloaded"
    else
        skip "fstab entry already present"
    fi
}

# ------------------------------------------------------------------------------
# 3. COMPOSER
# ------------------------------------------------------------------------------
setup_composer() {
    [[ "$OPT_COMPOSER" == "skip" ]] && { skip "Composer -- skipped"; return; }

    section "COMPOSER"

    dry mkdir -p /usr/local/share/composer

    if [[ -f "$COMPOSER_PHAR" && "$OPT_FORCE" == false ]]; then
        skip "composer.phar already installed at $COMPOSER_PHAR"
        skip "Use --force to reinstall"
    else
        run "Downloading Composer installer from getcomposer.org..."
        log "The installer is a small PHP script (~100KB) -- should be fast"
        spinner_start "Fetching Composer installer from getcomposer.org..."
        dry curl --silent --show-error --fail \
            -o /tmp/composer-setup.php \
            https://getcomposer.org/installer
        spinner_stop
        ok "Installer downloaded"

        run "Verifying installer SHA-384 signature..."
        if [[ "$OPT_DRY_RUN" == false ]]; then
            local expected actual
            expected=$(curl --silent --show-error --fail https://composer.github.io/installer.sig)
            actual=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
            [[ "$expected" == "$actual" ]] || die "Composer installer signature mismatch -- aborting for security"
        fi
        ok "Signature verified"

        run "Running Composer installer -- downloading composer.phar..."
        log "This downloads the Composer PHAR binary (~2MB)"
        spinner_start "Installing Composer PHAR (~2MB download)..."
        dry php /tmp/composer-setup.php \
            --quiet \
            --install-dir=/usr/local/share/composer \
            --filename=composer.phar
        spinner_stop
        dry rm -f /tmp/composer-setup.php
        dry chmod 644 "$COMPOSER_PHAR"
        ok "composer.phar installed at $COMPOSER_PHAR"
    fi

    # --- Global wrapper ---
    if [[ "$OPT_COMPOSER" == "global" ]]; then
        run "Writing universal PHP wrapper at $COMPOSER_BIN..."
        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat > "$COMPOSER_BIN" << 'WRAPPER'
#!/usr/bin/env bash
# Webkernel -- Composer universal wrapper
# To use a specific PHP version: PHP_BIN=/usr/bin/php8.3 composer install
PHAR="/usr/local/share/composer/composer.phar"
if   [[ -n "${PHP_BIN:-}" ]];    then PHP="$PHP_BIN"
elif command -v php &>/dev/null; then PHP=$(command -v php)
else echo "ERROR: No PHP binary found in PATH" >&2; exit 1
fi
exec "$PHP" "$PHAR" "$@"
WRAPPER
            chmod +x "$COMPOSER_BIN"
        fi
        ok "Global wrapper ready at $COMPOSER_BIN"
        log "Default PHP version used:   ${C_DIM}$(command -v php 2>/dev/null || echo 'none')${C_RESET}"
        log "Override with:              ${C_CYAN}PHP_BIN=/usr/bin/php8.3 composer install${C_RESET}"

    # --- Per-user wrapper ---
    elif [[ "$OPT_COMPOSER" == users=* ]]; then
        local user_list="${OPT_COMPOSER#users=}"
        readarray -t target_users < <(tr ',' '\n' <<< "$user_list")

        for u in "${target_users[@]}"; do
            local home_bin
            home_bin=$(eval echo "~${u}/bin")
            run "Installing wrapper for user ${C_CYAN}${u}${C_RESET} at ${home_bin}/composer"
            if [[ "$OPT_DRY_RUN" == false ]]; then
                mkdir -p "$home_bin"
                local phar_path="$COMPOSER_PHAR"
                cat > "${home_bin}/composer" << WRAPPER
#!/usr/bin/env bash
# Webkernel -- Composer wrapper for ${u}
PHAR="${phar_path}"
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
    [[ "$OPT_OPCACHE" == false ]] && { skip "OPcache -- skipped (--no-opcache)"; return; }
    [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]] && { skip "OPcache -- no PHP versions to configure"; return; }

    section "OPCACHE"

    log "Configuring OPcache for PHP: ${C_CYAN}${ACTIVE_PHP_VERSIONS[*]}${C_RESET}"
    log "memory=256M  max_files=20000  JIT=tracing (PHP 8.x only)"
    printf "\n"

    local total=${#ACTIVE_PHP_VERSIONS[@]}
    local i=0

    for VERSION in "${ACTIVE_PHP_VERSIONS[@]}"; do
        (( i++ )) || true
        progress_bar "OPcache php${VERSION}" "$i" "$total"

        local conf_file="/etc/php/${VERSION}/mods-available/opcache.ini"
        if [[ ! -f "$conf_file" ]]; then
            progress_done
            warn "No opcache.ini for PHP ${VERSION} -- skipping"
            continue
        fi

        dry cp "$conf_file" "${conf_file}.bak.$(date +%s)" 2>/dev/null || true

        local major; major=$(printf '%s' "$VERSION" | cut -d. -f1)
        local jit_block=""
        (( major >= 8 )) && jit_block="opcache.jit_buffer_size=128M
opcache.jit=tracing"

        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat > "$conf_file" << INIEOF
; Webkernel -- OPcache production config -- PHP ${VERSION}
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
${jit_block}
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
    [[ "$OPT_FPM" == false ]] && { skip "PHP-FPM -- skipped (--no-fpm)"; return; }
    [[ ${#ACTIVE_PHP_VERSIONS[@]} -eq 0 ]] && { skip "PHP-FPM -- no PHP versions to configure"; return; }

    section "PHP-FPM POOLS"

    local ram_mb; ram_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    local avg_mb=60
    local max_children=$(( ram_mb / avg_mb ))
    (( max_children < 5 )) && max_children=5

    log "Available RAM:    ${C_CYAN}${ram_mb}M${C_RESET}"
    log "pm.max_children:  ${C_CYAN}${max_children}${C_RESET}  (${ram_mb}M / ~${avg_mb}M per worker)"
    log "pm strategy:      ${C_CYAN}dynamic${C_RESET}  (start=10, min_spare=5, max_spare=20)"
    log "pm.max_requests:  ${C_CYAN}500${C_RESET}  (workers recycle to prevent memory bloat)"
    log "session.save_path: ${C_CYAN}${SESSION_TMPFS_PATH}${C_RESET}  (tmpfs)"
    printf "\n"

    local total=${#ACTIVE_PHP_VERSIONS[@]}
    local i=0

    for VERSION in "${ACTIVE_PHP_VERSIONS[@]}"; do
        (( i++ )) || true
        progress_bar "FPM pool php${VERSION}" "$i" "$total"

        local pool_conf="/etc/php/${VERSION}/fpm/pool.d/www.conf"
        if [[ ! -f "$pool_conf" ]]; then
            progress_done
            warn "No pool.d/www.conf for PHP ${VERSION} -- skipping"
            continue
        fi

        dry cp "$pool_conf" "${pool_conf}.bak.$(date +%s)"

        if [[ "$OPT_DRY_RUN" == false ]]; then
            sed -i 's/^pm = .*/pm = dynamic/'                                           "$pool_conf"
            sed -i "s/^pm\.max_children = .*/pm.max_children = ${max_children}/"       "$pool_conf"
            sed -i 's/^pm\.start_servers = .*/pm.start_servers = 10/'                  "$pool_conf"
            sed -i 's/^pm\.min_spare_servers = .*/pm.min_spare_servers = 5/'           "$pool_conf"
            sed -i 's/^pm\.max_spare_servers = .*/pm.max_spare_servers = 20/'          "$pool_conf"

            if grep -q '^;pm\.max_requests' "$pool_conf"; then
                sed -i 's/^;pm\.max_requests = .*/pm.max_requests = 500/' "$pool_conf"
            elif grep -q '^pm\.max_requests' "$pool_conf"; then
                sed -i 's/^pm\.max_requests = .*/pm.max_requests = 500/'  "$pool_conf"
            else
                printf 'pm.max_requests = 500\n' >> "$pool_conf"
            fi

            if grep -q 'session\.save_path' "$pool_conf"; then
                sed -i "s|.*session\.save_path.*|php_value[session.save_path] = ${SESSION_TMPFS_PATH}|" "$pool_conf"
            else
                printf 'php_value[session.save_path] = %s\n' "$SESSION_TMPFS_PATH" >> "$pool_conf"
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
    [[ "$OPT_KERNEL" == false ]] && { skip "Kernel tuning -- skipped (--no-kernel)"; return; }

    section "KERNEL / SYSCTL"

    run "Writing kernel parameters to $SYSCTL_CONF..."
    log "Tuning: vm.swappiness=10, somaxconn=65535, tcp_tw_reuse=1, file-max=2M"

    if [[ "$OPT_DRY_RUN" == false ]]; then
        cat > "$SYSCTL_CONF" << 'EOF'
# =============================================================================
# Webkernel OS -- Kernel tuning for PHP application server
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
    ok "sysctl parameters applied"

    run "Updating open file limits in /etc/security/limits.conf..."
    if ! grep -q "webkernel" /etc/security/limits.conf 2>/dev/null; then
        if [[ "$OPT_DRY_RUN" == false ]]; then
            cat >> /etc/security/limits.conf << 'EOF'

# Webkernel -- PHP server open file limits
*    soft    nofile    65535
*    hard    nofile    65535
root soft    nofile    65535
root hard    nofile    65535
EOF
        fi
        ok "limits.conf updated (nofile = 65535)"
    else
        skip "limits.conf already patched"
    fi
}

# ------------------------------------------------------------------------------
# 7. FINAL REPORT
# ------------------------------------------------------------------------------
print_report() {
    section "VERIFICATION REPORT"

    printf "%b\n" "  ${C_BOLD}Memory${C_RESET}"
    free -h | sed 's/^/    /'

    printf "\n"
    printf "%b\n" "  ${C_BOLD}Swap${C_RESET}"
    swapon --show 2>/dev/null | sed 's/^/    /' || printf "    (none)\n"

    printf "\n"
    printf "%b\n" "  ${C_BOLD}Session tmpfs${C_RESET}"
    mount 2>/dev/null | grep "php/sessions" | sed 's/^/    /' || printf "    (none)\n"

    printf "\n"
    printf "%b\n" "  ${C_BOLD}OPcache per PHP version${C_RESET}"
    for v in /usr/bin/php[0-9]*.[0-9]*; do
        [[ -x "$v" ]] || continue
        local VER STATUS JIT COLOR
        VER=$("$v" -r 'echo PHP_VERSION;' 2>/dev/null) || continue
        STATUS=$("$v" -r 'echo ini_get("opcache.enable") ? "ON" : "OFF";' 2>/dev/null || printf "?")
        JIT=$("$v" -r 'echo ini_get("opcache.jit_buffer_size") ?: "-";' 2>/dev/null || printf "-")
        if [[ "$STATUS" == "ON" ]]; then COLOR="$C_GREEN"; else COLOR="$C_YELLOW"; fi
        printf "%b\n" "    PHP ${VER}  opcache=${COLOR}${STATUS}${C_RESET}  jit_buffer=${C_DIM}${JIT}${C_RESET}"
    done

    printf "\n"
    printf "%b\n" "  ${C_BOLD}System default PHP${C_RESET}"
    if command -v php &>/dev/null; then
        printf "    %s\n" "$(php --version 2>/dev/null | head -1)"
    else
        printf "    (php not in PATH)\n"
    fi

    printf "\n"
    printf "%b\n" "  ${C_BOLD}Composer${C_RESET}"
    # Call phar directly with explicit binary to avoid wrapper + network calls
    if [[ -f "$COMPOSER_PHAR" ]]; then
        local php_bin
        php_bin=$(command -v php 2>/dev/null || printf "")
        if [[ -n "$php_bin" ]]; then
            printf "    %s\n" "$("$php_bin" "$COMPOSER_PHAR" --version --no-ansi --no-interaction 2>/dev/null \
                || printf 'Installed (version check timed out -- run: php %s --version)' "$COMPOSER_PHAR")"
        else
            printf "    Installed at %s\n" "$COMPOSER_PHAR"
        fi
    else
        printf "    Not installed\n"
    fi

    printf "\n"
    printf "%b\n" "  ${C_BOLD}PHP-FPM services${C_RESET}"
    local found_fpm=false
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        found_fpm=true
        local state; state=$(systemctl is-active "$svc" 2>/dev/null || printf "unknown")
        local color
        if [[ "$state" == "active" ]]; then color="$C_GREEN"; else color="$C_YELLOW"; fi
        printf "%b\n" "    ${color}${svc}${C_RESET}  ${C_DIM}${state}${C_RESET}"
    done < <(systemctl list-units --type=service --state=active --no-legend 2>/dev/null \
             | grep -oP 'php\S+-fpm\.service' || true)
    [[ "$found_fpm" == false ]] && printf "    (none active)\n"

    local total_elapsed; total_elapsed=$(elapsed)
    printf "\n"
    printf "%b\n" "  ${C_DIM}Log    : $LOG_FILE${C_RESET}"
    printf "%b\n" "  ${C_DIM}Time   : ${total_elapsed}${C_RESET}"
    random_quote
    printf "\n"
    printf "%b\n" "  ${C_BOLD}${C_GREEN}${SYM_OK}  All done. Server optimized.${C_RESET}"
    printf "\n"
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

    detect_php_versions
    print_plan

    [[ "$OPT_FORCE" == false && "$OPT_DRY_RUN" == false ]] && \
        confirm "This will modify system configuration on $(hostname -f 2>/dev/null || hostname)."

    ask_default_php

    setup_swap
    setup_session_tmpfs
    apply_default_php
    setup_composer
    configure_opcache
    tune_fpm_pools
    tune_kernel
    print_report
}

main "$@"
