# QNote 内置免费模型网关

把本机 magpie 的 `group/qnote` 包装成 App 内置的「小Q 内置服务」：

- App 只认识公开别名 `qnote-free`，真实模型名与 magpie Key 都留在本机；
- 只放行 `/v1/models`、`/v1/chat/completions`、`/v1/images/generations`；
- 按安装 ID / IP 做小时与天级配额，超限返回 429；
- 远程配置放仓库 `builtin-config` 分支，隧道 URL 变化时自动发布。

## 快速开始

```bash
# 前置：magpie 在 3425 监听，且已开启 Share on local network
bash tools/builtin_gateway/start.sh

# 查看状态
bash tools/builtin_gateway/status.sh

# 只重新发布配置（URL 未变也可以强制 +1）
bash tools/builtin_gateway/publish.sh

# 停止
bash tools/builtin_gateway/stop.sh
```

首次运行会生成：

- `~/.config/qnote-tunnel/gateway.json`（真实网关配置，`chmod 600`）
- `~/.config/qnote-tunnel/publish.env`（客户端 secret / 最低版本）
- `~/.config/qnote-tunnel/url.txt`（当前公网地址）

## 目录

| 文件 | 说明 |
|---|---|
| `server.js` | 网关：别名映射、配额、签名、SSE 脱敏、CORS |
| `publish.js` | 生成签名配置并用 git plumbing 推 `builtin-config` 分支 |
| `start.sh` | 预检 → 网关 → 隧道 → 自动发布 |
| `publish.sh` | 重新发布配置 |
| `stop.sh` | 停止网关与隧道 |
| `status.sh` | 进程、地址、健康、双端源、配额 |
| `config.example.json` | 配置模板 |

## 网关配置

```json
{
  "listen": "127.0.0.1:3426",
  "upstream": "http://127.0.0.1:3425",
  "requireSignature": false,
  "appSecrets": ["<本地 secret>"],
  "models": {
    "qnote-free": {
      "upstream": "group/qnote",
      "displayName": "小Q 免费模型",
      "contextWindow": 1048576,
      "vision": true,
      "type": "chat",
      "enabled": true
    },
    "qnote-image-free": {
      "upstream": "group/qnote-image",
      "displayName": "小Q 免费生图",
      "type": "image",
      "enabled": false
    }
  },
  "quotas": {
    "device": { "perHour": 30, "perDay": 300, "tokensPerDay": 3000000 },
    "ip": { "perHour": 60, "perDay": 600 },
    "global": { "perDay": 0, "tokensPerDay": 0 },
    "imageDevice": { "perDay": 3 },
    "maxTokensPerRequest": 4096,
    "maxBodyBytes": 1048576
  },
  "maintenance": { "enabled": false, "message": "" }
}
```

- `global` 为 0 表示不限；需要时改成具体数字。
- `imageDevice` 是生图独立桶，`qnote-image-free` 就绪后把 `enabled` 翻真。
- `requireSignature` 内测默认 `false`：App 不注入 secret 也能用，配额仍按安装 ID
  统计。要开启时设 `true`，并在构建 App 时加
  `--dart-define=QNOTE_BUILTIN_APP_SECRET=<publish.env 里的值>`。

## 远程配置

配置在仓库 `builtin-config` 分支的 `qnote_builtin.json`，不写 main、不触发 CI。
App 的候选源顺序：

1. Gitee Contents API（国内主源，base64 包装）
2. jsDelivr
3. GitHub raw（Fastly 缓存可能滞后几分钟）
4. ghfast 镜像

> Gitee 的 `raw` 对非默认分支实测会 404，所以国内主源用 Contents API，
> 不要改回 raw。

## 端点和保护

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 健康检查 |
| GET | `/v1/models` | 只返回已启用别名，绝不暴露 magpie 全量目录 |
| POST | `/v1/chat/completions` | 强制映射到 `group/qnote` |
| POST | `/v1/images/generations` | 生图就绪后映射到 `group/qnote-image` |
| 其他 | `*` | 404 |

- 客户端 `Authorization` 一律丢弃，换成 magpie `lanKey`；
- JSON / SSE 里的 `model` 字段改写回公开别名；
- 上游错误详情只写本地日志，客户端只看到通用文案；
- 只记录元数据（安装 ID 哈希、模型、tokens、延迟、状态），不记录 prompt。

## 安全边界

客户端 secret 会随 App 分发，**不是真正的密钥**。真正的防线是：

1. 按安装 ID / IP 的配额；
2. 模型别名白名单；
3. 全局维护开关；
4. 用量日志与异常排查。

不要把它当成「付费 API 的访问控制」。公开分发前请评估上游 ToS 与国内
生成式 AI 服务备案要求。

## 故障排查

见 `.agents/skills/qnote-builtin-service/SKILL.md` 的「常见故障」。
