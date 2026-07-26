# luci-app-homeproxy

The modern ImmortalWrt proxy platform for ARM64/AMD64, based on sing-box.

## 修改记录 (Fork Changes)

### sing-box v1.13.14 兼容性修复

- **sniff 字段迁移**：4 个入站（mixed / redirect / tproxy / tun）中删除已废弃的 `sniff` 和 `sniff_override_destination` 字段（自 sing-box 1.12.0 起已移除），改为在路由规则中启用 `action: sniff`
- **`default_domain_resolver` 格式修正**：两处 `route.default_domain_resolver` 中删除多余的 `action: 'route'` / `action: 'resolve'` 字段（根据 sing-box 拨号字段文档，`domain_resolver` 不应包含 `action` 字段）
- **死代码清理**：移除不再使用的 `sniff_override` 变量声明及赋值

### Bug 修复

- **ACME 选项布尔判断**（`generate_server.uc`）：`disable_tls_alpn_challenge` 字段直接使用原始字符串值判断，导致用户设为 `'0'` 时仍为 true；已改用 `strToBool()` 正确处理
- **路由模式拼写错误**（`update_subscriptions.uc`）：默认路由模式 `bypass_mainalnd_china` 缺少字母 `l`，导致订阅更新脚本在不设置 routing_mode 时使用错误默认值；已修正为 `bypass_mainland_china`

###替换sing-box更新源
原脚本上游更新源部分分流规则更新不及时，导致分流错误。替换活跃规则集更新源
<img width="1190" height="148" alt="image" src="https://github.com/user-attachments/assets/476ccfc8-33da-40a7-8e3a-91502c5c427c" />

