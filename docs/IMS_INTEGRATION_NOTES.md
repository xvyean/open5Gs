# IMS 接入与联调关键结论（2026-07-04）

本文记录把实践 1/2 的自研 SIP 软电话（PC 端 + Android 端）接入 shijian 的
Open5GS + Kamailio IMS 网络的关键技术结论，供联合实践验收与报告使用。

## 1. 网络拓扑与身份

- 核心网/IMS：`third_party/docker_open5gs`（herlesupreeth 版），4G VoLTE 部署
  `4g-volte-deploy.yaml`，共 21 个网元容器。
- PLMN：MCC `001` / MNC `01`。IMS 域：`ims.mnc001.mcc001.3gppnetwork.org`。
- P-CSCF：`172.22.0.21:5060`（UDP/TCP），Server 头标识 `TelcoSuite Proxy-CSCF`。
- rtpengine：`172.22.0.16`，负责媒体锚定/中继。
- 两张卡（config/subscribers.csv）：
  - 卡5 IMSI `001012345678905` / MSISDN `12345678905`
  - 卡6 IMSI `001012345678906` / MSISDN `12345678906`
  - Ki `000102030405060708090A0C0B0D0E0F`，OPc `C6413837878F5B826F4F8162A1C8D879`

## 2. 两种鉴权路径（关键）

Kamailio S-CSCF 的 REGISTER 路由对“非 IMS 软电话”做了兼容（配置里注释
`force to MD5 for zoiper.... non-ims`）：当 REGISTER 的 Authorization 未带
AKA 算法时，强制走 **MD5 SIP Digest**。

- **真机（白卡）走 LTE 空口**：手机原生 IMS 栈用 **IMS-AKA**（Ki/OPc），
  已在 pyHSS 用 AuC 配好，无需改动。这是 2 台真机 VoLTE 的主线。
- **自研软电话（无 SIM）**：走 **MD5 SIP Digest**。pyHSS 对 `Digest-MD5`
  直接把该卡的 **Ki 当作口令**返回给 S-CSCF 校验
  （`lib/database.py` 中 `vector_dict['SIP_Authenticate'] = key_data['ki']`）。

### 软电话接入 IMS 的配置配方（已实测 REGISTER 200 OK）

| 项 | 值 |
| --- | --- |
| 注册地址/AOR（IMPU） | `sip:001012345678905@ims.mnc001.mcc001.3gppnetwork.org` |
| 鉴权用户名（IMPI） | `001012345678905@ims.mnc001.mcc001.3gppnetwork.org` |
| 口令 | 该卡 Ki：`000102030405060708090A0C0B0D0E0F` |
| Realm/域 | `ims.mnc001.mcc001.3gppnetwork.org` |
| 注册/代理服务器 | P-CSCF `172.22.0.21:5060`（真机走 LTE 时由核心网下发/路由） |
| 传输 | UDP，Contact 必须带 `;transport=udp` |

pyHSS 用 IMPI 的 `@` 前部分当 **IMSI** 查订户，因此 IMPI/IMPU 的用户名部分
必须是 IMSI。互相呼叫时被叫号即对方 IMSI（如呼 `sip:001012345678906@域`）。

> 对自研 `SipClient`：把登录“用户名”填 IMSI、“密码”填 Ki、“服务器 IP”填
> IMS 域名（需能解析到 P-CSCF）即可，无需改客户端代码（其 URI 用
> `user@server` 拼装、realm 从挑战里取、已支持 qop=auth 的 MD5 Digest）。

## 3. P-CSCF 的 QoS/Rx 门禁（WITH_RX）

P-CSCF 默认 `#!define WITH_RX`（`pcscf/pcscf.cfg:140`），会在 REGISTER 时经
Rx 接口向 PCRF 校验该 UE 的 IP 是否有 Gx 承载会话。后果：

- 真机/仿真 UE 在 LTE `ims`/`internet` 承载上有 Gx 会话 → 通过。
- **PC 端没有蜂窝承载、任意 IP 的软电话** → 被拒 `403 Can't register to QoS for signalling`。

因此若要让 **PC 端软电话**也注册进同一套 IMS，需要放开该门禁：把
`pcscf/pcscf.cfg` 的 `#!define WITH_RX` 注释为 `##!define WITH_RX` 后重启
`pcscf`。已备份原文件为 `pcscf/pcscf.cfg.with_rx.bak`。

- 现状：本机已放开 WITH_RX 用于联调验证。
- 演示取舍：2 台真机走空口可保留/不依赖该门禁；PC 端要进 IMS 则需放开。
  是否在最终演示保留“真机专用承载 QoS”由小组定。

## 4. 已实测结论

- 环境 21 网元全部 Up；MME S1AP 36412 + 与 HSS 的 Diameter 已连；pyHSS
  `/oam/ping` OK；三个 CSCF 的 Cx Diameter 与 pyHSS 已通（3875）。
- 卡5、卡6 软电话 **REGISTER → 401(MD5挑战) → 200 OK** 均成功
  （`scripts/ims_register_test.py`、`scripts/ims_call_test.py`）。
- 主叫 INVITE **完整穿过 IMS**（orig P-CSCF → S-CSCF → term S-CSCF →
  term P-CSCF），并触发 **rtpengine** 做 offer/answer 媒体锚定（日志
  `NATMANAGE` 段）。
- **（2026-07-04 更新）终呼与完整呼叫已闭环复测通过**：以两个独立 IP 端点
  （主叫 = ZMQ 仿真的 `srsue_zmq` 172.22.0.34，被叫 = 独立容器 172.22.0.26）
  跑 `scripts/ims_ue.py`，得到完整链路
  **REGISTER 200 → INVITE → 100/180 → 200 OK（rtpengine 锚定 audio+video）
  → ACK → BYE 200 OK**，主被叫双方日志均确认收到 ACK/BYE，通话干净建立与挂断。

### 终呼复测中定位并修复的两个问题（关键，写进报告）

1. **终呼被 P-CSCF 按 TCP 投递导致 477**：root cause 不是"模拟器假象"，而是
   `pcscf/kamailio_pcscf.cfg` 里的 `udp_mtu = 1300` + `udp_mtu_try_proto = TCP`
   —— 任何大于 1300 字节的终呼 INVITE（带完整 SDP，本例即是）会被核心**静默
   改用 TCP** 投递到被叫 Contact；若被叫是**只监听 UDP** 的软电话，TCP 连接被
   拒（`Connection refused`）→ P-CSCF 回 `477`。
   - 修复：注释掉这两行（已备份 `kamailio_pcscf.cfg.udp_mtu.bak`），重启
     `pcscf`。之后终呼稳定走 UDP，被叫收到 INVITE。
   - 备选（不改核心网时）：让软电话/客户端**同端口同时监听 TCP**即可正常收终呼
     （`ims_ue.py` 的被叫已实现 udp+tcp 双监听，作为演示兜底）。
2. **对话内 ACK/BYE 得到 `404 Not here`**：本栈 P-CSCF 对 UDP 客户端的 200 OK
   **不回 Record-Route**，故 UAC 路由集为空；按 RFC 3261 12.1.2，此时 ACK/BYE
   应**直接发往对端 Contact 地址**，而不是发回 P-CSCF（发回会命中
   `route[WITHINDLG]` 末尾的 `sl_send_reply("404","Not here")`）。`ims_ue.py`
   已改为：有 Record-Route 时走路由集首跳，无则直发 Contact 主机:端口。

## 5. 测试脚本

- `scripts/ims_register_test.py <pcscf_ip> <port> <imsi> <ki>`：单端 REGISTER 验证。
- `scripts/ims_call_test.py [--route]`：卡5/卡6 双端注册 + 主叫 INVITE 验证。
- `scripts/ims_ue.py`：**单角色端到端呼叫验证**，两端各跑一个独立容器以获得
  独立源 IP（对应 2 手机 / 1 PC 的真实拓扑）。被叫同端口 UDP+TCP 双监听。
  - 被叫：`python3 ims_ue.py callee <imsi> <ki> [秒数]`（注册后自动应答 INVITE）。
  - 主叫：`python3 ims_ue.py caller <imsi> <ki> <被叫imsi>`（INVITE→ACK→保持3s→BYE）。
  - 实测跑法（被叫放 `webui` 容器、主叫放 `srsue_zmq` 容器，二者 IP 不同）：
    ```
    docker cp scripts/ims_ue.py webui:/tmp/ims_ue.py
    docker cp scripts/ims_ue.py srsue_zmq:/tmp/ims_ue.py
    docker exec webui sh -c "nohup python3 /tmp/ims_ue.py callee 001012345678906 <Ki> 45 > /tmp/callee.log 2>&1 &"
    docker exec srsue_zmq python3 /tmp/ims_ue.py caller 001012345678905 <Ki> 001012345678906
    docker exec webui cat /tmp/callee.log
    ```
- 需在 `docker_open5gs_default` 网络内运行（宿主机无法直达 172.22.0.x）。
  例：`docker cp` 进任一容器后 `docker exec <容器> python3 /tmp/xxx.py`。

## 6. 无 USRP 时的仿真路径

栈自带 `srsenb_zmq.yaml` / `srsue_zmq.yaml`（镜像 `docker_srslte`），可用
ZMQ 虚拟射频让 srsUE↔srsENB↔Open5GS 全软件跑通 4G 接入，作为无硬件时的
可复现验证与演示兜底。注意 `.env` 里的 `UE1_*` 是上游默认卡，需改为卡5/卡6
的 IMSI/Ki/OPc（或在 HSS 额外补配 UE1）才能让 srsUE 通过鉴权接入。
