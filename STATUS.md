# shijian 实践环境状态

日期：2026-07-04

## 已完成

- 已在本目录搭建 Open5GS EPC + Kamailio IMS + pyHSS + DNS + RTPengine 环境。
- 已拉取并配置 `third_party/docker_open5gs`。
- 已生成 srsRAN 4G eNB 配置：`runtime/srsran4g/`。
- 已配置测试 PLMN：MCC `001`，MNC `01`，TAC `1`。
- 已写入两张卡的 Open5GS HSS 数据：
  - IMSI `001012345678905`
  - IMSI `001012345678906`
- 已写入 pyHSS 数据：
  - APN `internet`，`apn_id=1`
  - APN `ims`，`apn_id=2`
  - 两张卡的 AuC、subscriber、IMS subscriber 记录
- 已添加 Windows Docker 启停脚本，用于绕开 Docker Desktop 的 Ubuntu WSL integration 异常。
- 已安装 `usbipd-win`。
- 已在 Ubuntu WSL 中安装 Docker CLI、Docker Compose plugin、Docker Buildx plugin。
- 已在 Ubuntu WSL 中安装 UHD、PC/SC、usbutils、tcpdump、编译依赖和 UHD FPGA/firmware images。

## 当前可用入口

- Open5GS WebUI: `http://127.0.0.1:9999`，账号 `admin`，密码 `1423`
- pyHSS Swagger: `http://127.0.0.1:8080/docs/`
- Grafana: `http://127.0.0.1:3000`，账号 `open5gs`，密码 `open5gs`

## 常用命令

> ⚠️ 本套核心网跑在 **WSL 原生 dockerd**(见【2026-07-05 复核】节)。下面 PowerShell 命令为早期 Docker Desktop 方案的历史记录;**当前请在 WSL 内用 `.sh` 版本**,勿跑 `.ps1`(会另起一套):
> ```bash
> bash scripts/start-core-ims.sh      # 启动
> bash scripts/stop-core-ims.sh       # 停止
> ```

启动核心网和 IMS（历史/Windows Docker 方案）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-core-ims.ps1
```

如果 Docker Desktop 弹出 Ubuntu WSL integration 超时窗口，先选择 `Skip WSL distro integration`，然后用已有配置启动：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-core-ims.ps1 -SkipConfigure
```

写入 Open5GS HSS 用户：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-subscribers.ps1
```

写入 pyHSS 用户：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-pyhss.ps1
```

停止核心网和 IMS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\stop-core-ims.ps1
```

## 已验证

- `scripts\validate-lab-config.ps1` 通过。
- Windows Docker Desktop engine 可用。
- `scripts\start-core-ims.ps1` 可刷新配置并保持容器运行。
- 21 个核心网/IMS 相关容器处于 `Up` 状态。
- Open5GS WebUI 返回 HTTP `200`。
- pyHSS `/oam/ping` 返回 `{"result": "OK"}`。
- `usbipd-win` 可执行，`usbipd list` 可列出 Windows USB 设备。
- Ubuntu WSL 中 `docker --version`、`docker compose version`、`uhd_find_devices`、`pcsc_scan`、`lsusb`、`tcpdump` 均可找到。
- MME 日志显示 S1AP `36412` 已启动，并已连接 HSS。
- Open5GS HSS 中两张卡均有 `internet` 和 `ims` 会话配置。
- pyHSS 中两张卡均可查到 AuC、subscriber、IMS subscriber 记录。

## 2026-07-04 追加进展

- ZMQ 过渡验证已跑通：srsUE（卡5）attach 成功，`Network attach successful. IP: 192.168.100.2`，ping 通 APN 网关（`scripts/start-zmq-sim.ps1`）。
- 端到端 VoLTE 呼叫已闭环：两个独立 IP 端点 REGISTER 200 → INVITE → 200 OK（rtpengine 锚定 audio+video）→ ACK → BYE 200 OK（`scripts/ims_ue.py`）。
- 修复终呼 477：根因为 P-CSCF `kamailio_pcscf.cfg` 的 `udp_mtu=1300`+`udp_mtu_try_proto=TCP` 把大 INVITE 强制切 TCP，已注释（备份 `.udp_mtu.bak`）并重启 pcscf。
- 修复对话内 404：P-CSCF 对 UDP 客户端不回 Record-Route，ACK/BYE 改为直发对端 Contact。
- 定位说明：早前"单机模拟器 477 假象"的判断已被证伪，真实根因见上（udp_mtu）。

## 2026-07-05 OTA 前置复核（实测校正）

> 以下为 B210 到货前一天的实机复核结论，**如与本文更早段落冲突，以本节为准**。

- **核心网实际引擎 = WSL Ubuntu 原生 dockerd**（`docker context = default`，主机名 `tean`），21 个容器 `Up`。**不是** Docker Desktop。上文「核心网已改走 Windows Docker」的说法已过时 —— 明日**勿跑 `start-core-ims.ps1`**（会在 Docker Desktop 另起一套、端口冲突）；核心网一律在 WSL 内用 `.sh` 版本操作。
- 该归属对 OTA 是**正确的**:B210 用 `usbipd attach` 挂进同一个 WSL 后,`srsenb.yaml` 才能透传 `/dev/bus/usb`,与 MME(172.22.0.9)同引擎互通。
- 开户数据双库实测在位:mongo `open5gs.subscribers` = …905/…906(2);`ims_hss_db` 的 subscriber/auc/ims_subscriber 均含两卡(msisdn 12345678905/6)。**无需重跑 provision**。
- `docker_srslte` 镜像已在 WSL 原生引擎就位(pull 自 ghcr 并 tag),含 UHD/`srsenb`/B210 FPGA(`usrp_b210_fpga.bin`)。docker 模式 B210 通路已就绪。
- 无残留 ZMQ `srsenb/srsue` 容器,启 eNB 不会撞 172.22.0.22。
- P-CSCF 477 修复(udp_mtu 注释)经 bind-mount `/mnt/pcscf` 实测生效。
- **docker 模式射频参数来自模板文件**(`srslte/enb.conf`+`rr_enb.conf`),不读 `.env.shijian`;已在模板注入 `device_args=type=b200,master_clock_rate=23.04e6`(与 EARFCN 3350 / n_prb 50 一致)。
- pySim 已装于 `~/pysim`(WSL,Python 3.12 → 依赖在 venv `~/pysim/venv`);读卡命令用 `~/pysim/venv/bin/python pySim-read.py -p 0`。

## 2026-07-06 端到端复验 + ZMQ 脚本补齐（实测）

> 本节为 B210 到货当天的运行时复验结论，**如与更早段落冲突，以本节为准**。全程在 WSL 原生 dockerd 上实跑（非静态检查）。

**新增 WSL 版 ZMQ 启停脚本（修 `.ps1` 引擎错配）**

- 核心网 7/5 起跑在 WSL 原生 dockerd，但此前 ZMQ 仿真只有 `start-zmq-sim.ps1`（Windows Docker Desktop），照 README 跑会找不到 `docker_open5gs_default` / `mme`。
- 已补 `scripts/start-zmq-sim.sh` / `scripts/stop-zmq-sim.sh`：走 WSL 同引擎，含"核心网未起 / 镜像缺失"前置校验，**不加** `--remove-orphans`（避免误删核心网）。二者均**实测通过**（起→attach→停→核心网原样保留）。

**实测通过项（2026-07-06）**

- 核心网+IMS `docker compose -f 4g-volte-deploy.yaml up -d` → 21 容器 Up、pyHSS `/oam/ping`=`{"result":"OK"}`、卡5/卡6 数据在卷里（无需重跑 provision）。
- 端到端呼叫（按 **IMSI** 拨）：REGISTER 200 → INVITE → 180 → 200 OK（rtpengine 锚定 audio+video）→ ACK → BYE 200，主被叫双方 PASS。
- 端到端呼叫（按 **MSISDN 电话号 `12345678906`** 拨）：**同样 PASS**。S-CSCF 日志 `Term User <sip:12345678906@...> [registered]` → `Found contact sip:001012345678906@...`。**结论：按号码路由靠 `msisdn_list` 隐式注册即可，无需 ENUM**（此前"原生拨号需 ENUM"的担心已排除）。
- ZMQ attach（经新 `.sh` 脚本）：`Found PLMN 00101` → `RRC Connected` → `Network attach successful. IP: 192.168.100.x`。

**校正：ZMQ 用户面（数据面）当前不通**

- srsUE attach（控制面）正常、拿到 IP；但 `ping` APN 网关 `192.168.100.1` 与外网 `8.8.8.8` 均 100% 丢包，抓包确认**上行 GTP-U 未到达 sgwu/upf**——断点在 srsRAN ZMQ 用户面。
- **2026-07-04 记录的"ping 通 APN 网关"不复现**；演示 / 报告勿声称 ZMQ 能上网。
- 影响面：**不影响 ZMQ 兜底**（兜底展示 attach 控制面 + IMS 信令走 docker 网，均不依赖 ZMQ 用户面）；**不预示 B210 失败**（真机走真实射频，数据通路与 ZMQ 采样管不同，ZMQ 用户面不通常为其自身特性）。但**"用户面数据端到端跑通"目前尚未在任何一条路上被证明**，待 B210 真机验。

**环境操作注意**

- 用一次性 `wsl.exe 命令` 方式驱动时，命令返回后 WSL2 会回收发行版、连 dockerd 带 21 容器一起杀（compose 栈无 `restart:` 策略、不会自愈）。**演示与联调务必在一个常驻 WSL 终端里操作**（或后台留一个进程钉住发行版）。

## 未完成条件

- USRP B210 将于 7/6 接入，完成 OTA 真机空口测试（VoLTE 主线的最终形态）。射频以外的**信令全链路**（attach 控制面、IMS 注册/呼叫、rtpengine 媒体锚定）已在 ZMQ + `ims_ue.py` 复验打通；**唯用户面数据端到端尚未证明**（见 2026-07-06 节），待真机验。
- ~~Docker Desktop 的 Ubuntu WSL daemon bridge 当前不可用；核心网已改走 Windows Docker。~~ **（已过时,见上节:核心网实际跑在 WSL 原生 dockerd。）**

## 下一步 OTA 测试

1. 接入 USRP B210，确认 Windows 或 WSL 可见（`usbipd attach` 挂进同一 WSL）。
2. 确认使用屏蔽箱或足够衰减，避免在许可频段外辐射。
3. 运行 `bash scripts/start-srsenb.sh docker`（或 `native`）启动 srsRAN 4G eNB；**先确认启动 banner 打印 EARFCN 3350 / `device_args=type=b200`**（`enb.conf` 里 `dl_earfcn` 仍是注释的 `#3150`，须确认频点由模板/env 正确注入）。
4. 手机手动选网 `00101`，配置 APN `internet` 和 `ims`，开启 VoLTE。
5. 观察 `mme`、`pcscf`、`scscf` 日志，验证 attach、PDN、IMS REGISTER 和 VoLTE 呼叫。
6. **重点验用户面数据（当前唯一未证明的一环）**：真机 attach 后能否上网 / 收发 ims APN 数据。可在 UPF 抓 `udp port 2152` 确认上行 GTP-U 到达、UE 能 ping 通 `192.168.100.1`。**数据面不通则 VoLTE 媒体也不通**。
7. 号码互打：拨对方 **MSISDN**（如 `12345678906`）即可，IMS 靠 `msisdn_list` 隐式注册路由到被叫（已实测，无需 ENUM）。

> **兜底**：真机 / 射频翻车时，`bash scripts/start-zmq-sim.sh` 展示 srsUE 经核心网 attach（证明核心网正确），再由 PC / Android 软电话走 IP 互打音视频；ZMQ 用户面数据不通不影响该兜底。演示务必在**常驻 WSL 终端**内操作（避免发行版被回收）。
