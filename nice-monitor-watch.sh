#!/bin/bash
#
# nice-monitor-watch.sh — 基于 watch(1) 的 CPU 调度监控面板
#
# 用法:
#   nice-monitor-watch.sh [--interval N] [job-name ...]
#
# 与 nice-monitor.sh 的区别:
#   - 使用 watch(1) 驱动刷新循环，而非 bash 内建 while+read
#   - 不支持交互按键（q/r/+/-），使用 Ctrl+C 退出
#   - 更轻量，代码行数更少
#   - 终端自适应更好（watch 原生处理 clear + 尺寸变化）
#

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'
C_MAGENTA='\033[35m'
C_DIM='\033[2m'

# ── 环境变量传递 ────────────────────────────────────────────
# 由 watch 子进程继承：NICE_MONITOR_CONF_DIR, NICE_MONITOR_JOBS

# ── 数据获取函数 ────────────────────────────────────────────

get_system_cpu() {
    top -b -n1 2>/dev/null | grep "^%Cpu(s)" | awk '{
        for(i=1;i<=NF;i++) {
            val=$(i-1); gsub(/[^0-9.]/,"",val)
            if($i=="us,") us=val
            if($i=="sy,") sy=val
            if($i=="ni,") ni=val
            if($i=="id,") id=val
            if($i=="wa,") wa=val
        }
    }
    END { printf "%s %s %s %s %s", us, sy, ni, id, wa }
    '
}

get_load() {
    awk '{print $1, $2, $3}' /proc/loadavg
}

get_job_processes() {
    local pattern="$1"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)
    [ -z "$pids" ] && return
    for pid in $pids; do
        ps -o pid=,nice=,%cpu=,%mem=,stat=,etime=,cmd= -p "$pid" --no-headers 2>/dev/null || true
    done
}

# ── 显示函数 ────────────────────────────────────────────────

print_header() {
    local load; load=$(get_load)
    local us sy ni id wa
    read -r us sy ni id wa <<< "$(get_system_cpu)"

    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}CPU Scheduler Monitor (watch)${C_RESET}   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${C_BOLD}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_BOLD}║${C_RESET}  Load: ${C_YELLOW}${load}${C_RESET}  |  Cores: $(nproc)"
    printf "${C_BOLD}║${C_RESET}  ${C_GREEN}us: %5s%%${C_RESET}  ${C_RED}sy: %5s%%${C_RESET}  ${C_MAGENTA}ni: %5s%%${C_RESET}  ${C_DIM}id: %5s%%${C_RESET}  ${C_YELLOW}wa: %5s%%${C_RESET}\n" \
        "$us" "$sy" "$ni" "$id" "$wa"

    # 可视化条
    local us_int; us_int=$(printf "%.0f" "$us" 2>/dev/null || echo 0)
    local sy_int; sy_int=$(printf "%.0f" "$sy" 2>/dev/null || echo 0)
    local ni_int; ni_int=$(printf "%.0f" "$ni" 2>/dev/null || echo 0)
    local us_bar sy_bar ni_bar
    us_bar=$(dd if=/dev/zero bs="$us_int" count=1 2>/dev/null | tr '\0' '#' || true)
    sy_bar=$(dd if=/dev/zero bs="$sy_int" count=1 2>/dev/null | tr '\0' '#' || true)
    ni_bar=$(dd if=/dev/zero bs="$ni_int" count=1 2>/dev/null | tr '\0' '#' || true)
    local dots
    dots=$(dd if=/dev/zero bs=30 count=1 2>/dev/null | tr '\0' '.' || true)
    printf "${C_BOLD}║${C_RESET}  ${C_GREEN}%s${C_RED}%s${C_MAGENTA}%s${C_DIM}%s${C_RESET}\n" "$us_bar" "$sy_bar" "$ni_bar" "$dots"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
}

print_job_section() {
    local name="$1"
    local conf_file="${NICE_MONITOR_CONF_DIR}/${name}.conf"

    if [ ! -f "$conf_file" ]; then
        echo -e "${C_RED}  [${name}] config not found${C_RESET}"
        return
    fi

    source "$conf_file"

    local svc_status
    svc_status=$(systemctl --user is-active "nice-scheduler@${name}.service" 2>/dev/null || echo "inactive")
    local svc_symbol
    case "$svc_status" in
        active) svc_symbol="${C_GREEN}●${C_RESET}" ;;
        *) svc_symbol="${C_YELLOW}○${C_RESET}" ;;
    esac

    echo ""
    echo -e "${C_BOLD}┌─ Job: ${C_CYAN}${name}${C_RESET} ${svc_symbol}  target_nice=${NICE_TARGET}  pattern='${PROCESS_PATTERN}'${C_RESET}"
    echo -e "${C_BOLD}│${C_RESET}  ${C_DIM}${DESCRIPTION:-}${C_RESET}"
    echo -e "${C_BOLD}│${C_RESET}"

    local processes
    processes=$(get_job_processes "$PROCESS_PATTERN")

    if [ -z "$processes" ]; then
        echo -e "${C_BOLD}│${C_RESET}  ${C_YELLOW}(no matching processes)${C_RESET}"
    else
        printf "${C_BOLD}│${C_RESET}  %-8s %5s %6s %6s %-5s %-8s %s\n" \
            "PID" "NICE" "%CPU" "%MEM" "STAT" "TIME" "COMMAND"
        echo -e "${C_BOLD}│${C_RESET}  ──────────────────────────────────────────────────────────"

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local p_pid p_nice p_cpu p_mem p_stat p_time p_cmd
            read -r p_pid p_nice p_cpu p_mem p_stat p_time p_cmd <<< "$line"

            local nice_color="$C_RESET"
            if [ "$p_nice" -ge "$NICE_TARGET" ] 2>/dev/null; then
                nice_color="$C_GREEN"
            else
                nice_color="$C_RED"
            fi

            p_cmd=$(echo "$p_cmd" | cut -c1-40)

            printf "${C_BOLD}│${C_RESET}  %-8s ${nice_color}%5s${C_RESET} %6s %6s %-5s %-8s %s\n" \
                "$p_pid" "$p_nice" "$p_cpu" "$p_mem" "$p_stat" "$p_time" "$p_cmd"
        done <<< "$processes"
    fi
    echo -e "${C_BOLD}└─────────────────────────────────────────────────────────────────────${C_RESET}"
}

print_footer() {
    echo ""
    echo -e "  ${C_DIM}Powered by watch(1)  |  Ctrl+C to quit${C_RESET}"
}

# ── 渲染模式：输出一帧后退出 ────────────────────────────────
do_render() {
    print_header
    for job_name in $NICE_MONITOR_JOBS; do
        print_job_section "$job_name"
    done
    print_footer
}

# ── 入口 ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/tmp"

# ── watch 子进程入口（通过环境变量 NICE_MONITOR_RENDER 检测）───
if [ "${NICE_MONITOR_RENDER:-}" = "1" ]; then
    do_render
    exit 0
fi

# ── 首次调用：解析参数，启动 watch ───────────────────────────
INTERVAL=2
JOB_NAMES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--interval N] [job-name ...]"
            echo "Monitor system load and managed process scheduling via watch(1)."
            echo ""
            echo "Options:"
            echo "  --interval N   Refresh interval in seconds (default: 2)"
            echo ""
            echo "Keys (when running):"
            echo "  Ctrl+C         Quit"
            echo ""
            echo "Examples:"
            echo "  $0                            # monitor all jobs"
            echo "  $0 jupyter-kernel             # monitor a specific job"
            echo "  $0 --interval 5 job1 job2     # custom interval, multiple jobs"
            exit 0
            ;;
        *) JOB_NAMES+=("$1"); shift ;;
    esac
done

# 自动发现
if [ ${#JOB_NAMES[@]} -eq 0 ]; then
    if [ -d "$CONF_DIR" ]; then
        for conf in "$CONF_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            JOB_NAMES+=("$(basename "$conf" .conf)")
        done
    fi
fi

if [ ${#JOB_NAMES[@]} -eq 0 ]; then
    echo "No jobs found. Create one with: nice-mgr.sh start <name> --pattern <pattern>"
    exit 1
fi

# 导出环境变量给 watch 子进程
export NICE_MONITOR_RENDER=1
export NICE_MONITOR_CONF_DIR="$CONF_DIR"
export NICE_MONITOR_JOBS="${JOB_NAMES[*]}"

# 启动 watch
exec watch \
    --interval "$INTERVAL" \
    --color \
    --no-title \
    "$0"
