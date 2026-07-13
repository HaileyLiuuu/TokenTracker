# AIUsageBar

一个原生 macOS 菜单栏工具，把 Codex 和 Claude Code 的用量放到随时可见的位置。

## 当前测试版

- 菜单栏显示主服务的精简进度条与已用百分比。
- 鼠标悬停或点击菜单栏项目后，展开完整面板。
- 面板同时显示 Codex 和 Claude Code 的剩余百分比、下次重置时间及本机 7 天 Token。
- 可选择 Codex 或 Claude Code 作为主显示项。
- 可在中文和英文之间切换。
- 每 5 分钟自动刷新，也可以手动刷新。

## 数据来源

- **Codex 配额**：通过本机 Codex CLI 自带的 `app-server` 读取，与 Codex 的 account rate-limit 数据同源。
- **Claude Code 配额**：读取 macOS Keychain 中现有的 `Claude Code-credentials` 登录态，并请求 Claude Code 自身使用的 usage 接口。应用不会保存令牌。
- **Token**：从 `~/.codex` 和 `~/.claude` 的本机 JSONL 日志统计，并明确标为“本机 7 天 Token”；它不是跨设备的官方账户 Token 总量。

如果 Claude Code 显示“请先在 Claude Code 中重新登录”，请在终端运行 `claude`，使用 `/login` 完成登录，再回到 AIUsageBar 点击“立即刷新”。首次读取 Claude Code 登录态时，macOS 可能弹出钥匙串授权提示。

## 构建和运行

要求：macOS 14+、Swift 6.2+、已安装 Codex CLI；Claude Code 为可选，但未安装或未登录时会显示不可用状态。

```bash
./scripts/run-app.sh
```

生成的测试应用位于：

```text
dist/AIUsageBar.app
```

核心测试：

```bash
swift run AIUsageBarCoreTests
```

包含真实 Codex app-server 的集成测试：

```bash
AIUSAGEBAR_LIVE_TESTS=1 swift run AIUsageBarCoreTests
```

## 发布前待办

当前版本采用本地 ad-hoc 签名，适合本人测试。发布 GitHub 前需要确定开源许可证，并完成 Developer ID 签名、notarization、版本化安装包及隐私说明。
