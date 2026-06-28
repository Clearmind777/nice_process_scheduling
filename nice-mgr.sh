#!/bin/bash
#
# nice-mgr.sh — 进程调度作业管理器
#
# 用法:
#   nice-mgr start  <name> --pattern <pgrep-pattern> [--nice 19] [--interval 10] [--desc "..."]
#   nice-mgr stop   <name>
#   nice-mgr kill   <name>
#   nice-mgr status <name>
#   nice-mgr list
#   nice-mgr edit   <name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/tmp"
SERVICE_NAME_PREFIX="nice-scheduler@"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_TEMPLATE="${SCRIPT_DIR}/nice-scheduler@.service"

# ── 颜色 ────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_RED='\033[31m'
C_CYAN='\033[36m'

# ── 辅助函数 ────────────────────────────────────────────────
die() { echo -e "${C_RED}Error:${C_RESET} $*" >&2; exit 1; }
info() { echo -e "${C_GREEN}→${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*"; }

print_usage() {
    cat <<EOF
Usage: nice-mgr <command> [args...]

Commands:
  start  <name> --pattern <pattern> [options]  创建并启动调度作业
  stop   <name>                                停止作业（保留配置）
  kill   <name>                                停止并删除作业
  status <name>                                查看作业状态
  list                                         列出所有作业
  edit   <name>                                编辑作业配置

Start options:
  --pattern <str>    pgrep -f 匹配模式（必需）
  --nice <1-19>      目标 nice 值（默认 19）
  --interval <sec>   扫描间隔秒数（默认 10）
  --desc <str>       作业描述

Examples:
  nice-mgr start jupyter --pattern "ipykernel_launcher" --desc "Jupyter kernel"
  nice-mgr start train   --pattern "runrun_model" --nice 5
  nice-mgr status jupyter
  nice-mgr list
  nice-mgr stop jupyter
  nice-mgr kill jupyter
EOF
}

# ── 参数解析 ────────────────────────────────────────────────
COMMAND="${1:-}"
case "$COMMAND" in
    start|stop|kill|status|list|edit) ;;
    *) print_usage; exit 1 ;;
esac

# ── start ───────────────────────────────────────────────────
cmd_start() {
    local name=""
    local pattern=""
    local nice_target=19
    local interval=10
    local desc=""

    name="$1"; shift

    while [ $# -gt 0 ]; do
        case "$1" in
            --pattern) pattern="$2"; shift 2 ;;
            --nice)    nice_target="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            --desc)    desc="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # 验证
    [ -z "$name" ] && die "job name is required"
    [ -z "$pattern" ] && die "--pattern is required"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "job name must be alphanumeric (a-z, 0-9, _, -)"
    [ "$nice_target" -ge 1 ] 2>/dev/null && [ "$nice_target" -le 19 ] 2>/dev/null \
        || die "--nice must be between 1 and 19"
    [ "$interval" -ge 1 ] 2>/dev/null || die "--interval must be >= 1"

    local conf_file="${CONF_DIR}/${name}.conf"
    if [ -f "$conf_file" ]; then
        warn "job '$name' already exists, overwriting..."
    fi

    # 写入配置
    mkdir -p "$CONF_DIR"
    cat > "$conf_file" <<EOF
# Nice Scheduler Config — $(date '+%Y-%m-%d %H:%M:%S')
PROCESS_PATTERN="${pattern}"
NICE_TARGET=${nice_target}
SCAN_INTERVAL=${interval}
DESCRIPTION="${desc}"
EOF
    info "config written: $conf_file"

    # 安装 systemd 模板
    if [ ! -f "${SYSTEMD_USER_DIR}/nice-scheduler@.service" ]; then
        mkdir -p "$SYSTEMD_USER_DIR"
        cp "$SERVICE_TEMPLATE" "${SYSTEMD_USER_DIR}/nice-scheduler@.service"
        info "service template installed to ${SYSTEMD_USER_DIR}/"
    fi

    # 启用并启动
    systemctl --user daemon-reload
    systemctl --user enable --now "nice-scheduler@${name}.service"

    info "job '$name' started"
    echo ""
    cmd_status "$name"
}

# ── stop ────────────────────────────────────────────────────
cmd_stop() {
    local name="$1"
    [ -z "$name" ] && die "job name is required"
    systemctl --user stop "nice-scheduler@${name}.service" 2>/dev/null || \
        warn "service was not running"
    info "job '$name' stopped (config preserved)"
}

# ── kill ────────────────────────────────────────────────────
cmd_kill() {
    local name="$1"
    [ -z "$name" ] && die "job name is required"

    # 停止并禁用
    systemctl --user disable --now "nice-scheduler@${name}.service" 2>/dev/null || \
        warn "service was not active"

    # 删除配置
    local conf_file="${CONF_DIR}/${name}.conf"
    if [ -f "$conf_file" ]; then
        rm "$conf_file"
        info "config removed: $conf_file"
    fi

    systemctl --user daemon-reload
    info "job '$name' killed"
}

# ── status ──────────────────────────────────────────────────
cmd_status() {
    local name="$1"
    [ -z "$name" ] && die "job name is required"

    local conf_file="${CONF_DIR}/${name}.conf"
    if [ ! -f "$conf_file" ]; then
        die "job '$name' not found (no config at $conf_file)"
    fi

    # 加载配置
    source "$conf_file"

    echo ""
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║  Job: ${C_CYAN}${name}${C_RESET}"
    echo -e "${C_BOLD}╠══════════════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "${C_BOLD}║${C_RESET}  Description:  ${DESCRIPTION:-<none>}"
    echo -e "${C_BOLD}║${C_RESET}  Pattern:      ${PROCESS_PATTERN}"
    echo -e "${C_BOLD}║${C_RESET}  Target nice:  ${NICE_TARGET}"
    echo -e "${C_BOLD}║${C_RESET}  Scan interval: ${SCAN_INTERVAL}s"

    # 服务状态
    local svc_status
    svc_status=$(systemctl --user is-active "nice-scheduler@${name}.service" 2>/dev/null || echo "inactive")
    local svc_symbol
    case "$svc_status" in
        active) svc_symbol="${C_GREEN}● active${C_RESET}" ;;
        inactive) svc_symbol="${C_YELLOW}○ inactive${C_RESET}" ;;
        *) svc_symbol="${C_RED}✗ ${svc_status}${C_RESET}" ;;
    esac
    echo -e "${C_BOLD}║${C_RESET}  Service:      ${svc_symbol}"
    echo -e "${C_BOLD}╠══════════════════════════════════════════════════════════════╣${C_RESET}"

    # 匹配进程
    local matched_pids
    matched_pids=$(pgrep -f "$PROCESS_PATTERN" 2>/dev/null || true)

    if [ -z "$matched_pids" ]; then
        echo -e "${C_BOLD}║${C_RESET}  ${C_YELLOW}No processes matched${C_RESET}"
    else
        printf "${C_BOLD}║${C_RESET}  %-8s %5s %5s %5s %-5s %s\n" "PID" "NICE" "%CPU" "%MEM" "STAT" "COMMAND"
        echo -e "${C_BOLD}║${C_RESET}  ─────────────────────────────────────────────────────"
        for pid in $matched_pids; do
            local p_info
            p_info=$(ps -o pid=,nice=,%cpu=,%mem=,stat=,cmd= -p "$pid" --no-headers 2>/dev/null || echo "")
            if [ -n "$p_info" ]; then
                local p_nice;  p_nice=$(echo "$p_info"  | awk '{print $2}')
                local p_nice_color="$C_RESET"
                if [ "$p_nice" -ge "$NICE_TARGET" ] 2>/dev/null; then
                    p_nice_color="$C_GREEN"
                elif [ "$p_nice" -gt 0 ] 2>/dev/null; then
                    p_nice_color="$C_YELLOW"
                else
                    p_nice_color="$C_RED"
                fi
                printf "${C_BOLD}║${C_RESET}  %-8s ${p_nice_color}%5s${C_RESET} %5s %5s %-5s %s\n" \
                    "$(echo "$p_info" | awk '{print $1}')" \
                    "$p_nice" \
                    "$(echo "$p_info" | awk '{print $3}')" \
                    "$(echo "$p_info" | awk '{print $4}')" \
                    "$(echo "$p_info" | awk '{print $5}')" \
                    "$(echo "$p_info" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | cut -c1-40)"
            fi
        done
    fi
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
}

# ── list ────────────────────────────────────────────────────
cmd_list() {
    echo ""
    echo -e "${C_BOLD}Managed Jobs:${C_RESET}"
    echo ""

    if [ ! -d "$CONF_DIR" ] || [ -z "$(ls -A "$CONF_DIR"/*.conf 2>/dev/null)" ]; then
        echo "  (no jobs configured)"
        echo ""
        echo "  Create one with: nice-mgr start <name> --pattern <pattern>"
        echo ""
        return
    fi

    printf "  %-20s %-12s %6s %-10s %s\n" "NAME" "STATUS" "NICE" "INTERVAL" "PATTERN"
    echo "  ────────────────────────────────────────────────────────────────────────"

    for conf_file in "$CONF_DIR"/*.conf; do
        local name
        name=$(basename "$conf_file" .conf)
        source "$conf_file"

        local svc_status
        svc_status=$(systemctl --user is-active "nice-scheduler@${name}.service" 2>/dev/null || echo "inactive")
        local svc_symbol
        case "$svc_status" in
            active) svc_symbol="${C_GREEN}active${C_RESET}" ;;
            *) svc_symbol="${C_YELLOW}inactive${C_RESET}" ;;
        esac

        printf "  %-20s %-12b %6s %8ss %s\n" \
            "$name" "$svc_symbol" "$NICE_TARGET" "$SCAN_INTERVAL" "$PROCESS_PATTERN"
    done
    echo ""
}

# ── edit ────────────────────────────────────────────────────
cmd_edit() {
    local name="$1"
    [ -z "$name" ] && die "job name is required"

    local conf_file="${CONF_DIR}/${name}.conf"
    if [ ! -f "$conf_file" ]; then
        die "job '$name' not found (no config at $conf_file)"
    fi

    local editor="${EDITOR:-vi}"
    "$editor" "$conf_file"

    # 检查服务是否在运行
    if systemctl --user is-active "nice-scheduler@${name}.service" >/dev/null 2>&1; then
        warn "config changed. Restart service to apply:"
        echo "  systemctl --user restart nice-scheduler@${name}.service"
    fi
}

# ── 分发 ────────────────────────────────────────────────────
case "$COMMAND" in
    start)  shift; cmd_start "$@" ;;
    stop)   shift; cmd_stop "$@" ;;
    kill)   shift; cmd_kill "$@" ;;
    status) shift; cmd_status "$@" ;;
    list)   cmd_list ;;
    edit)   shift; cmd_edit "$@" ;;
esac
