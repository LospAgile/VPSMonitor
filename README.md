# VPSMonitor Proview

VPSMonitor Proview 是一款原生 macOS 菜单栏应用。它连接你自己的 Komari 面板，把节点状态、资源用量和延迟曲线放在菜单栏里。新增服务器时，在 Komari 中接入 Agent 即可，Mac 会自动同步节点。

**运行环境**　macOS 14 或更高版本，支持 Apple 芯片和 Intel 处理器。

**当前版本**　0.7.0（17）。[下载 Apple 芯片原生版（ARM64）](https://github.com/LospAgile/VPSMonitor/releases/download/v0.7.0/VPSMonitor-Proview-0.7.0-macOS-arm64.zip) · [通用版、源码与校验值](https://github.com/LospAgile/VPSMonitor/releases/tag/v0.7.0)

## 首次连接

1. **准备 Komari。** 已有面板的用户，先用浏览器确认能看到自己的节点。首次搭建时，安装 Komari 服务端，再按面板生成的命令为需要监控的服务器安装 Agent。等第一台设备出现在网页上，就可以连接 Mac。[Komari 官方安装指南](https://komari-document.pages.dev/install/quick-start)
2. **安装应用。** 在苹果菜单的“关于本机”查看芯片。Apple M 系列选文件名结尾为 `arm64.zip` 的原生包；Intel 处理器选 `universal.zip`。解压后将 `VPSMonitor Proview.app` 拖入“应用程序”并打开。发布包使用本地临时签名，尚未经过 Apple 公证。也可以按下文从源码构建。
3. **填面板地址。** 第一次启动会打开设置。在“Komari 地址”填面板根地址，例如 `https://komari.example.com`。粘贴前删去末尾的 `/admin` 或 `/api`。建议使用 HTTPS 和单独的域名。
4. **选择访问方式。** 面板允许访客查看时，把所有凭据留空即可。需要登录时，填写 Komari 的 **API Key**，或在“高级认证”使用现有会话。Agent 安装命令里的客户端令牌只供 Agent 上报。[Komari 官方认证说明](https://komari-document.pages.dev/dev/api)
5. 点击“保存”，再点菜单栏的服务器图标。用节点名称和在线数与网页版核对。之后可以用面板右上角的齿轮重新打开设置。

## 面板里能看什么

| 视图 | 内容 |
| --- | --- |
| 菜单栏与概览 | 在线数、内存用量、实时上下行和累计流量。状态过期时显示未知。 |
| 设备 | 列表、小卡片和大卡片。按名称、分组或地区搜索，用“需关注”找到离线、丢包或即将到期的节点。 |
| 延迟 | 读取 Komari 首页绑定的 Ping 任务。卡片展示近 24 小时记录，采样缺口留空。配置三条线路后可以逐线查看。 |
| 套餐 | 读取 Komari 已填写的价格、币种、计费周期和到期日，计算人民币估值与年化费用。 |
| 家庭网络 | 可选。通过 SSH 读取 OpenWrt 采集结果，查看 WAN、DNS 和自定义探测，支持手动备份路由器配置。 |

## 配置文件

用设置窗口保存一次即可生成 `~/.config/komari-swiftbar/config.json`。应用将该文件权限设为 `0600`。凭据保存在本机 JSON 中，可以通过设置窗口更新。

也可以在源码目录执行以下命令，再用文本编辑器填写自己的地址。`cp -n` 会保留已有配置。

```sh
mkdir -p "$HOME/.config/komari-swiftbar"
(umask 077 && cp -n config.example.json "$HOME/.config/komari-swiftbar/config.json")
```

```json
{
  "base_url": "https://komari.example.com",
  "api_key": "",
  "session_token": "",
  "cookie": "",
  "verify_tls": true
}
```

| 字段 | 填写方法 |
| --- | --- |
| `base_url` | Komari 面板的根地址。示例域名仅用于演示，请换成自己的地址。 |
| `api_key` | API Key 认证时填写原始密钥。应用自动添加 `Bearer` 前缀。 |
| `session_token` | 采用会话认证时，填写 `session_token` 的值。 |
| `cookie` | 需要额外 Cookie 时，填写请求头中的 `name=value` 内容。 |
| `verify_tls` | 保留 `true`。当前版本始终使用 macOS 的证书信任设置，此兼容字段不能关闭证书校验。 |

手写 JSON 时请保留全部五个字段，未使用的凭据填空字符串。测试不同面板时，可以用 `VPSMONITOR_CONFIG_PATH` 指定另一份配置的绝对路径。

### 可选的家庭路由

普通 VPS 直接从 Komari 同步。要启用“家庭网络”，先在 OpenWrt 部署采集器，确认路由器已生成 `/tmp/vpsmonitor-network/latest.json`。随后在 Mac 的 SSH 配置中设置可用别名，并通过可信渠道确认主机密钥。应用通过非交互 SSH 读取数据。[采集器与探测配置](router-tools/README.md)

将下例保存为 `~/.config/komari-swiftbar/devices.json`，用路由器在 Komari 中的节点 ID 和本机实际 SSH 别名替换示例。重启应用后打开“家庭网络”。可通过 `VPSMONITOR_DEVICES_PATH` 指定其他映射文件。[设备配置样例](devices.example.json)

```json
{
  "devices": [
    {
      "nodeID": "REPLACE_WITH_ROUTER_NODE_ID",
      "sshAlias": "example-router",
      "router": true
    }
  ]
}
```

选择“备份路由配置到本机”会执行 OpenWrt 的 `sysupgrade -b -`，将结果保存到 `~/Library/Application Support/VPSMonitor/Backups/`。备份可能含有网络凭据，请保存在私人位置。需要让 Komari 的上线、离线通知附带路由诊断时，可另行部署服务端工具。[通知集成说明](network-bot-tools/README.md)

## 连接与排查

客户端从面板读取节点目录和最新状态，通过 WebSocket 接收实时数据。部分节点缺少实时推送时，会通过 HTTP 补取。人民币估值还会单独向 Frankfurter 请求公开的 USD 汇率，该请求只包含基准币种。[Komari 接口文档](https://komari-document.pages.dev/dev/api) · [Frankfurter](https://frankfurter.dev/)

| 遇到的现象 | 检查位置 |
| --- | --- |
| 节点为空，或少了隐藏节点 | 在浏览器以相同身份打开面板。访客可见范围取决于面板设置。使用有效凭据后重新保存。 |
| 连接返回 401 或 403 | 检查面板地址和当前凭据。会话过期时更新会话；切换为访客时清空三个凭据字段。 |
| 能看到节点，实时状态却一直显示轮询 | 反向代理需放行 `POST /api/rpc2` 和 `/api/clients` 的 WebSocket 升级。当前实时连接使用站点根路径。 |
| 没有 24 小时延迟曲线 | 在面板配置首页 Ping 任务绑定，确认 `/api/public` 有对应主题设置，且任务已有历史样本。 |
| 只有资产估值缺项 | 检查节点的价格、币种和计费周期，再查看汇率服务是否可达。 |
| 系统提示无法验证开发者 | 可使用下方命令在本机从源码构建。发布页的 `SHA256SUMS.txt` 可用于核对下载完整性。 |

## 从源码构建

使用包含 **macOS 26 SDK** 的 Xcode 或 Command Line Tools 和 Swift 6 工具链。项目通过 Swift Package Manager 构建，没有第三方 Swift 包依赖。界面在 macOS 14、15 上使用兼容样式。

```sh
./script/test.sh                  # Swift 测试，Komari 请求使用回环模拟服务
./scripts/build-app.sh            # 构建适用于本机架构的应用
./scripts/build-app.sh --universal # 构建 Apple 芯片与 Intel 双架构包
```

脚本最后输出 `.app` 的绝对路径。默认写入 `~/Library/Caches/VPSMonitor/Builds/`。使用 `./scripts/build-app.sh --install` 可安装到当前用户的 `~/Applications/`。路由实机测试需要显式启用，常规测试使用模拟数据。

## 项目来源与许可

本项目基于原始 VPSMonitor 开发，保留上游 MIT 版权声明。感谢 Komari 提供监控服务与接口，Lumina 提供早期界面参考。[上游 VPSMonitor](https://github.com/xt1990xt1990/VPSMonitor) · [Komari](https://github.com/komari-monitor/komari) · [Lumina](https://github.com/stqfdyr/komari-theme-Lumina) · [MIT 许可证](LICENSE)
