# Router health collector

纯 BusyBox `ash` 采集器，默认每 60 秒采样，写出 `latest.json` 与按时间戳保留最近 24 小时的 `observations.tsv`。`wan_up` 来自 OpenWrt `ubus network.interface.<WAN_INTERFACE> status`，不是网关 ICMP 的替代值；NPS 使用 `npc` 进程和现有 TCP session 检查。断线次数只在同一 boot、相邻间隔未超限且已观测的 `wan_up` 状态发生 `true -> false` 时递增；首次启动、重启、长缺口、`null` 探测不算断线，并保留实际 `observation_seconds_24h` 覆盖时长。

配置从部署目录读取，真实节点地址必须放在设备上的 `PROBE_FILE`，仓库样例使用文档地址。网关与可直接访问的 VPS 使用 ICMP；家庭 NAT 后的主机使用 `ssh` 类型和实际可达入口，读取 SSH 标识响应，避免把家庭公网 IP 或中继监听端口当作主机。DNS 使用 `nslookup`；NPS 检查客户端进程及到服务端的现有 TCP 连接。在路由上验证：`HEALTH_CONFIG=... ./health-collector.sh --check-config`；`--once` 执行一轮采样。

探测格式为 `id|label|kind|target|port`：`ping` 不填端口；`ssh` 必须填 1—65535 的端口。SSH 探测读取服务标识。成功时记录从发起连接到收到标识的耗时，丢包率为空。ICMP 收到部分回应时保留真实丢包率，界面显示“部分丢包”。

历史窗口回归测试：`./test-health-history.sh`（覆盖状态转换、长缺口、重启和窗口过期）。

探测回归：`python3 test-health-probes.py`（部分丢包、无结果、SSH 响应、错误协议、超时及配置校验）。

首次部署示例（先修改两个配置样例中的地址和持久数据盘路径；已有配置需保留）：

```sh
mkdir -p /etc/vpsmonitor /usr/lib/vpsmonitor
cp health-collector.sh /usr/bin/health-collector.sh
cp health-history.awk /usr/lib/vpsmonitor/health-history.awk
cp health-probes.sh /usr/lib/vpsmonitor/health-probes.sh
chmod 755 /usr/bin/health-collector.sh
cp health-collector.conf.example /etc/vpsmonitor/health-collector.conf
cp probes.conf.example /etc/vpsmonitor/probes.conf
chmod 600 /etc/vpsmonitor/*.conf
cp vpsmonitor-health.init /etc/init.d/vpsmonitor-health
chmod 755 /etc/init.d/vpsmonitor-health
/usr/bin/health-collector.sh --check-config
/etc/init.d/vpsmonitor-health enable
/etc/init.d/vpsmonitor-health start
```

JSON 顶层字段为 `version,timestamp,observed_since,interval_seconds,wan_up,nps_running,dns_ok,wan_outages_24h,observation_seconds_24h,probes`；每个 probe 为 `id,label,kind,target,ok,latency_ms,loss_percent`，失败时值为 `false` 或 `null`。
