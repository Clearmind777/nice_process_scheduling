#!/bin/bash
#
# nice-scheduler.sh — 通用进程 nice 调度守护
#
# 用法: nice-scheduler.sh <job-name>
#
# 从 tmp/<job-name>.conf 读取配置，轮询匹配进程并维持目标 nice 值。
# 设计为由 systemd nice-scheduler@.service 模板调用。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/tmp"
SCHEDULER_USER="${SCHEDULER_USER:-$(whoami)}"

# ── 参数 ────────────────────────────────────────────────────
JOB_NAME="${1:-}"
if [ -z "$JOB_NAME" ]; then
    echo "Usage: $0 <job-name>" >&2
    exit 1
fi

CONF_FILE="${CONF_DIR}/${JOB_NAME}.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: config not found: $CONF_FILE" >&2
    exit 1
fi

# ── 加载配置 ────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$CONF_FILE"

PROCESS_PATTERN="${PROCESS_PATTERN:-}"
NICE_TARGET="${NICE_TARGET:-19}"
SCAN_INTERVAL="${SCAN_INTERVAL:-10}"

if [ -z "$PROCESS_PATTERN" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: PROCESS_PATTERN not set in $CONF_FILE" >&2
    exit 1
fi

# ── 函数 ────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$JOB_NAME] $*"
}

get_current_nice() {
    local pid="$1"
    awk '{print $19}' /proc/"$pid"/stat 2>/dev/null || echo ""
}

get_process_count() {
    pgrep -f "$PROCESS_PATTERN" 2>/dev/null | wc -l
}

# ── 启动日志 ────────────────────────────────────────────────
log "scheduler started (pattern='${PROCESS_PATTERN}', target_nice=${NICE_TARGET}, interval=${SCAN_INTERVAL}s)"
log "description: ${DESCRIPTION:-<none>}"

# ── 主循环 ──────────────────────────────────────────────────
consecutive_dry=0
while true; do
    matched_pids=$(pgrep -f "$PROCESS_PATTERN" 2>/dev/null || true)

    changed=0
    for pid in $matched_pids; do
        # 跳过非当前用户的进程（renice 会失败，提前过滤减少日志噪音）
        pid_owner=$(awk '/^Uid:/ {print $2}' /proc/"$pid"/status 2>/dev/null || echo "")
        if [ "$pid_owner" != "$(id -u "$SCHEDULER_USER" 2>/dev/null || echo "")" ]; then
            continue
        fi

        current_nice=$(get_current_nice "$pid")

        if [ -z "$current_nice" ]; then
            continue
        fi

        if [ "$current_nice" -lt "$NICE_TARGET" ]; then
            if renice -n "$NICE_TARGET" -p "$pid" >/dev/null 2>&1; then
                log "PID $pid: nice $current_nice → $NICE_TARGET"
                changed=$((changed + 1))
            else
                log "PID $pid: renice failed (nice=$current_nice)"
            fi
        fi
    done

    # 降低日志噪声：只在有变更或每 60 个周期输出一次状态
    if [ "$changed" -gt 0 ]; then
        consecutive_dry=0
    else
        consecutive_dry=$((consecutive_dry + 1))
        if [ $((consecutive_dry % 6)) -eq 0 ]; then
            process_count=$(echo "$matched_pids" | grep -c . || echo 0)
            log "heartbeat: ${process_count} process(es) at nice ${NICE_TARGET}"
        fi
    fi

    sleep "$SCAN_INTERVAL"
done
