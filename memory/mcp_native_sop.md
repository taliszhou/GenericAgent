---
name: mcp_native_sop
description: "MCP Native Client 标准化操作流程"
version: 1.0.0
author: Hermes Agent (derived from native-mcp SKILL.md)
---

# MCP Native Client SOP

## 概述
基于 `/Users/taliszhou/code/src/github.com/hermes-agent/skills/mcp/native-mcp/SKILL.md` 提取的标准化操作流程。

---

## 一、环境检查

**Step 0.1 - 验证依赖**
```bash
# 1. 检查 Python mcp 包
pip show mcp

# 2. 检查 Node.js（用于 npx）
node --version

# 3. 检查 uv（用于 uvx）
uv --version
```
- ✅ 若 `mcp` 未安装 → 执行 `pip install mcp`
- ✅ 若缺 `npx`/`uvx` → 安装 Node.js/uv

---

## 二、配置 MCP 服务器

**Step 0.2 - 编辑配置文件**
配置文件路径：`$PROJECT_ROOT/configs/config.yaml`
> **注意**：配置文件位于项目目录下的 `configs` 子目录中，格式为 YAML。如果 `configs/config.yaml` 不存在，需要先创建目录和文件。

**自动创建流程：**
```bash
# 1. 检查 configs 目录是否存在
if [ ! -d "$PROJECT_ROOT/configs" ]; then
    mkdir -p "$PROJECT_ROOT/configs"
fi

# 2. 检查 config.yaml 是否存在
if [ ! -f "$PROJECT_ROOT/configs/config.yaml" ]; then
    touch "$PROJECT_ROOT/configs/config.yaml"
    echo "# MCP Servers Configuration" > "$PROJECT_ROOT/configs/config.yaml"
fi
```

### Stdio 传输（本地进程）
```yaml
mcp_servers:
  server_name:
    command: "npx" | "uvx" | "custom_cmd"   # 必填
    args: ["pkg-name", "--option"]           # 可选，默认 []
    env:
      KEY: "value"                           # 可选，只传此变量
    timeout: 120                             # 可选，默认 120s
    connect_timeout: 60                      # 可选，默认 60s
```

### HTTP 传输（远程服务）
```yaml
mcp_servers:
  server_name:
    url: "https://server.example.com/mcp"    # 必填
    headers:
      Authorization: "Bearer sk-..."        # 可选
    timeout: 180                             # 可选，默认 120s
    connect_timeout: 60                      # 可选，默认 60s
```

**⚠️ 关键约束：**
- 每个服务器必须有 `command`（stdio）或 `url`（HTTP），**不能同时存在**
- Server name 不能重复

---

## 三、服务端发现与注册

**Step 0.3 - 重启 Agent**
```bash
# 重启 Hermes Agent 以加载新配置
# 配置文件位于 $PROJECT_ROOT/configs/config.yaml
```

Agent 启动时自动执行 `discover_mcp_tools()`：
1. 读取 `$PROJECT_ROOT/configs/config.yaml` 中的 `mcp_servers`
2. 为每个服务器启动独立后台事件循环
3. 初始化 MCP 会话并调用 `list_tools()`
4. 按命名规则注册到工具注册表

**工具命名规范：**
```
mcp_{server_name}_{tool_name}
```
- `filesystem` → `read_file` → `mcp_filesystem_read_file`
- `github` → `list-issues` → `mcp_github_list_issues`
- 连字符/点号替换为下划线

---

## 四、工具调用

**Step 0.4 - 直接调用**
```python
# MCP 工具注册后，可直接作为普通工具调用
mcp_filesystem_read_file(path="/some/path")
mcp_github_list_issues(owner="org", repo="repo")
mcp_time_get_current_time()
```

**结果格式：**
```json
{"result": "..."}  # 成功
{"error": "..."}   # 失败（凭证件已脱敏）
```

---

## 五、配置采样（Sampling）— 服务器发起 LLM 请求

**Step 0.5 - 启用/配置采样（默认启用）**
```yaml
mcp_servers:
  my_server:
    command: "npx"
    args: ["-y", "my-mcp-server"]
    sampling:
      enabled: true                   # 默认 true
      model: "gemini-3-flash"         # 可选，覆盖默认模型
      max_tokens_cap: 4096            # 可选，每请求最大 token
      timeout: 30                     # 可选，LLM 调用超时
      max_rpm: 10                     # 可选，每分钟最大请求数
      allowed_models: []              # 可选，白名单（空=全部）
      max_tool_rounds: 5              # 可选，工具循环限制（0=禁用）
      log_level: "info"               # 可选，审计级别
```

**采样由 MCP 服务器在工具执行期间主动发起**，实现 agent-in-the-loop 工作流。

---

## 六、安全机制

| 机制 | 说明 |
|------|------|
| **环境变量过滤** | 仅继承安全基础变量（PATH, HOME, USER 等）|
| **手动指定 env** | 密钥必须通过 `env:` 显式传递 |
| **错误消息脱敏** | GitHub PAT (`ghp_...`)、OpenAI 密钥 (`sk-...`)、Bearer token 等自动隐藏 |
| **未信任服务器** | 可设置 `sampling: { enabled: false }` 禁用采样 |

---

## 七、故障排查

| 症状 | 解决 |
|------|------|
| `MCP SDK not available` | 安装 `pip install mcp` |
| `No MCP servers configured` | 在 `$PROJECT_ROOT/configs/config.yaml` 中添加 `mcp_servers` |
| `Failed to connect` | 检查命令是否在 PATH、包是否存在、timeout 是否足够 |
| `HTTP transport not available` | 升级 `pip install --upgrade mcp` |
| 工具未出现 | 确认配置项为 `mcp_servers`（非 `mcp`/`servers`）、缩进正确、查找 `mcp_{server}_{tool}` 格式 |
| 连接持续断开 | 自动重试 5 次（1s→2s→4s→8s→16s，最大 60s），根本不可达则放弃 |

---

## 八、生命周期管理

- MCP 服务器作为后台 `asyncio Task` 长期运行
- 连接在 Agent 进程生命周期内保持持久
- 连接断开 → 指数退避自动重连（最多 5 次）
- Agent 关闭 → 优雅关闭所有连接
- **添加/移除服务器 → 必须重启 Agent（无热重载）**
- `discover_mcp_tools()` 是幂等的

---

**SOP 总结：**
> MCP Native Client 的核心流程是：**安装依赖 → 配置服务器 → 重启 Agent → 自动发现注册 → 直接调用**。采样机制允许服务器主动请求 LLM，增强 agent-in-the-loop 能力。安全方面通过环境变量过滤和凭证实时脱敏保护用户数据。

