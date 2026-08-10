# 本机 pi agent 总览

- 对 pi 自身的自定义改造（footer 显示、主题、快捷键、扩展、模型配置等）由 pi-dotfiles 仓库统一管理：源码在 `~/pi-dotfiles/`（pi package：`extensions/` + `skills/pi-hacks/`），索引见 skill `pi-hacks`（文档为 skill 目录下的 `footer-customization.md` 等）。
- 本机通过 `pi install git:github.com/hatanokokoroyo/pi-dotfiles` 安装该 package；修改仓库内容后 push，各终端执行 `pi update --extensions` 同步。
- 同步改动时使用固定 git 提交身份：`hatanokokoro <hatanokokoroyo@gmail.com>`（仓库 local 已配置；其他终端 clone 后如未继承需手动 `git config user.name/user.email`）。
- 非 package 文件（本文件 `AGENTS.md`、`settings.json`）经仓库 `agent/` 目录同步：`~/pi-dotfiles/sync.sh` 复制到 `~/.pi/agent/`。
- 已安装扩展：`footer-custom.ts`（自定义 footer：费用人民币/美元显示 + AI 输出速率 tok/s，命令 `/footer`，详情见 pi-hacks skill 的 `footer-customization.md`）。
- 机器相关、不入库的文件：`~/.pi/agent/auth.json`、`models-store.json`、`trust.json`、`footer-state.json`、`sessions/`。
