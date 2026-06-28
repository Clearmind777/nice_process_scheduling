#!/bin/bash
#
# nice-monitor.sh — 实时 CPU 调度监控面板
#
# 用法:
#   nice-monitor.sh [--interval N] [job-name ...]
#
# 不指定 job-name 时监控所有受管理作业。
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/tmp"

# ── 颜色 ────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'
C_MAGENTA='\033[35m'
C_DIM='\033[2m'

# ── 参数解析 ────────────────────────────────────────────────
INTERVAL=2
JOB_NAMES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--interval N] [job-name ...]"
            echo "Monitor system load and managed process scheduling."
            exit 0
            ;;
        *) JOB_NAMES+=("$1"); shift ;;
    esac
done

# 未指定作业名时自动发现所有受管理作业
if [ ${#JOB_NAMES[@]} -eq 0 ]; then
    if [ -d "$CONF_DIR" ]; then
        for conf in "$CONF_DIR"/*.conf; do
            [ -f "$conf" ] || continue
            JOB_NAMES+=("$(basename "$conf" .conf)")
        done
    fi
fi

# ── 数据获取函数 ────────────────────────────────────────────

# 系统级 CPU 使用率
get_system_cpu() {
    local cpu_line
    # 不使用 -1 才能得到聚合行 %Cpu(s):
    cpu_line=$(top -b -n1 2>/dev/null | grep "^%Cpu(s)" || true)
    if [ -n "$cpu_line" ]; then
        # 解析聚合行: %Cpu(s):  5.2 us,  2.1 sy, 45.3 ni, 47.1 id,  0.0 wa, ...
        echo "$cpu_line" | awk '{
            for(i=1;i<=NF;i++) {
                val=$(i-1); gsub(/[^0-9.]/,"",val)
                if($i=="us,")  us=val
                if($i=="sy,")  sy=val
                if($i=="ni,")  ni=val
                if($i=="id,")  id=val
                if($i=="wa,")  wa=val
            }
        }
        END { printf "%s %s %s %s %s", us, sy, ni, id, wa }
        ' 2>/dev/null
    fi
}

# 每核 CPU 使用率（top-5 最忙核心）
get_top_cores() {
    top -b -n1 -1 2>/dev/null | grep "^%Cpu" | \
        awk '{
            for(i=1;i<=NF;i++) {
                if($i=="ni,") ni=substr($(i-1),1); gsub(/[^0-9.]/,"",ni)
                if($i=="us,") us=substr($(i-1),1); gsub(/[^0-9.]/,"",us)
                if($i=="sy,") sy=substr($(i-1),1); gsub(/[^0-9.]/,"",sy)
                if($i=="id,") id=substr($(i-1),1); gsub(/[^0-9.]/,"",id)
            }
            total=us+ni+sy
            printf "%s %.1f\n", $1, total
        }' | sort -t' ' -k2 -rn | head -5
}

# Load average
get_load() {
    awk '{print $1, $2, $3}' /proc/loadavg
}

# 作业进程详情
get_job_processes() {
    local pattern="$1"
    local target_nice="$2"
    local pids
    pids=$(pgrep -f "$pattern" 2>/dev/null || true)

    if [ -z "$pids" ]; then
        return
    fi

    for pid in $pids; do
        ps -o pid=,nice=,%cpu=,%mem=,stat=,etime=,cmd= -p "$pid" --no-headers 2>/dev/null || true
    done
}

# ── 显示函数 ────────────────────────────────────────────────

print_header() {
    local load
    load=$(get_load)
    local cpu_info
    cpu_info=$(get_system_cpu)
    local us sy ni id wa
    read -r us sy ni id wa <<< "$cpu_info"

    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║${C_RESET}  ${C_CYAN}CPU Scheduler Monitor${C_RESET}   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${C_BOLD}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_BOLD}║${C_RESET}  Load: ${C_YELLOW}${load}${C_RESET}  |  Cores: $(nproc)"
    printf "${C_BOLD}║${C_RESET}  ${C_GREEN}us: %5s%%${C_RESET}  ${C_RED}sy: %5s%%${C_RESET}  ${C_MAGENTA}ni: %5s%%${C_RESET}  ${C_DIM}id: %5s%%${C_RESET}  ${C_YELLOW}wa: %5s%%${C_RESET}\n" \
        "$us" "$sy" "$ni" "$id" "$wa"

    # 可视化条
    local us_bar sy_bar ni_bar id_bar
    us_bar=$(printf "%.0f" "$us" 2>/dev/null || echo 0); us_bar=$(head -c $(( us_bar > 0 ? us_bar : 0 )) < /dev/zero | tr '\0' '#' || true)
    sy_bar=$(printf "%.0f" "$sy" 2>/dev/null || echo 0); sy_bar=$(head -c $(( sy_bar > 0 ? sy_bar : 0 )) < /dev/zero | tr '\0' '#' || true)
    ni_bar=$(printf "%.0f" "$ni" 2>/dev/null || echo 0); ni_bar=$(head -c $(( ni_bar > 0 ? ni_bar : 0 )) < /dev/zero | tr '\0' '#' || true)
    printf "${C_BOLD}║${C_RESET}  ${C_GREEN}%s${C_RED}%s${C_MAGENTA}%s${C_DIM}%s${C_RESET}\n" "$us_bar" "$sy_bar" "$ni_bar" "$(head -c 30 /dev/zero | tr '\0' '.')"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
}

print_job_section() {
    local name="$1"
    local conf_file="${CONF_DIR}/${name}.conf"

    if [ ! -f "$conf_file" ]; then
        echo -e "${C_RED}  [${name}] config not found${C_RESET}"
        return
    fi

    # shellcheck source=/dev/null
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
    processes=$(get_job_processes "$PROCESS_PATTERN" "$NICE_TARGET")

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

            # nice 值颜色
            local nice_color="$C_RESET"
            if [ "$p_nice" -ge "$NICE_TARGET" ] 2>/dev/null; then
                nice_color="$C_GREEN"
            else
                nice_color="$C_RED"
            fi

            # 截断命令
            p_cmd=$(echo "$p_cmd" | cut -c1-40)

            printf "${C_BOLD}│${C_RESET}  %-8s ${nice_color}%5s${C_RESET} %6s %6s %-5s %-8s %s\n" \
                "$p_pid" "$p_nice" "$p_cpu" "$p_mem" "$p_stat" "$p_time" "$p_cmd"
        done <<< "$processes"
    fi
    echo -e "${C_BOLD}└─────────────────────────────────────────────────────────────────────${C_RESET}"
}

print_footer() {
    echo ""
    echo -e "  ${C_DIM}Refresh: ${INTERVAL}s  |  q: quit  |  r: refresh now  |  +/-: adjust interval${C_RESET}"
}

# ── 主循环 ──────────────────────────────────────────────────
trap 'echo -e "\n${C_GREEN}Monitor stopped.${C_RESET}"; exit 0' INT TERM

while true; do
    clear
    print_header

    for job_name in "${JOB_NAMES[@]}"; do
        print_job_section "$job_name"
    done

    print_footer

    # 带超时的读取（允许用户按键）
    read -r -t "$INTERVAL" -n 1 key 2>/dev/null || true
    case "${key:-}" in
        q) echo -e "\n${C_GREEN}Monitor stopped.${C_RESET}"; exit 0 ;;
        r) continue ;;
        +) INTERVAL=$(( INTERVAL + 1 )); [ "$INTERVAL" -gt 30 ] && INTERVAL=30 ;;
        -) INTERVAL=$(( INTERVAL - 1 )); [ "$INTERVAL" -lt 1 ] && INTERVAL=1 ;;
    esac
done
