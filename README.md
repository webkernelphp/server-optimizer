# Webkernel Server Optimizer Suite

A comprehensive toolkit of bash scripts to optimize, monitor, and maintain PHP servers on Debian/Ubuntu with HestiaCP integration.

## Overview

The **Webkernel Server Optimizer** suite consists of three complementary scripts designed to work together for complete server lifecycle management:

1. **server-optimizer.sh** — Initial setup and optimization
2. **server-apps-autoheal.sh** — Automated remediation and fixes  
3. **server-perf-report.sh** — Performance diagnostics and reporting

---

## Requirements

- Debian 11/12 or Ubuntu 20.04+
- Root access (all scripts require `sudo`)
- Internet access (for Composer installation)
- Optional: HestiaCP for advanced features

---

## Script 1: server-optimizer.sh

**Purpose:** Initial server configuration and optimization (one-time setup)

### Download & Run

#### Using `wget`
```bash
TIMESTAMP=$(date +%s)
wget "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-optimizer.sh?ts=$TIMESTAMP" -O server-optimizer.sh
sudo bash server-optimizer.sh [OPTIONS]
```

#### Using `curl`
```bash
TIMESTAMP=$(date +%s)
curl -L "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-optimizer.sh?ts=$TIMESTAMP" -o server-optimizer.sh
sudo bash server-optimizer.sh [OPTIONS]
```

### Modes

| Mode | Description |
|------|-------------|
| `--mode=numerimondes-webkernel` | Production preset (64G swap, all PHP versions, global Composer, OPcache, FPM, kernel tuning) |

### Options

| Option | Description |
|--------|-------------|
| `--swap=SIZE` | Swap file size (e.g., 4G, 16G, 64G) |
| `--session-tmpfs=SIZE` | RAM disk for PHP sessions (default: 512M) |
| `--php-versions=` | `all`, `8.1,8.2`, or `none` |
| `--composer=` | `global`, `users=user1,user2`, `skip` |
| `--no-opcache` | Disable OPcache tuning |
| `--no-fpm` | Disable PHP-FPM tuning |
| `--no-kernel` | Disable kernel tuning |
| `--log=PATH` | Custom log file |
| `--dry-run` | Show actions without applying changes |
| `--force` | Skip confirmation prompts |
| `-h, --help` | Show help |

### Examples

```bash
# Full production setup
sudo bash server-optimizer.sh --mode=numerimondes-webkernel

# Custom configuration
sudo bash server-optimizer.sh --swap=16G --php-versions=8.2,8.3 --composer=global

# Preview without changes
sudo bash server-optimizer.sh --dry-run --mode=numerimondes-webkernel
```

### Features

- Swap creation with safety checks
- PHP version detection and tuning
- OPcache configuration
- PHP-FPM optimization
- Kernel/sysctl tuning
- Composer installation with signature verification
- tmpfs for fast PHP sessions
- Logging to configurable file
- Dry-run mode for safe previews

---

## Script 2: server-apps-autoheal.sh

**Purpose:** Automated application fixes and remediation (ongoing maintenance)

### Download & Run

#### Using `wget`
```bash
TIMESTAMP=$(date +%s)
wget "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-apps-autoheal.sh?ts=$TIMESTAMP" -O server-apps-autoheal.sh
sudo bash server-apps-autoheal.sh [OPTIONS]
```

#### Using `curl`
```bash
TIMESTAMP=$(date +%s)
curl -L "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-apps-autoheal.sh?ts=$TIMESTAMP" -o server-apps-autoheal.sh
sudo bash server-apps-autoheal.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would be done without applying anything |
| `--yes` | Skip confirmation prompts for SAFE actions (dangerous always prompt) |
| `--only=SLUG` | Run only a specific fix by slug |
| `--list` | List all available fix slugs |
| `-h, --help` | Show help |

### Available Fix Slugs

| Slug | Description | Safety |
|------|-------------|--------|
| `fpm-dynamic` | Switch all ondemand pools to dynamic | SAFE |
| `fpm-dummy-children` | Raise dummy pool max_children from 4 to sane default | SAFE |
| `opcache-tune` | Set validate_timestamps=0, realpath_cache, memory | SAFE |
| `mysql-slowlog` | Enable MySQL slow query log | SAFE |
| `laravel-cache` | Run composer w-cache on all detected Webkernel projects | SAFE |
| `laravel-500` | Diagnose and repair Laravel 500 errors | SAFE |
| `env-debug-off` | Set APP_DEBUG=false on projects with debug on | DANGEROUS |
| `env-production` | Set APP_ENV=production on projects still in local/dev | DANGEROUS |

### Examples

```bash
# List all available fixes
sudo bash server-apps-autoheal.sh --list

# Preview changes without applying
sudo bash server-apps-autoheal.sh --dry-run

# Auto-apply all SAFE fixes
sudo bash server-apps-autoheal.sh --yes

# Run specific fix
sudo bash server-apps-autoheal.sh --only=opcache-tune

# Recommended order (interactive)
sudo bash server-apps-autoheal.sh --only=opcache-tune
sudo bash server-apps-autoheal.sh --only=fpm-dummy-children
sudo bash server-apps-autoheal.sh --only=fpm-dynamic
sudo bash server-apps-autoheal.sh --only=mysql-slowlog
sudo bash server-apps-autoheal.sh --only=env-debug-off
sudo bash server-apps-autoheal.sh --only=env-production
sudo bash server-apps-autoheal.sh --only=laravel-cache
```

### Features

- PHP-FPM pool optimization
- OPcache tuning with verification
- MySQL slow query log enablement
- Laravel application config fixes
- Per-project safety prompts
- Automatic backups before changes
- Service restart verification
- Detailed logging to sysadmin reports
- Dry-run mode for previews

---

## Script 3: server-perf-report.sh

**Purpose:** Comprehensive performance diagnostics and analysis (diagnostic)

### Download & Run

#### Using `wget`
```bash
TIMESTAMP=$(date +%s)
wget "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-perf-report.sh?ts=$TIMESTAMP" -O server-perf-report.sh
sudo bash server-perf-report.sh [OPTIONS]
```

#### Using `curl`
```bash
TIMESTAMP=$(date +%s)
curl -L "https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-perf-report.sh?ts=$TIMESTAMP" -o server-perf-report.sh
sudo bash server-perf-report.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--test` | Run HTTP simulation against https://test.webkernelphp.com/ |
| `--test="https://url"` | Run HTTP simulation against given URL |
| `--artisan` | Run Laravel cache warm-up on detected Webkernel projects |
| `--no-color` | Disable terminal colors |
| `-h, --help` | Show help |

### Examples

```bash
# Full report with system diagnostics
sudo bash server-perf-report.sh

# Report with HTTP performance testing
sudo bash server-perf-report.sh --test

# Test against specific domain
sudo bash server-perf-report.sh --test="https://example.com"

# Include Laravel cache warm-up
sudo bash server-perf-report.sh --artisan

# Full report with testing and cache warm-up
sudo bash server-perf-report.sh --test --artisan

# Non-color output (for logs)
sudo bash server-perf-report.sh --no-color > report.txt
```

### Report Sections

The generated report includes:

1. **Executive Summary** — Critical issues with actionable fixes
2. **System Overview** — CPU, Memory, Disk, Process information
3. **Network** — Interface, sockets, connection states
4. **HestiaCP** — Panel configuration and status (if installed)
5. **Nginx** — Version, config, error logs, active connections
6. **Apache2** — Configuration and status (if installed)
7. **PHP-FPM** — All versions, pool configs, OPcache status
8. **MySQL/MariaDB** — Configuration, performance variables, slow logs
9. **Redis** — Status, configuration, keyspace info
10. **Supervisor** — Queue worker status
11. **Systemd Services** — Status of relevant services
12. **Cron Jobs** — Scheduled tasks review
13. **Webkernel/Laravel Projects** — Project detection, .env review, logs
14. **Artisan Cache Warm-up** — Optional cache building
15. **HTTP Simulation** — Optional performance testing
16. **OOM & Kernel Messages** — Recent errors and warnings
17. **System Limits** — File descriptors, TCP settings, swap usage
18. **Automated Checks** — Performance issues with recommendations

### Features

- 17 comprehensive diagnostic sections
- Automatic issue detection (Critical/Warning/OK)
- Actionable remediation recommendations
- HestiaCP integration
- Multi-PHP version support
- Laravel project auto-discovery
- OPcache health metrics
- MySQL/MariaDB analysis
- Redis/cache diagnostics
- Network connection analysis
- Kernel message review
- Optional HTTP performance testing
- Optional cache warm-up
- Executive summary prepended to full report
- Reports saved to `/root/sysadmin/webkernel-reports/`
- Color-coded terminal output

---

## Typical Workflow

### Initial Setup
```bash
# 1. Optimize the server (one-time)
sudo bash server-optimizer.sh --mode=numerimondes-webkernel

# 2. Generate initial report
sudo bash server-perf-report.sh > initial-report.txt
```

### Ongoing Maintenance (Monthly/As-Needed)
```bash
# 1. Apply all safe autoheal fixes
sudo bash server-apps-autoheal.sh --yes

# 2. Generate updated report
sudo bash server-perf-report.sh

# 3. Review summary for any remaining issues
# Issues shown in EXECUTIVE SUMMARY section
```

### Troubleshooting Specific Issues
```bash
# When Laravel apps return 500 errors
sudo bash server-apps-autoheal.sh --only=laravel-500

# When OPcache memory is full
sudo bash server-apps-autoheal.sh --only=opcache-tune

# When response times are slow
sudo bash server-perf-report.sh --test="https://yoursite.com"
```

---

## Common Scenarios

### Slow Website Performance
```bash
# 1. Generate diagnostic report with HTTP testing
sudo bash server-perf-report.sh --test="https://yoursite.com"

# 2. Review EXECUTIVE SUMMARY for critical issues

# 3. Apply recommended fixes from autoheal
sudo bash server-apps-autoheal.sh --only=opcache-tune
sudo bash server-apps-autoheal.sh --only=fpm-dynamic

# 4. Verify with new report
sudo bash server-perf-report.sh --test="https://yoursite.com"
```

### Laravel 500 Errors
```bash
# 1. Diagnose and repair
sudo bash server-apps-autoheal.sh --only=laravel-500

# 2. Check logs in generated report
sudo bash server-perf-report.sh
```

### High CPU or Memory Usage
```bash
# 1. Generate diagnostic report
sudo bash server-perf-report.sh

# 2. Review "Top Processes by CPU/RAM" and "Automated Checks"

# 3. Apply relevant fixes
sudo bash server-apps-autoheal.sh --only=fpm-dynamic
sudo bash server-apps-autoheal.sh --only=env-debug-off
```

### New Server Deployment
```bash
# 1. Initial optimization
sudo bash server-optimizer.sh --mode=numerimondes-webkernel

# 2. Apply all safe autoheal fixes
sudo bash server-apps-autoheal.sh --yes

# 3. Deploy applications, then generate report
sudo bash server-perf-report.sh --artisan
```

---

## Log Locations

All scripts generate logs in `/root/sysadmin/webkernel-reports/`:

- `server-optimizer_TIMESTAMP.log` — Setup logs
- `w-autoheal_TIMESTAMP.log` — Autoheal fix logs
- `server-perf-report_TIMESTAMP.txt` — Complete diagnostic report

---

## License

EPL-2.0

---

## For issues or suggestions

TO SEE EXISTING ONES, VISIT:
- https://github.com/webkernelphp/server-optimizer/issues

TO CREATE A NEW ONE, VISIT:
- https://github.com/webkernelphp/server-optimizer/issues/new (for a new one)
