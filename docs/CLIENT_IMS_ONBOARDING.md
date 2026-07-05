# 自研 SIP 客户端接入 IMS 操作手册（PC 端 + Android 端）

适用范围：`G:\study\Third\lab\sip` 工程的 `desktop-client`（实践1 PC 端）与
`app`（实践2 Android 端）接入本仓库的 Open5GS + Kamailio IMS
（`4g-volte-deploy.yaml`，21 容器，Docker Desktop/WSL2）。
前置结论见 `docs/IMS_INTEGRATION_NOTES.md`（MD5 Digest 配方、WITH_RX 门禁等）。

宿主机 LAN IP 以 `.env` 的 `DOCKER_HOST_IP` 为准，当前为 **10.129.164.17**。
下文出现该 IP 处，若换了网络环境请先重跑 `scripts/configure-env.sh` 并以新值代入。

---

## 0. 客户端能力与配置入口（代码事实，不需要改代码）

| 事实 | 位置 |
| --- | --- |
| PC 登录表单：SIP 用户 / 密码 / 服务器 IP 三个输入框 | `sip/desktop-client/.../DesktopApp.kt:1308-1327` |
| PC 登录逻辑：本地 SIP 端口 `40000+(user%10000)`，服务器端口固定 5060/UDP | `sip/desktop-client/.../DesktopCallController.kt:626-655` |
| Android 登录表单（LoginCard：用户名/密码/服务器 IP） | `sip/app/.../feature/call/CallRoute.kt:90-100` |
| Android 登录逻辑：同样固定 5060/UDP | `sip/app/.../feature/call/CallViewModel.kt:206-252` |
| Digest 认证：MD5 + `qop=auth`（nc/cnonce），realm/nonce 取自 401 挑战 | `sip/sip-core/.../SipClient.kt:404-434` |
| Contact 恒带 `;transport=udp`；REGISTER URI = `sip:<服务器字段>`；From/To = `sip:<用户名>@<服务器字段>` | `SipClient.kt:278-295` |
| 仅支持 UDP 传输（DatagramSocket），无 TCP/TLS | `SipClient.kt:108` |
| RTP 端口：`50000+(user%1000)*2`，视频 `+2`；SDP 的 c= 用本机 LAN IPv4 | `DesktopCallController.kt:488`、`CallViewModel.kt:295` |

两个要点：

1. **“服务器 IP”字段同时充当 SIP 域**（From/To/请求 URI 的 host 部分）和
   实际发包地址（`InetAddress.getByName`）。填域名就要求本机能把域名解析
   到可达地址；填 IP 就意味着 IMPU 的域是这个 IP。
2. 用户名填 15 位 IMSI 时 `toIntOrNull()` 溢出返回 null → user%… 按 0 计，
   即 **PC/Android 的本地 SIP 端口都是 40000、RTP 都是 50000（视频 50002）**。
   不同设备各用一张卡没有冲突；**不要在同一台机器上跑两个客户端**。

---

## 1. 先应用可达性 override（一次性）

Docker Desktop（WSL2 后端）不路由 172.22.0.x，宿主机和局域网设备必须走
“发布端口”。已提供：

- `config/docker-compose.client-access.override.yaml`
  - `pcscf`：发布 `5060/udp + 5060/tcp` 到宿主机 0.0.0.0。
  - `rtpengine`：`INTERFACE=172.22.0.16!10.129.164.17`（rtpengine 的
    advertised-address 语法，SDP 中公告宿主机 IP），RTP 窗口收窄为
    `PORT_MIN=49000 / PORT_MAX=49100` 并按同一范围发布
    `49000-49100/udp`（上游默认 49000-50000 共 1001 个端口，Docker Desktop
    发布大范围 UDP 端口极慢/易失败，101 个端口约可承载 12 路音视频并发）。
  - 不启用 pcscf 的 SIP 层 advertise：客户端不按 Via/Record-Route 路由，
    所有信令直发服务器:5060，SIP 层公告宿主机 IP 无收益且会波及内网真机。

应用（Docker 引擎就绪后执行；会**重建 rtpengine 和 pcscf 两个容器**，
其余 19 个不动）：

```powershell
cd G:\study\Third\lab\shijian
powershell -ExecutionPolicy Bypass -File scripts\apply-client-access.ps1
```

应用后：

- 所有已注册终端（含真机/仿真 UE）需要重新注册（pcscf 重建导致）。
- 验证端口已发布：`docker port pcscf`（应含 5060/udp）、`docker port rtpengine | more`。
- 还原：重新运行 `scripts\start-core-ims.ps1`（不带 client-access override
  即回到原配置）。
- 确认 `third_party/docker_open5gs/pcscf/pcscf.cfg:140` 仍是
  `##!define WITH_RX`（已放开的 QoS 门禁；若被 git 还原，PC 端注册会 403）。

---

## 2. PC 端（桌面客户端，建议用卡5）

### 2.1 一次性系统准备

1. 管理员编辑 `C:\Windows\System32\drivers\etc\hosts`，追加：

   ```text
   10.129.164.17  ims.mnc001.mcc001.3gppnetwork.org
   ```

   这样“服务器 IP”可以直接填 IMS 域名（与已实测成功的 REGISTER 配方一致，
   IMPU=`sip:IMSI@ims域`），报文实际发往宿主机 5060 发布端口。

2. 管理员 PowerShell 放行客户端入站 UDP（终呼 INVITE 直达 Contact 端口
   40000，RTP 到 50000/50002；首次运行 Java 时弹出的防火墙提示选“允许
   专用网络”亦可）：

   ```powershell
   New-NetFirewallRule -DisplayName "sip0-client-udp" -Direction Inbound -Protocol UDP -LocalPort 40000,50000-50003 -Action Allow
   ```

### 2.2 登录表单逐项

| 字段 | 填写值 |
| --- | --- |
| SIP 用户 | `001012345678905`（卡5 IMSI，**纯 IMSI，不带 @域**） |
| 密码 | `000102030405060708090A0C0B0D0E0F`（卡5 Ki，32 位十六进制原样） |
| 服务器 IP | `ims.mnc001.mcc001.3gppnetwork.org` |
| 传输协议 | 无需选择（客户端固定 UDP:5060） |
| 本地端口 | 无需填写（自动 SIP=40000，RTP=50000/视频 50002） |

登录状态出现 `SIP ready` 即注册成功（REGISTER → 401 MD5 挑战 → 200 OK）。
“消息状态”失败属正常——IMS 环境里没有 8081 消息后端；若同时想用消息/群聊，
在本机跑 `sip` 工程的 `messaging-server`（hosts 已把域名指回本机，8081 恰好
落在本机，无需改配置）。

---

## 3. Android 端（app，建议用卡6）

Android 无法改 hosts（未 root），按优先级两种方案：

### 方案 A（先试）：服务器字段直接填宿主机 IP

| 字段 | 填写值 |
| --- | --- |
| 用户名 | `001012345678906`（卡6 IMSI） |
| 密码 | `000102030405060708090A0C0B0D0E0F`（卡6 Ki） |
| 服务器 IP | `10.129.164.17` |

代价：IMPU/被叫 URI 的域变成 `10.129.164.17`（如
`sip:001012345678906@10.129.164.17`）。Digest 运算本身不受影响（realm 从
挑战里取，仍是 IMS 域；pyHSS 取 `@` 前的 IMSI 查库），但 I-CSCF/S-CSCF/pyHSS
的 UAR/SAR/LIR 是否接受“IP 作域”的 IMPU **未实测**。若注册被 403/404 拒或
互拨报 404/604，即是这个原因，改用方案 B。
可先在容器内验证：把 `scripts/ims_register_test.py` 拷入 pyhss 容器，将其
`realm`/`impu` 域改为 `10.129.164.17` 后运行，看第二次 REGISTER 是否 200。

### 方案 B（兜底）：让手机能解析 IMS 域名

任选其一，然后服务器字段填 `ims.mnc001.mcc001.3gppnetwork.org`：

- 路由器（若可管理）添加本地 DNS/静态解析：IMS 域 → `10.129.164.17`；
- 手机装本地 DNS 覆写类应用（VPN 方式免 root，如 personalDNSfilter /
  Nebulo），添加规则 IMS 域 → `10.129.164.17`；
- root 设备/模拟器直接改 `/system/etc/hosts`。

注意：**不要**把 docker 栈里 dns 容器的 53 端口发布给手机用——它把 IMS 域
解析到 172.22.0.21，手机不可达。

### 网络要求

- 手机与 PC 在同一网段（同一 Wi-Fi），且 AP 未开“客户端隔离”，否则
  pcscf 从容器出方向 NAT 后发往手机 `40000` 的终呼 INVITE 和 rtpengine 发往
  手机 `50000` 的 RTP 都到不了。
- 通话中保持 app 前台（省电策略可能冻结 UDP 收包）。

---

## 4. 互相呼叫

- 被叫号码 = 对方 **IMSI**：PC 呼 Android 填 `001012345678906`，反之填
  `001012345678905`。
- 媒体路径：双方 RTP 都发往 SDP 中 rtpengine 公告的
  `10.129.164.17:49000-49100`，经宿主机发布端口进 rtpengine 中转；
  rtpengine → 客户端方向经容器出站 NAT 直达客户端 `50000/50002`。

---

## 5. 看哪些日志

### 注册成功链（REGISTER → 401 → 200）

```powershell
docker logs -f pcscf       # 入口：REGISTER 到达、401/200 转发、Contact/received 记录
docker logs -f icscf       # UAR/UAA（选 S-CSCF）
docker logs -f scscf       # MAR（取 MD5 向量，"force to MD5 ... non-ims"）、SAR/SAA、200 OK
Get-Content third_party\docker_open5gs\pyhss\logs\hss.log -Tail 50 -Wait   # Cx 侧：按 IMSI 查库、返回 Digest 口令(Ki)
```

判定：`scscf` 出现该 IMPU 的 `200 OK`（SAA 成功）即注册完成；客户端状态
`SIP ready`。

### 呼叫成功链（INVITE 全程）

```powershell
docker logs -f pcscf       # 主叫侧 MO 路由 + NATMANAGE 段（rtpengine offer/answer 标志）；被叫侧 MT 投递到 Contact
docker logs -f scscf       # orig → term 路由（含 LIR 定位被叫 S-CSCF）
docker logs -f rtpengine   # offer/answer 端口分配（应看到公告地址 10.129.164.17 与 49xxx 端口）、双向包计数
```

判定：主叫看到 180 后 200 OK；rtpengine 日志两条媒体流均有增长的包计数
（`packets`/kernel stream）即双向通。

---

## 6. 常见故障速查

| 现象 | 原因与处置 |
| --- | --- |
| 一直 401 循环（挑战→带鉴权重发→又 401） | ① 密码没填 Ki 全 32 位十六进制或大小写截断；② 用户名不是纯 IMSI（带了 `@域` 会拼出坏 URI）；③ 挑战 nonce 过期+UDP 重传交错。看 `scscf` 日志的鉴权失败原因和 `hss.log` 里返回的向量。 |
| 403 Forbidden（注册即拒） | 最常见：`Can't register to QoS for signalling` → `pcscf.cfg` 的 `WITH_RX` 又被打开（应保持 `pcscf.cfg:140` 为 `##!define WITH_RX`），改回后重启 pcscf。其次：pyHSS 无该 IMSI 订户（重跑 `scripts/provision-subscribers.ps1`）。 |
| 403/404/604（仅 Android 方案 A） | “IP 作域”的 IMPU 被 HSS/I-CSCF 拒。换方案 B（让手机解析 IMS 域名）。 |
| 主叫收到 477 Unfortunately error / 被叫无振铃 | 终呼侧 P-CSCF 投递不到被叫 Contact：PC 端防火墙没放行 UDP 40000；Android 端 AP 隔离/手机休眠；或（模拟器场景）P-CSCF 按 TCP 回落投递被拒——真实分立 IP 的 UDP 端点不受此影响（见 IMS_INTEGRATION_NOTES §4）。`docker logs pcscf` 会显示投递目标与失败原因。 |
| 注册超时（连 401 都没有） | override 未应用（`docker port pcscf` 为空）；Docker 引擎未就绪；hosts 未加导致域名解析失败；宿主机 5060 被其他软件占用（`netstat -ano | findstr :5060`）。 |
| 接通但单通/无声 | ① override 未生效，SDP 里 c=172.22.0.16（客户端够不着容器 IP）——重跑 apply 脚本并重拨；② RTP 范围未发布或与 PORT_MIN/MAX 不一致（`docker port rtpengine` 应列出 49000-49100/udp）；③ PC 防火墙拦了入站 UDP 50000/50002；④ `.env` 的 `DOCKER_HOST_IP` 不是本机当前 LAN IP（换网后忘了重新 configure-env + 重建 rtpengine）；⑤ SDP 里出现 a=candidate（NATMANAGE 某方向 ICE=force）——客户端只认 c=/m= 行可忽略，若 rtpengine 因等待 ICE 不放包，看 rtpengine 日志确认后可在通话中先说话触发对称学习。 |
| 通话建立 30 秒左右被挂断 | 对端 ACK 没送达（丢在 NAT/防火墙），客户端在 32 秒无 ACK 时会主动挂断（SipClient 200 OK 重传逻辑）。排查同 477 行。 |

---

## 7. 遗留风险与边界

1. **rtpengine 公告 IP 是全局的**：`INTERFACE=...!10.129.164.17` 对**所有**
   通话生效，包括内网真机/srsUE 之间的 VoLTE——它们的媒体也会被公告到宿主
   机 IP，再经发布端口回流（hairpin）。演示纯真机通话若出现媒体异常，
   重跑 `start-core-ims.ps1` 还原后再演示；软电话联调时再 apply。
   （如需两者并存，得给 rtpengine 配双命名接口并改 pcscf 的 rtpengine
   调用方向标志，超出“不改上游配置”的范围。）
2. **Android 与 PC 必须同网段**且 AP 不隔离；若手机在另一网段，需在网关
   上放通/路由到 10.129.164.17 的 5060 与 49000-49100/UDP。
3. **信令回程依赖 Docker 端口代理的 UDP 映射**：pcscf 的应答按 rport 回给
   docker-proxy 的源端口。客户端每 20s 发 OPTIONS、每 60s 重注册，可保持
   映射常活；长时间挂机后若终呼失败，重新登录即可。
4. **IP 作域（Android 方案 A）未实测**，HSS 侧行为不确定；已给出容器内
   预验证方法与方案 B 兜底。
5. **换网络必须三步走**：重跑 `configure-env.sh`（刷新 DOCKER_HOST_IP）→
   `apply-client-access.ps1`（重建 rtpengine/pcscf）→ PC 端更新 hosts 行。
6. 客户端固定 UDP、无 IPsec/TLS：依赖 S-CSCF 对非 AKA REGISTER 的 MD5
   回落（上游注释 `force to MD5 for zoiper.... non-ims`），不要在 pcscf/
   scscf 上启用强制 IPsec/Sec-Agree。
