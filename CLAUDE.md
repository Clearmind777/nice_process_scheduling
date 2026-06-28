# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Nice Process Scheduler — a user-space framework for automatically maintaining target `nice` values on matched Linux processes. Managed via systemd user services, no root required.

## Architecture

```
nice-mgr.sh (CLI) → systemd --user nice-scheduler@<name>.service → nice-scheduler.sh (daemon)
                                                                     ├── pgrep -f <pattern>
                                                                     ├── renice -n <target> -p <pid>
                                                                     └── sleep <interval>
```

Three independent layers:
- **nice-mgr.sh** — job lifecycle manager (start/stop/kill/status/list/ps/edit). Writes configs to `tmp/<name>.conf`, installs the systemd template to `~/.config/systemd/user/`.
- **nice-scheduler.sh** — stateless polling daemon. Reads a single conf file, scans via `pgrep`, applies `renice`. Only touches processes owned by `$(whoami)` (gated by `/proc/<pid>/status` Uid check).
- **nice-scheduler@.service** — systemd user template, `%i` = job name, passes it as the only argument to the daemon.

Config format (`tmp/<name>.conf`, bash-sourceable):
```
PROCESS_PATTERN="pgrep -f pattern"
NICE_TARGET=19
SCAN_INTERVAL=10
DESCRIPTION="..."
```

Two monitor scripts, identical output, different refresh mechanisms:
- `nice-monitor.sh` — bash `while read -t` loop, interactive keys (q/r/+/-)
- `nice-monitor-watch.sh` — dual-mode: first call parses args and execs `watch`, watch sub-calls (detected via `NICE_MONITOR_RENDER=1` env var) render one frame

## Key constraints

- **renice up (lower priority) only** — no root needed. Decreasing nice (raising priority) would require CAP_SYS_NICE.
- **SCHED_IDLE is a one-way door** — `chrt --idle` works without privileges, but switching back to SCHED_OTHER requires CAP_SYS_NICE. This project uses nice values only, not scheduling policy changes.
- **pgrep is cross-user by default** — the daemon filters by UID before calling renice. Job configs should include a user-specific pattern prefix (e.g. `zjl.*ipykernel_launcher`) to avoid noisy status output.
- **ps -p expects comma-separated PIDs** — pgrep outputs newline-separated. `nice-mgr.sh` converts via `tr '\n' ','` before passing to ps.

## Common commands

```bash
# Job management
./nice-mgr.sh start <name> --pattern "<pgrep-pattern>" [--nice 19] [--interval 10] [--desc "..."]
./nice-mgr.sh stop <name>        # stop service, keep config
./nice-mgr.sh kill <name>        # stop + disable + delete config
./nice-mgr.sh status <name>      # job info + compact process table
./nice-mgr.sh ps <name>          # detailed process list (PID, PPID, RSS, TIME, full CMD)
./nice-mgr.sh list               # all jobs
./nice-mgr.sh edit <name>        # $EDITOR on config file

# Monitoring
./nice-monitor.sh [--interval N] [job-name ...]        # interactive
./nice-monitor-watch.sh [--interval N] [job-name ...]  # watch-based

# Direct systemd
systemctl --user status nice-scheduler@<name>.service
journalctl --user -u nice-scheduler@<name>.service -f
```

## Testing changes

- After editing `nice-scheduler.sh`: `systemctl --user restart nice-scheduler@<name>.service`
- After editing `nice-mgr.sh`: run `./nice-mgr.sh <command>` directly, no daemon reload needed
- After editing `nice-scheduler@.service`: `systemctl --user daemon-reload && systemctl --user restart nice-scheduler@<name>`
- Verify renice is working: `./nice-mgr.sh status <name>` — nice column should show target value in green
- Dry-run the daemon: `./nice-scheduler.sh <name>` (runs in foreground, Ctrl+C to stop)
