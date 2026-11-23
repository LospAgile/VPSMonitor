# Komari Bot 网络诊断

`diagnostic_service.py` 仅监听 `127.0.0.1:18765/diagnostic`。它每 60 秒并行读取最多两台路由的体检 JSON；每次 SSH 最长 15 秒，输出最多 1 MiB。HTTP 只读取缓存，启动和路由不可达时不会等 SSH。样本校验包含版本、时间、覆盖时长、三态状态、有限指标及唯一探测 ID；失败时保留最后有效样本并明确标为历史。

示例 systemd 单元使用 `komari` 服务账号。部署时按本机已有服务账号调整 `User`、`Group` 与 SSH 配置的读取权限。配置模板见同目录。凭据和实际配置放在仓库外 `/etc/vpsmonitor/`、`/var/lib/vpsmonitor-network/`。推荐为诊断单独生成密钥，只将公钥加入路由的 Dropbear `authorized_keys`，并限制为：

```text
command="cat /tmp/vpsmonitor-network/latest.json",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty <public key>
```

主机密钥必须从已有可信连接固定下来，禁止首次连接自动接受。测试受限凭据时，任意请求命令都应只返回体检 JSON，端口转发应被拒绝。

`provider-augment.js.example` 是现有 Javascript provider 的辅助函数。在既有 `sendEvent(event)` 最后的发送调用中，把原 HTML 文本交给 `await augmentEvent(event, originalHTML)`；其余发送逻辑、凭据、时区和事件格式保留。只增强 `Offline`／`Online`：路由事件选中对应 UUID，VPS 事件附带已配置路由器的状态（最多两台）。HTML 转义、实际观测时长、历史样本、2 秒超时和原通知保留均有测试。

收到部分 ICMP 响应时，缓存使用 `degraded_probes` 保留本轮丢包率，通知显示“部分丢包”；完全失败仍放在 `failed_probes`。SSH 响应探测没有 ICMP 丢包率，不补造为 0%。这些是离线/恢复消息的诊断线索，不会单凭一轮丢包另发设备离线告警。

修改生产 provider 前，将完整原配置备份到仓库外的私有目录，先用拦截全部外发请求的测试验证组合脚本。通过 Komari `admin:setMessageSenderProvider` 热重载后回读比对；失败时恢复原配置。辅助服务停止不会阻断原通知，不需要给公网新增端口，也不把 Telegram 凭据下发到路由。

```bash
python3 -m unittest discover -s network-bot-tools -v
node network-bot-tools/test-provider.mjs
```
