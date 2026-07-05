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

启动核心网和 IMS：

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

## 未完成条件

- USRP B210 将于 7/6 接入，完成 OTA 真机空口测试（VoLTE 主线的最终形态）。射频以外的全链路已在 ZMQ 过渡验证中打通。
- Docker Desktop 的 Ubuntu WSL daemon bridge 当前不可用；这是 Docker Desktop 集成代理状态，不是缺少 Ubuntu 包。核心网已改走 Windows Docker，不影响当前核心网运行。

## 下一步 OTA 测试

1. 接入 USRP B210，确认 Windows 或 WSL 可见。
2. 确认使用屏蔽箱或足够衰减，避免在许可频段外辐射。
3. 运行 `scripts/start-srsenb.sh` 启动 srsRAN 4G eNB。
4. 手机手动选网 `00101`，配置 APN `internet` 和 `ims`。
5. 观察 `mme`、`pcscf`、`scscf` 日志，验证 attach、PDN、IMS REGISTER 和 VoLTE 呼叫。
