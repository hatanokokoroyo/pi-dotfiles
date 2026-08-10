---
name: pi-hacks
description: pi agent 自身的自定义与改造知识索引（footer 显示、主题、快捷键、扩展开发、模型/Provider 配置等）。使用场景：用户提出修改 pi 自身行为或界面（如自定义 footer 显示、改主题、写扩展、调整模型配置）时，先读本 skill 的改造索引，再按需读取本目录下对应文档；新增改造时先看"登记新改造"一节。
---

# pi 改造索引（pi-hacks）

本 skill 是"pi 自身改造"的统一入口。所有对 pi agent 的元层自定义（不是用 pi 做业务任务，而是改 pi 本身）都在此登记。

> 本文档与各改造项文档位于同一目录（package 内 `skills/pi-hacks/`），引用一律使用相对路径；本机安装后对应 `~/.pi/agent/skills/pi-hacks/`（直接文件方式）或 pi package 的 `skills/pi-hacks/`（package 安装方式）。

## 改造索引

| 改造项 | 触发场景 | 文档 | 状态 |
| --- | --- | --- | --- |
| footer 自定义（费用人民币 + tok/s 速率） | 改底部 footer 显示（费用单位/统计项/布局/输出速率） | `footer-customization.md`（本目录） | ✅ 已落地（扩展 `extensions/footer-custom.ts`，命令 `/footer`） |

## 使用方式

1. 从上方索引找到对应改造项，读取其文档获取完整知识（结论速览 / 实现细节 / 数据源 / 修改点 / 注意事项）。文档即本目录下的同名 Markdown 文件。
2. 修改已有扩展后执行 `/reload` 验证；源码改动提交到 pi-dotfiles 仓库并 push（提交身份 `hatanokokoro <hatanokokoroyo@gmail.com>`），各终端 `pi update --extensions` 同步。
3. 扩展统一由 pi-dotfiles package 管理（仓库 `extensions/` 目录）；全局生效，与项目无关的改造不要放进项目仓库（`.pi/extensions/` 仅临时/项目级用）。

## 登记新改造

新增对 pi 的改造时，按以下流程（保持 skill 数量不变，列表不膨胀）：

1. 在本目录（skill 目录，package 内 `skills/pi-hacks/`）新建 `<改造项>.md`，参照既有文档结构：结论速览 → 背景 → 实现（含数据源/源码位置）→ 验证 → 修改点 → 注意事项；开头记录 pi 版本号。改动后 push 到 pi-dotfiles 仓库，各终端 `pi update --extensions` 同步。
2. 在本文件索引表追加一行（改造项 | 触发场景 | 文档 | 状态）。
3. 若改动影响会话行为，同步检查 `~/.pi/agent/AGENTS.md` 是否需要更新总览。

## 原则

- **触发精准**：本 skill 的 description 只覆盖"pi 自身改造"，业务能力（如 codegraph、chrome-devtools）由各自独立 skill 承担，不要合并。
- **渐进式披露**：索引只写一行摘要，细节全部在 pi-hacks/ 文档中按需读取。
- **版本可追溯**：每篇文档记录 pi 版本，升级后先 diff 相关内置源码再判断是否需要同步。
- **敏感信息**：密码/密钥不入档（与项目仓库约定一致）。
