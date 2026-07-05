# Open5GS + Kamailio IMS + srsRAN 端到端 4G/5G VoLTE 实践环境

本仓库是"创新创业校企联合实践(软件工程)"的**网络环境工程**,与 SIP 客户端工程(实践1 PC 端 / 实践2 Android 端)相互独立。

目标:基于 **Open5GS(EPC/4G 核心网)+ Kamailio IMS + srsRAN 4G + USRP B210 + 可读写白卡真机**,搭建端到端 4G/5G 移动网络,并集成 IMS 提供 VoLTE 多媒体服务,最终让 PC 客户端与 Android 客户端接入网络、实现音视频互通。

> ⚠️ 说明:2.86 GB 的离线镜像包 `ims-images.tar` 未纳入仓库(见 `.gitignore`),镜像通过 `scripts/build-images.sh` 拉取/构建获取,见【复现流程 · 步骤0】。图形客户端源码不在本仓库,来自独立的 `sip` 工程。

---

## 目标架构

```text
   实践1 PC 客户端            实践2 Android 客户端            真机(白卡)
        │                          │                          │
        │  SIP/RTP over IP         │  SIP/RTP over IP         │  4G 空口
        │  (局域网/WSL)            │  (WiFi + 中继)           │  USRP B210
        └───────────┬──────────────┴───────────┬─────────────┘
                    │                           │  srsRAN 4G eNB
                    ▼                           ▼
        ┌─────────────────────────────────────────────────────┐
        │  Open5GS EPC(MME/SGW/PGW/HSS) + Kamailio IMS         │
        │  P/I/S-CSCF + pyHSS + rtpengine + DNS + WebUI        │
        └─────────────────────────────────────────────────────┘
```

- **软件层(应用)**:客户端用 SIP 注册到 IMS,完成呼叫与音视频。与"怎么接入"无关。
- **接入层(承载)**:PC 走 IP 直连;真机走 USRP B210 的真实 4G 空口(白卡鉴权、核心网发 IP),再连 IMS。二者是上下配合,不是二选一。

---

## 主要组成

| 组件 | 作用 | 关键地址(docker 网 172.22.0.0/16) |
|---|---|---|
| Open5GS EPC | 4G 核心网:MME/SGW/PGW/HSS | MME 172.22.0.9 |
| Kamailio IMS | P/I/S-CSCF,SIP 信令中枢 | P-CSCF 172.22.0.21:5060,S-CSCF 172.22.0.19 |
| pyHSS | IMS 用户/鉴权数据库(HTTP REST) | 172.22.0.18:8080 |
| rtpengine | 媒体(RTP)锚定/中继 | 172.22.0.16 |
| DNS | 解析 IMS 服务域名 | — |
| srsRAN 4G | 软件无线电 eNB / UE(可 ZMQ 仿真或接 B210) | — |
| USRP B210 | SDR 射频前端(真实 4G 空口) | 经 USB3 / usbipd 接入 |

编排来源:`third_party/docker_open5gs`(vendored 的开源栈,核心 compose 为 `4g-volte-deploy.yaml`)。

---

## 目录结构

```text
shijian/
├─ .env.shijian                 实验网络参数(PLMN 001/01、主机IP、UE 子网、srsRAN 频点)
├─ config/
│  ├─ subscribers.csv           卡5/卡6 的 IMSI/MSISDN/Ki/OPc
│  ├─ docker-compose.client-access.override.yaml   对外发布 pcscf 5060 + rtpengine,供软客户端接入
│  └─ docker-compose.enb-external.override.yaml     对外暴露 S1AP/GTP-U,供外部 eNB 接入
├─ scripts/                     启停、开户、仿真、呼叫测试、中继、自检脚本(见下)
├─ deliverables/                小组实验报告 / 汇报PPT大纲 / 个人报告模板
├─ docs/                        IMS 集成笔记、ZMQ 仿真笔记、客户端接入指引
├─ runtime/                     生成的 srsRAN 配置、pyHSS 开户载荷、日志与验证记录
└─ third_party/docker_open5gs/  Open5GS + Kamailio IMS 编排(核心网/IMS 容器)
```

常用脚本:

| 脚本 | 用途 |
|---|---|
| `scripts/check-prereqs.ps1` | 检查前置环境(Docker/WSL/USB 等) |
| `scripts/build-images.sh` | 构建或拉取(`pull`)所需镜像 |
| `scripts/start-core-ims.ps1` / `.sh` | 启动 Open5GS EPC + Kamailio IMS |
| `scripts/provision-subscribers.ps1` / `.sh` | 写入 Open5GS HSS 用户 |
| `scripts/provision-pyhss.ps1`(或 `provision_pyhss.py`) | 写入 pyHSS APN/AuC/subscriber/IMS-subscriber |
| `scripts/start-zmq-sim.ps1` / `stop-zmq-sim.ps1` | ZMQ 虚拟射频仿真(无硬件即可跑通 attach) |
| `scripts/ims_ue.py` | 端到端 VoLTE 呼叫测试(caller/callee) |
| `scripts/apply-client-access.ps1` | 应用"客户端接入" override(发布 5060,rtpengine 通告局域网IP) |
| `scripts/udp_relay_host_to_wsl.py` | 主机→WSL 的 UDP 中继(供别的电脑/手机 WiFi 接入) |
| `scripts/start-srsenb.sh` | 启动 srsRAN 4G eNB(docker 或 native,配 B210 用真实射频) |
| `scripts/validate-lab-config.ps1` / `verify-all.ps1` | 配置/运行时自检 |
| `scripts/stop-core-ims.ps1` / `.sh` | 停止核心网与 IMS |

---

## 前置条件

1. Windows 11 + WSL2(Ubuntu),已装 **Docker**(Docker Desktop 或 WSL 原生 docker 均可)。
2. Python 3(用于 `ims_ue.py`、`udp_relay_host_to_wsl.py` 等测试脚本)。
3. 使用测试 PLMN **`001/01`**,与两张卡的 IMSI 一致。
4. 射频路径(可选)才需要:USRP B210 + srsRAN 4G + 可读写白卡;并且必须在**屏蔽箱/足够衰减**下进行,严禁在许可频段上对外辐射。

---

## 复现流程

> 无射频硬件也能完整复现"注册 + 呼叫 + 媒体"全链路 —— 走【步骤5 · 路径A(ZMQ 仿真)】即可。B210 到位后再走【路径B】做真机空口。

### 步骤 0 · 获取镜像(仓库不含离线包)

```bash
# 在 WSL / Git Bash 中,进入仓库
cd /g/study/Third/lab/shijian
# 拉取上游镜像(推荐,最快)
bash scripts/build-images.sh pull
# 若你另有离线包 ims-images.tar,则:  docker load -i ims-images.tar
```

### 步骤 1 · 克隆与环境变量

```bash
git clone git@github.com:xvyean/open5Gs.git shijian
cd shijian
# 按本机情况核对/修改主机 IP:.env.shijian 里的 DOCKER_HOST_IP / RAN_BIND_IP
#   —— 应为本机能被客户端/射频侧访问到的局域网 IPv4
bash scripts/configure-env.sh      # 依据 .env.shijian 生成 docker_open5gs/.env 等运行配置
```

### 步骤 2 · 启动核心网 + IMS

PowerShell(Windows Docker):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-core-ims.ps1
# 若 Docker Desktop 弹 WSL integration 超时,先选 Skip,再:
#   .\scripts\start-core-ims.ps1 -SkipConfigure
```

或 WSL 原生 Docker:

```bash
bash scripts/start-core-ims.sh
```

启动后约 21 个核心网/IMS 容器应为 `Up`。访问入口:

- Open5GS WebUI:`http://<主机IP>:9999`(`admin` / `1423`)
- pyHSS Swagger:`http://<主机IP>:8080/docs/`
- Grafana:`http://<主机IP>:3000`(`open5gs` / `open5gs`)

### 步骤 3 · 开户(两处都要写)

```powershell
# 3.1 写入 Open5GS HSS(4G 附着用)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-subscribers.ps1
# 3.2 写入 pyHSS(IMS 注册/鉴权用):APN internet/ims + AuC + subscriber + ims_subscriber
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-pyhss.ps1
```

WSL 侧等价:`bash scripts/provision-subscribers.sh` 与 `python3 scripts/provision_pyhss.py`。

卡数据(测试白卡,PLMN 001/01):

| 卡 | IMSI | MSISDN | Ki | OPc |
|---|---|---|---|---|
| 卡5 | 001012345678905 | 12345678905 | `000102030405060708090A0C0B0D0E0F` | `C6413837878F5B826F4F8162A1C8D879` |
| 卡6 | 001012345678906 | 12345678906 | `000102030405060708090A0C0B0D0E0F` | `C6413837878F5B826F4F8162A1C8D879` |

### 步骤 4 · 核心网就绪自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lab-config.ps1
```

```bash
docker ps                 # 容器均 Up
docker logs mme    | tail # 看到 S1AP 36412 已监听、已连 HSS
# pyHSS 存活:GET /oam/ping 应返回 {"result":"OK"}
```

### 步骤 5 · 选一条验证路径

#### 路径 A · 无硬件(ZMQ 虚拟射频)—— 推荐先跑通

用 srsRAN 的 ZMQ 虚拟射频让 UE(卡5,身份取自 `docker_open5gs/.env` 的 UE1)附着,再做端到端 VoLTE 呼叫:

```powershell
# 5A.1 起虚拟射频(核心网须已在运行)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-zmq-sim.ps1
```

```bash
# 5A.2 验证附着
docker logs -f srsue_zmq   # "Found PLMN Id=00101" -> "RRC Connected" -> "Network attach successful. IP: 192.168.100.x"
docker exec srsue_zmq ping -c3 -I tun_srsue 192.168.100.1   # ping 通 APN 网关

# 5A.3 端到端 VoLTE 呼叫(两个角色跑在不同容器,拿到不同源 IP,模拟 2 部终端)
#      被叫(卡6)自动应答;主叫(卡5)注册后 INVITE 卡6,完成 200/ACK/BYE
python3 scripts/ims_ue.py callee 001012345678906 000102030405060708090A0C0B0D0E0F &
python3 scripts/ims_ue.py caller 001012345678905 000102030405060708090A0C0B0D0E0F 001012345678906
# 预期:REGISTER 200 -> INVITE -> 200 OK(rtpengine 锚定 audio+video)-> ACK -> BYE 200
```

停止:`powershell -File .\scripts\stop-zmq-sim.ps1`。

#### 路径 B · 真实射频(USRP B210 + 真机)

```bash
# 5B.1 接入 B210(USB3),Windows 不可见时用 usbipd 挂进 WSL;务必屏蔽/衰减
# 5B.2 起 srsRAN 4G eNB
bash scripts/start-srsenb.sh docker      # 或 native(WSL 已装 srsRAN_4G)
```

真机侧:手动选网 `00101`,配置 APN `internet`(默认上网)与 `ims`(VoLTE),开启 VoLTE。观察 `mme`/`pcscf`/`scscf` 日志,依次验证 attach → PDN 拿 IP → SIP REGISTER → VoLTE 呼叫。

### 步骤 6 · 接入图形客户端(实践1 PC / 实践2 Android)

> 客户端源码在独立的 `sip` 工程,不在本仓库。以下是让其接入本环境 IMS 的配置要点(已在实测中验证)。

**登录三要素:**

- **服务器**:填**域名** `ims.mnc001.mcc001.3gppnetwork.org`(客户端把该字段当作 SIP 域名;**填 IP 会 483 Too Many Hops**)。
- **用户**:某张卡的 IMSI(如卡5 `001012345678905`);两端要用不同卡才能互打。
- **密码**:该卡的 Ki(如 `000102030405060708090A0C0B0D0E0F`)。

**域名解析(hosts):** 在客户端所在电脑的 `C:\Windows\System32\drivers\etc\hosts` 加一行,把域名指到"该机能到达 IMS 的 IP":

- 本机(与 IMS 同机):`<WSL 侧 IMS IP,如 172.17.204.81>  ims.mnc001.mcc001.3gppnetwork.org`
- 别的电脑 / 手机 WiFi:`<本机局域网 IP,如 10.129.164.17>  ims.mnc001.mcc001.3gppnetwork.org`

**局域网/多机接入(别的电脑或手机走 WiFi):** IMS 跑在本机 WSL 内网,外部设备够不到,需要在本机架 UDP 中继并对外发布端口:

```powershell
# 6.1 让 rtpengine 对外通告局域网 IP,并发布 pcscf 5060 / rtpengine 端口
powershell -File .\scripts\apply-client-access.ps1
```

```bash
# 6.2 起主机→WSL 的 UDP 中继(先确保本机 5060 未被占用)
python scripts/udp_relay_host_to_wsl.py --host 10.129.164.17 --wsl 172.17.204.81
```

此后:外部设备 hosts 指向 `10.129.164.17` + 服务器填域名 + 用一张卡登录,即可注册并互打。本机上的 PC 客户端则直连 WSL IP,无需中继。

### 步骤 7 · 停止 / 清理

```powershell
powershell -File .\scripts\stop-zmq-sim.ps1     # 若开了仿真
powershell -File .\scripts\stop-core-ims.ps1    # 停核心网与 IMS
```

---

## 关键参数速查

| 项 | 值 |
|---|---|
| PLMN(MCC/MNC) | `001` / `01`(手动选网 `00101`) |
| IMS 域名(SIP realm) | `ims.mnc001.mcc001.3gppnetwork.org` |
| SIP 信令端口 | UDP 5060(P-CSCF) |
| UE 子网 | internet `192.168.100.0/24`,ims `192.168.101.0/24` |
| 主机/射频绑定 IP | `.env.shijian` 的 `DOCKER_HOST_IP` / `RAN_BIND_IP` |
| WebUI / pyHSS / Grafana | `admin/1423` · `/docs/` · `open5gs/open5gs` |

---

## 已知问题与修复(踩坑记录)

- **483 Too Many Hops(注册失败)**:客户端"服务器"字段填了 IP。必须填域名 `ims.mnc001.mcc001.3gppnetwork.org`,由 hosts 负责域名→IP。
- **403(注册被拒)**:密码(Ki)输入有误。Ki 中段是 `…090A0C0B0D0E0F`(注意 `0C` 在 `0B` 之前),手输易错,建议粘贴。
- **终呼 477**:P-CSCF `kamailio_pcscf.cfg` 的 `udp_mtu=1300` + `udp_mtu_try_proto=TCP` 把大 INVITE 强切 TCP。已注释(备份 `.udp_mtu.bak`)并重启 pcscf。
- **对话内 404(ACK/BYE)**:P-CSCF 对 UDP 客户端不回 Record-Route;ACK/BYE 直发对端 Contact 即可。
- **Docker Desktop 的 WSL daemon bridge 不可用**:改用 PowerShell 脚本(Windows Docker)运行核心网,不影响功能。

---

## 参考资料

- Open5GS Dockerized VoLTE:https://open5gs.org/open5gs/docs/tutorial/03-VoLTE-dockerized/
- Open5GS Your First LTE:https://open5gs.org/open5gs/docs/tutorial/01-your-first-lte/
- Open5GS VoLTE with Kamailio IMS:https://open5gs.org/open5gs/docs/tutorial/02-VoLTE-setup/
- srsRAN Project(srsUE / Open5GS):https://docs.srsran.com/projects/project/en/latest/tutorials/source/srsUE/source/index.html
- Kamailio IMS 安装:https://www.kamailio.org/wikidocs/tutorials/ims/installation-howto/

---

## 安全与合规

- 本仓库中的卡 Ki/OPc 为课程测试白卡(PLMN 001/01)数据,仅供实验复现,请勿用于任何真实网络。
- 射频发射务必在屏蔽箱或足够衰减的隔离环境下进行,不得在许可频段上对外辐射。
