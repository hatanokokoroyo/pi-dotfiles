#!/usr/bin/env bash
# daemon — 通用后台服务管理工具（tmux 底座）
#
# 每个服务对应一个命名 tmux 会话（daemon-<name>），会话名即服务身份，天然免疫 PID 复用；
# 进程随 tmux server 存活，脱离调用方 shell；机器重启后需重新 daemon start。
#
# 服务注册表: ~/.config/daemon/registry（TSV: name \t 命令 \t 工作目录 \t 日志文件），
# 可用环境变量 DAEMON_REGISTRY 覆盖。
#
# 用法:
#   daemon add <name> <cmd> [cwd] [logfile]   注册服务
#   daemon rm <name>                          移除注册（并结束其会话）
#   daemon start <name>                       启动（幂等；自动清理上次退出的旧会话）
#   daemon stop <name>                        优雅停止（Ctrl-C，超时强制）
#   daemon restart <name>                     重启
#   daemon status [name]                      单个服务详情 / 全部列表
#   daemon log <name> [N]                     最近 N 行输出（默认 50）
#   daemon attach <name>                      交互查看（仅人用，需要 tty）
#
# 设计要点:
#   - 经 new-session 直接运行命令（非交互 shell，无提示符污染），命令以 exec 方式
#     运行于 pane，pane_pid 即服务真实 PID；命令中的 $VAR 由 pane 的 shell 在启动时展开
#   - remain-on-exit 在 pane 内先设置再 exec（避免瞬间退出竞态）: 服务退出后会话保留，
#     退出输出仍可查（daemon status/log）
#   - 日志文件可选；配置后经 pipe-pane 落盘，退出后 daemon log 依然可用

set -u

DAEMON_PREFIX="daemon-"
REGISTRY="${DAEMON_REGISTRY:-$HOME/.config/daemon/registry}"

die() { echo "daemon: $*" >&2; exit 1; }

sess_name() { echo "${DAEMON_PREFIX}$1"; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]; }

require_tmux() {
    command -v tmux >/dev/null 2>&1 || die "tmux 未安装"
}

# 输出注册表全部有效行: name \t cmd \t cwd \t log
load_registry() {
    [ -f "$REGISTRY" ] || return 0
    local n c w l
    while IFS=$'\t' read -r n c w l; do
        case "$n" in ""|\#*) continue ;; esac
        [ -n "$c" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$n" "$c" "$w" "$l"
    done < "$REGISTRY"
}

# 按名字查找，命中时设置 DAEMON_NAME/DAEMON_CMD/DAEMON_CWD/DAEMON_LOG
find_service() {
    local want="$1" n c w l
    while IFS=$'\t' read -r n c w l; do
        if [ "$n" = "$want" ]; then
            DAEMON_NAME="$n"; DAEMON_CMD="$c"; DAEMON_CWD="$w"; DAEMON_LOG="$l"
            return 0
        fi
    done < <(load_registry)
    return 1
}

# 运行中 = 会话存在 且 pane 未死
is_running() {
    local s; s=$(sess_name "$1")
    tmux has-session -t "$s" 2>/dev/null || return 1
    local dead
    dead=$(tmux display-message -p -t "$s" '#{pane_dead}' 2>/dev/null)
    [ "$dead" = "0" ]
}

usage() {
    cat <<EOF
daemon — 通用后台服务管理工具 (tmux 底座)

用法: daemon <命令> [参数]
  add <name> <cmd> [cwd] [logfile]   注册服务
  rm <name>                          移除注册
  start <name>                       启动（幂等）
  stop <name>                        优雅停止
  restart <name>                     重启
  status [name]                      全部列表 / 单个详情
  log <name> [N]                     最近 N 行输出（默认 50）
  attach <name>                      交互查看（需 tty）

注册表: $REGISTRY
EOF
    exit 0
}

cmd_add() {
    [ $# -ge 2 ] || die "用法: daemon add <name> <命令> [工作目录] [日志文件]"
    local name="$1" cmd="$2" cwd="${3:-}" log="${4:-}"
    valid_name "$name" || die "非法服务名: $name（仅允许字母数字 _ . -）"
    case "$cmd" in *$'\t'*) die "命令中不能包含制表符";; esac
    find_service "$name" >/dev/null 2>&1 && die "服务 $name 已存在，编辑 $REGISTRY 修改"
    mkdir -p "$(dirname "$REGISTRY")"
    printf '%s\t%s\t%s\t%s\n' "$name" "$cmd" "$cwd" "$log" >> "$REGISTRY"
    echo "daemon: 已注册 $name -> $cmd"
    [ -n "$log" ] && mkdir -p "$(dirname "$log")" 2>/dev/null || true
}

cmd_rm() {
    [ $# -ge 1 ] || die "用法: daemon rm <name>"
    local name="$1"
    find_service "$name" >/dev/null 2>&1 || die "未注册的服务: $name"
    local sname; sname=$(sess_name "$name")
    tmux has-session -t "$sname" 2>/dev/null && tmux kill-session -t "$sname"
    local tmp; tmp=$(mktemp)
    awk -F '\t' -v n="$name" '$1 != n' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
    echo "daemon: 已移除 $name"
}

cmd_start() {
    [ $# -ge 1 ] || die "用法: daemon start <name>"
    local name="$1"
    find_service "$name" >/dev/null 2>&1 || die "未注册的服务: $name（先 daemon add）"
    require_tmux
    local sname; sname=$(sess_name "$name")
    if tmux has-session -t "$sname" 2>/dev/null; then
        if is_running "$name"; then
            echo "daemon: $name 已在运行 (会话 $sname)"
            return 0
        fi
        echo "daemon: $name 上次已退出，清理旧会话"
        tmux kill-session -t "$sname"
    fi
    # 非交互 shell 直接运行；在 pane 内先设 remain-on-exit 再 exec，保证瞬间退出也可诊断
    tmux new-session -d -s "$sname" -c "${DAEMON_CWD:-$HOME}" \
        "tmux set-window-option -t $sname remain-on-exit on; exec $DAEMON_CMD" || die "创建会话失败"
    tmux set-window-option -t "$sname" history-limit 10000 2>/dev/null
    if [ -n "$DAEMON_LOG" ]; then
        tmux pipe-pane -o -t "$sname" "cat >> '$DAEMON_LOG'" 2>/dev/null
    fi
    sleep 1
    if is_running "$name"; then
        echo "daemon: $name 已启动 (会话 $sname)"
        [ -n "$DAEMON_LOG" ] && echo "daemon: 日志文件 $DAEMON_LOG"
        cmd_log "$name" 5
    else
        echo "daemon: $name 启动失败（命令已退出），请查看: daemon log $name" >&2
        cmd_log "$name" 10 >&2 2>/dev/null
        exit 1
    fi
}

cmd_stop() {
    [ $# -ge 1 ] || die "用法: daemon stop <name>"
    local name="$1"
    local sname; sname=$(sess_name "$name")
    if ! tmux has-session -t "$sname" 2>/dev/null; then
        echo "daemon: $name 未在运行"
        return 0
    fi
    if is_running "$name"; then
        tmux send-keys -t "$sname" C-c
        local i
        for i in $(seq 1 10); do
            is_running "$name" || break
            sleep 0.3
        done
    fi
    if tmux has-session -t "$sname" 2>/dev/null; then
        tmux kill-session -t "$sname"
    fi
    if tmux has-session -t "$sname" 2>/dev/null; then
        die "停止失败: 会话 $sname 仍存在"
    fi
    echo "daemon: $name 已停止"
}

cmd_restart() {
    [ $# -ge 1 ] || die "用法: daemon restart <name>"
    cmd_stop "$1"
    sleep 1
    cmd_start "$1"
}

cmd_log() {
    [ $# -ge 1 ] || die "用法: daemon log <name> [N]"
    local name="$1" n="${2:-50}"
    find_service "$name" >/dev/null 2>&1 || die "未注册的服务: $name"
    if [ -n "$DAEMON_LOG" ] && [ -f "$DAEMON_LOG" ]; then
        tail -n "$n" "$DAEMON_LOG"
    elif tmux has-session -t "$(sess_name "$name")" 2>/dev/null; then
        tmux capture-pane -p -t "$(sess_name "$name")" -S -"$n" 2>/dev/null
    else
        echo "daemon: $name 未运行且无日志文件" >&2
        return 1
    fi
}

cmd_status() {
    if [ $# -lt 1 ]; then
        cmd_list
        return 0
    fi
    local name="$1"
    find_service "$name" >/dev/null 2>&1 || die "未注册的服务: $name"
    local sname; sname=$(sess_name "$name")
    if tmux has-session -t "$sname" 2>/dev/null; then
        local dead
        dead=$(tmux display-message -p -t "$sname" '#{pane_dead}' 2>/dev/null)
        if [ "$dead" = "0" ]; then
            echo "服务: $name    状态: 运行中"
        else
            echo "服务: $name    状态: 已退出 (会话保留，可查日志)"
        fi
        if [ "$dead" = "0" ]; then
            local ppid
            ppid=$(tmux display-message -p -t "$sname" '#{pane_pid}' 2>/dev/null)
            [ -n "$ppid" ] && echo "进程 (PID $ppid): $(ps -o args= -p "$ppid" 2>/dev/null | head -1)"
        fi
        echo "--- 最近输出 ---"
        cmd_log "$name" 20
    else
        echo "服务: $name    状态: 已停止"
        echo "启动命令: $DAEMON_CMD   (cwd: ${DAEMON_CWD:-未指定})"
        [ -n "$DAEMON_LOG" ] && echo "日志文件: $DAEMON_LOG"
    fi
}

cmd_list() {
    local n c w l
    printf '%-20s %-10s %s\n' "名称" "状态" "命令"
    while IFS=$'\t' read -r n c w l; do
        local st="已停止"
        is_running "$n" && st="运行中"
        if tmux has-session -t "$(sess_name "$n")" 2>/dev/null && ! is_running "$n"; then
            st="已退出"
        fi
        printf '%-20s %-10s %s\n' "$n" "$st" "${c:0:60}"
    done < <(load_registry)
}

cmd_attach() {
    [ $# -ge 1 ] || die "用法: daemon attach <name>"
    [ -t 0 ] || die "attach 需要交互终端（agent 请用 daemon log）"
    require_tmux
    local name="$1"
    is_running "$name" || die "$name 未在运行"
    tmux attach -t "$(sess_name "$name")"
}

main() {
    local cmd="${1:-help}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        add)      cmd_add "$@" ;;
        rm)       cmd_rm "$@" ;;
        start)    cmd_start "$@" ;;
        stop)     cmd_stop "$@" ;;
        restart)  cmd_restart "$@" ;;
        status|st) cmd_status "$@" ;;
        log)      cmd_log "$@" ;;
        list|ls)  cmd_list ;;
        attach|at) cmd_attach "$@" ;;
        help|-h|--help) usage ;;
        *) usage ;;
    esac
}

main "$@"
