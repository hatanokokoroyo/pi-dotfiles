---
name: daemon
description: 管理需要长期运行的进程/后台服务（开发服务器、代理/转发程序、文件 watcher、隧道、mock 服务等）：注册、启动、停止、重启、状态查询、日志查看。使用场景：需要"启动一个持续运行的服务，并在之后重启/确认状态/查看输出"时。基于 tmux 命名会话封装，避免每次 ps/kill/pkill 现场拼命令导致的 PID 竞态与误杀，进程不受父 shell 生命周期影响。命令为 scripts/daemon.sh（可软链为 ~/.local/bin/daemon），服务注册表 ~/.config/daemon/registry。
compatibility: tmux >= 3.2（本机 3.2a）；bash
---

# daemon — 通用后台服务管理

## 概述

agent 在开发中经常需要启动并持续运行某个进程（开发服务器、代理转发、watcher、隧道、mock 服务等），之后还要重启、确认状态、查看输出。若每次用 `ps`/`kill`/`pkill` 现场拼命令，容易踩 PID 复用、`pkill -f` 误杀、进程随父 shell 生命周期退出的坑，且每次都要重新摸索。

`daemon` 把这类管理封装为统一命令（脚本 `scripts/daemon.sh`）。每个服务对应一个命名 tmux 会话（`daemon-<name>`）：

- **会话名即服务身份**，无需 PID 文件，天然免疫 PID 复用
- 进程随 tmux server 存活，**脱离调用方 shell**，无需 nohup/setsid
- 服务退出后会话保留（remain-on-exit），**退出输出仍可查询**，便于排查启动失败
- 日志可选落盘（pipe-pane），服务退出后 `daemon log` 依然可用

## 前置条件

- tmux >= 3.2（`tmux -V` 确认；本机 3.2a）
- 脚本路径：`~/.pi/pi-dotfiles/skills/daemon/scripts/daemon.sh`
- 建议软链 `ln -s ~/.pi/pi-dotfiles/skills/daemon/scripts/daemon.sh ~/.local/bin/daemon`（便于直接敲 `daemon`）

## 快速开始

```bash
# 1. 注册服务（名称 / 启动命令 / 工作目录 / 可选日志文件）
daemon add web "python3 -m http.server 8000" /path/to/project /tmp/daemon-web.log

# 2. 启动（幂等；自动清理上次退出的旧会话）
daemon start web

# 3. 查看状态与输出
daemon status web        # 运行中/已退出 + 真实 PID + 最近输出
daemon log web 100       # 最近 100 行

# 4. 改代码后重启
daemon restart web

# 5. 停止
daemon stop web
```

## 命令速查

| 命令 | 用途 |
| --- | --- |
| `daemon add <name> <cmd> [cwd] [logfile]` | 注册服务（向注册表追加一行） |
| `daemon rm <name>` | 移除注册（同时结束其会话） |
| `daemon start <name>` | 启动（幂等；上次已退出时先清理旧会话） |
| `daemon stop <name>` | 优雅停止：Ctrl-C 发 SIGINT，3 秒未退则强制 kill-session |
| `daemon restart <name>` | 停止 + 启动 |
| `daemon status [name]` | 不带名 = 全部服务列表；带名 = 单服务详情（状态/PID/最近输出） |
| `daemon log <name> [N]` | 最近 N 行输出（默认 50；优先日志文件，否则读会话历史） |
| `daemon attach <name>` | 进入会话交互查看/调试（**仅人用**，需要 tty） |

## 服务注册表

- 位置：`~/.config/daemon/registry`（环境变量 `DAEMON_REGISTRY` 可覆盖）
- 格式：每行一个服务，**制表符**分隔 4 列：`名称<TAB>启动命令<TAB>工作目录<TAB>日志文件`；日志文件可留空；`#` 开头为注释
- 启动命令中的 `$VAR` 等由服务会话里的 shell 在启动时展开（可用 `$PORT` 这类环境变量）
- 工作目录留空则用 `$HOME`；关键服务务必配日志文件（退出后仍可查完整输出）

```bash
# 示例
web	python3 -m http.server 8000	/home/user/proj	/tmp/daemon-web.log
```

## 推荐工作流（agent）

1. **首次**：`daemon add <name> "<启动命令>" <工作目录> <日志文件>`
2. **启动**：`daemon start <name>`；返回中已带最近输出，**视为已读取**，不要重复 tail
3. **改代码后**：`daemon restart <name>`
4. **排查**：进程异常时先 `daemon status <name>`（显示已退出 + 最近输出），再 `daemon log <name> 100` 看完整日志
5. **收尾/切换**：`daemon stop <name>`
6. 需要多个服务同时跑时逐个注册即可；`daemon status`（无参数）一次看全

## 注意事项

- **不要在 bash 里手动 kill/pkill**：用 `daemon stop`（优雅 SIGINT + 超时强制），避免误杀或留下半死进程
- 会话名前缀 `daemon-`，`tmux ls` 可直接观察；不要手工 `tmux kill-session` 绕过 daemon（会造成注册表与状态不一致）
- `attach` 需要交互终端，agent 调用会挂起，**不要用**；看输出用 `log`
- 服务退出后会话保留（remain-on-exit）属设计行为；`daemon start` 会先清理旧会话再起新的
- 机器重启后 tmux server 与所有服务消失，需重新 `daemon start`（开机自启属后续增强，暂不支持）
- 日志经 pipe-pane 落盘：**先 `add` 配好日志再 `start`**；中途改注册表不影响已运行会话
- `add` 只追加不修改；变更命令/目录时直接编辑注册表文件（或 `rm` 后重新 `add`）
