# pi-dotfiles

pi agent 自定义配置仓库（pi package + dotfiles 辅助文件），用于在多个终端间手动同步 pi 的自定义改动（扩展 / skills / 主题 / 提示词模板 / 全局设置）。

## 仓库结构

```
pi-dotfiles/
├── package.json          # pi package 清单：extensions + skills（含 js-tiktoken 依赖）
├── extensions/           # 扩展（package 资源）
│   └── footer-custom.ts  #   footer 自定义：费用人民币/美元 + tok/s 输出速率（命令 /footer）
├── skills/               # skills（package 资源）
│   └── pi-hacks/         #   pi 自身改造索引 skill（SKILL.md + 各改造项文档，相对路径引用）
├── agent/                # 非 package 资源，经 sync.sh 复制到 ~/.pi/agent/
│   ├── AGENTS.md         #   pi agent 全局总览
│   └── settings.json     #   全局设置（theme / defaultProvider / defaultModel / thinking）
└── sync.sh               # 一键同步 agent/ 下文件到 ~/.pi/agent/
```

## 安装（新终端）

```bash
# 1. 安装 package 资源（扩展、skills），依赖自动 npm install
pi install git:github.com/hatanokokoroyo/pi-dotfiles

# 2. 同步非 package 文件（AGENTS.md、settings.json）
git clone git@github.com:hatanokokoroyo/pi-dotfiles.git ~/pi-dotfiles
~/pi-dotfiles/sync.sh

# 3. /reload 或重启 pi 生效
```

## 更新（已有终端）

```bash
# package 资源更新：修改并 push 到 GitHub 后，各终端拉取
pi update --extensions

# 非 package 文件更新
cd ~/pi-dotfiles && git pull && ./sync.sh
```

## 说明与注意事项

- `settings.json` 同步后，新终端需自行配置对应 provider 凭据（`auth.json` / 环境变量），模型相关文件不入库。
- **不入库（机器相关）**：`~/.pi/agent/auth.json`、`models-store.json`、`trust.json`、`footer-state.json`、`sessions/`、`npm/`（包依赖，由 `pi update` 自动重装）。
- 新改动流程：改 `~/pi-dotfiles/` → push → 各终端 `pi update --extensions`（package 资源）或 `git pull && ./sync.sh`（agent/ 文件）。
- pi 版本升级后，先对照 `footer-customization.md` 记录的版本号 diff 内置源码，再决定是否同步修改扩展。
