---
name: add-new-model
description: 向 pi 添加/接入新的模型（新发布的模型在 /model、/scoped-models 或 --list-models 中不可见时）。使用场景：模型服务商发布了新模型但 pi 模型列表里没有、想手动接入自定义模型或兼容端点。核心结论：pi 内置 provider 的模型列表来自远端目录（本地 4 小时缓存），新模型未收录时不会自动出现，需在 ~/.pi/agent/models.json 手动注册；修改后打开 /model 即生效，无需重启。
compatibility: pi >= 0.84（远端模型目录机制）；bash/curl
---

# add-new-model — 向 pi 添加新模型

## 结论速览

1. **模型列表来源分三层**：内置 provider 模型来自远端目录（`pi.dev`，本地缓存 `~/.pi/agent/models-store.json`，etag 校验、约 4 小时刷新一次）；本地 `~/.pi/agent/models.json` 做覆盖/追加；扩展可注册 provider。**新模型不会自动出现**——远端目录未收录时，本地怎么刷新都不会有。
2. `/login` 只存凭据，`/scoped-models` 只是"启用哪些模型"的白名单选择器，两者都不会产生新模型条目。
3. **标准做法**：在 `~/.pi/agent/models.json` 的对应 provider 下加 `models` 数组（合并语义：内置模型保留、同名按 id 覆盖、新 id 追加），保存后重新打开 `/model` 即生效（无需重启）。
4. 动手前先收集官方参数（模型 id、上下文窗口、最大输出、输入模态、是否支持思考、定价），并用已有凭据实测接口可用性。

## 背景

- pi 内置 provider（各家模型服务商）的模型目录由远端 catalog 下发：`https://pi.dev/api/models/providers/<provider-id>`，本地 `~/.pi/agent/models-store.json` 缓存（含 `checkedAt`/`lastModified`/`etag`），刷新间隔约 4 小时、4 秒超时。
- 模型服务商发布新模型后，远端目录的收录存在**滞后**；目录未收录前，`/model`、`/scoped-models`、`pi --list-models` 都看不到。
- 远端目录收录后，本地缓存最多滞后 4 小时（带 etag 的 304 校验，远端更新后下次刷新即拉到）。

## 实施步骤

### 1. 确认现状

```bash
# 列出当前全部可用模型，确认新模型确实缺失
pi --list-models | grep <provider>            # 或直接全量看

# 查远端目录是否已收录（本机在中国境内，境外访问先 proxyon 确认代理）
curl -s "https://pi.dev/api/models/providers/<provider-id>" | python3 -m json.tool

# 看本地缓存（确认缓存内容与远端是否一致）
python3 -c "import json; d=json.load(open('$HOME/.pi/agent/models-store.json')); print(list(d.keys()))"
```

- 远端目录**已收录** → 等本地缓存刷新（4 小时内）即可，无需任何配置。
- 远端目录**未收录** → 走第 2~4 步手动注册。

### 2. 收集官方参数

从模型服务商官方文档/定价页/API 的 `/models` 列表获取：

| 参数 | 来源 | 说明 |
|---|---|---|
| 模型 id | 官方 API `/models` 列表或文档 | 请求体里实际传的 id，必须与上游一致 |
| 上下文窗口 / 最大输出 | 官方文档 | `contextWindow`、`maxTokens`（token 数） |
| 输入模态 | 官方文档 | 仅文本 `["text"]`；支持图片加 `"image"` |
| 是否支持思考 | 文档或实测 | `reasoning`；思考档位用 `thinkingLevelMap` 映射 |
| 定价 | 官方定价页 | 每百万 token 的输入/输出/缓存价格；注意促销价与标准价 |
| API 兼容性 | 官方文档 | OpenAI 兼容即 `openai-completions`；注意是否支持 `developer` role、`reasoning_effort` 等 |

> 同一 provider 下其他已收录模型的远端目录条目是**最佳参数模板**（baseUrl、compat、thinkingLevelMap 都可参照）。

### 3. 写入 models.json

```json
{
  "providers": {
    "<provider-id>": {
      "models": [
        {
          "id": "<model-id>",
          "name": "显示名（可选，默认同 id）",
          "reasoning": true,
          "thinkingLevelMap": { "low": "low", "high": "high", "max": "max", "off": null },
          "input": ["text", "image"],
          "contextWindow": 1000000,
          "maxTokens": 131072,
          "cost": { "input": 0.5, "output": 1.5, "cacheRead": 0.1, "cacheWrite": 0 },
          "compat": {
            "supportsDeveloperRole": false,
            "supportsReasoningEffort": true,
            "maxTokensField": "max_tokens"
          }
        }
      ]
    }
  }
}
```

- `baseUrl`/`api` 继承 provider 内置值，一般无需写；自定义 provider（非内置）则必须写 `baseUrl` 和 `api`。
- `apiKey` 不需要：`auth.json` 已有该 provider 凭据即用；没有则需先 `/login`（或配置 provider 级 `apiKey`）。
- 合并语义：内置模型保留、自定义模型按 id upsert、新 id 追加。只加新模型不影响其他模型。
- 完整字段说明见 pi 官方文档 `docs/models.md`（model 配置表）与 `docs/custom-provider.md`。

### 4. 实测验证接口可用性

用已有凭据发最小请求，确认模型 id 正确、返回结构与 pi 期望兼容（OpenAI 兼容端点看是否返回 `choices`/`usage`；支持思考的模型看 `reasoning_content` 等字段）：

```bash
curl -s "<baseUrl>/chat/completions" \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"hi"}],"max_tokens":10}'
```

### 5. 生效与确认

```bash
pi --list-models | grep <provider>   # 确认新模型出现
```

- `models.json` **每次打开 /model 时重新加载**，会话内修改后重新打开即可，无需重启、无需 /reload。
- 在 `/model` 中选择新模型（或 `/scoped-models` 勾选启用）即可使用。

## 注意事项

- **兼容性坑**：OpenAI 兼容端点若报错，优先检查 provider/model 级 `compat`——不支持 `developer` role 设 `supportsDeveloperRole: false`（改发 system）、不支持 `reasoning_effort` 设 `supportsReasoningEffort: false`、旧端点用 `max_tokens` 字段设 `maxTokensField`。思考格式特殊（非 OpenAI 标准）的 provider 需 `thinkingFormat`（如 zai/qwen/deepseek 等，见官方文档）。
- **定价会变**：促销价、标准价、缓存价要按官方最新定价填写；`cost` 只用于费用统计，不影响请求本身。
- **上游收录后可清理**：远端目录收录该模型后，models.json 中对应条目可删除（内置目录接管）；若想长期覆盖某些参数（如 contextWindow、定价），保留即可。
- **多模型场景**：`modelOverrides` 只能覆盖**已存在**的模型（未知 id 会被忽略），新增模型必须用 `models` 数组。
- **网络**：`pi.dev` 及模型服务商接口属境外访问，本机（中国境内）先 `proxyon` 确认代理再排查超时/失败。
- **敏感信息**：API key 只放 `auth.json`（/login 生成）或环境变量，不要写进 models.json 字面量。
