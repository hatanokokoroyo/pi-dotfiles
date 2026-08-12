# pi-dotfiles

pi agent 自定义配置仓库（纯 pi package：扩展 + skills），用于在多个终端间同步 pi 的自定义改动。

## 仓库结构

```
pi-dotfiles/
├── package.json          # pi package 清单：extensions + skills（含 js-tiktoken 依赖）
├── extensions/           # 扩展（package 资源）
│   └── footer-custom.ts  #   footer 自定义：费用人民币/美元 + tok/s 输出速率（命令 /footer）
├── skills/               # skills（package 资源）
│   └── pi-hacks/         #   pi 自身改造索引 skill（SKILL.md + 各改造项文档，含同步机制说明）
└── setup.sh              # 新终端一键安装：npm install + pi install 本目录
```

## 安装（新终端）

所有终端采用 **local path 安装**：工作副本即包源，pi 不维护第二份克隆。

```bash
git clone git@github.com:hatanokokoroyo/pi-dotfiles.git ~/.pi/pi-dotfiles
~/.pi/pi-dotfiles/setup.sh      # npm install（js-tiktoken）+ pi install ~/.pi/pi-dotfiles
```

`/reload` 或重启 pi 生效。

## 日常开发（任意终端）

```bash
# 扩展：改 ~/.pi/pi-dotfiles/extensions/xxx.ts → /reload 立即生效 → 测试 → commit → push
# skill：改 ~/.pi/pi-dotfiles/skills/xxx/ → 下个会话自动读盘 → commit → push
```

## 跨终端同步

```bash
cd ~/.pi/pi-dotfiles && git pull   # 拉取最新
# 扩展改动：/reload 生效；skill 改动：下个会话生效
# 若 package.json 依赖有变：npm install
```

`pi update --extensions` 对 local 包无操作，更新天然靠 `git pull`。

## git 提交身份

提交身份约定 `hatanokokoro <hatanokokoroyo@gmail.com>`（仓库 local 已配置；新 clone 未继承则手动配置）：

```bash
cd ~/.pi/pi-dotfiles
git config user.name "hatanokokoro"
git config user.email "hatanokokoroyo@gmail.com"
```

## 说明与注意事项

- `AGENTS.md`（`~/.pi/agent/AGENTS.md`）与 `settings.json` **不入库、不同步**，各终端自维护；机制说明见 pi-hacks skill。
- 新终端 `settings.json` 需自行配置（theme / defaultProvider / defaultModel / defaultThinkingLevel / enabledModels），provider 凭据在 `auth.json`。
- **不入库（机器相关）**：`~/.pi/agent/auth.json`、`models-store.json`、`trust.json`、`footer-state.json`、`sessions/`。
- 改动流程：改 `~/.pi/pi-dotfiles/` → 本机 `/reload` 验证 → commit + push → 其他终端 `git pull`。
- pi 版本升级后，先对照 `footer-customization.md` 记录的版本号 diff 内置源码，再决定是否同步修改扩展。
