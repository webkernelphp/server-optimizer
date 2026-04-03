# Webkernel OS — PHP Server Optimizer

Webkernel Server Optimizer is a Bash script to automatically configure and optimize PHP servers on Debian and Ubuntu. It handles swap setup, PHP tuning, OPcache, PHP-FPM pools, kernel parameters, Composer installation, and tmpfs for PHP sessions.

## Requirements

- Debian 11/12 or Ubuntu 20.04+
- Root access
- Internet access for Composer installation

## Usage

```bash
sudo bash server-optimizer.sh [OPTIONS]
```

## Download & Run

### Using `wget`

```bash
wget https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-optimizer.sh -O server-optimizer.sh
sudo bash server-optimizer.sh [OPTIONS]
```

### Using `curl`

```bash
curl -o server-optimizer.sh https://raw.githubusercontent.com/webkernelphp/server-optimizer/refs/heads/main/server-optimizer.sh
sudo bash server-optimizer.sh [OPTIONS]
```

## Modes

* `--mode=numerimondes-webkernel` — Production preset (64G swap, all PHP versions, global Composer, OPcache, FPM, kernel tuning)

## Options

| Option                 | Description                               |
| ---------------------- | ----------------------------------------- |
| `--swap=SIZE`          | Swap file size (e.g., 4G, 16G, 64G)       |
| `--session-tmpfs=SIZE` | RAM disk for PHP sessions (default: 512M) |
| `--php-versions=`      | `all`, `8.1,8.2`, or `none`               |
| `--composer=`          | `global`, `users=user1,user2`, `skip`     |
| `--no-opcache`         | Disable OPcache tuning                    |
| `--no-fpm`             | Disable PHP-FPM tuning                    |
| `--no-kernel`          | Disable kernel tuning                     |
| `--log=PATH`           | Custom log file                           |
| `--dry-run`            | Show actions without changes              |
| `--force`              | Skip confirmation prompts                 |
| `-h, --help`           | Show help                                 |

## Examples

```bash
sudo bash server-optimizer.sh --mode=numerimondes-webkernel
sudo bash server-optimizer.sh --swap=16G --php-versions=8.2,8.3 --composer=global
sudo bash server-optimizer.sh --dry-run --mode=numerimondes-webkernel
```

## Features

* Swap creation with safety checks
* PHP version detection and tuning
* OPcache configuration
* PHP-FPM optimization
* Kernel/sysctl tuning
* Composer installation with signature verification
* tmpfs for fast PHP sessions
* Logging to a configurable file
* Dry-run mode for safe previews
