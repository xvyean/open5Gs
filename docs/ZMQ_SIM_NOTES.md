# ZMQ 虚拟射频 4G 仿真（srsENB + srsUE，无 USRP 硬件）

无 B210 硬件时，用上游 docker_open5gs 自带的 ZMQ 虚拟射频方案在纯软件里跑通
`srsUE ↔ srsENB ↔ Open5GS EPC` 的 4G attach，用于验收演示。

## 链路结构

```
srsue_zmq (172.22.0.34)          srsenb_zmq (172.22.0.22)          EPC 核心网
  soft-USIM: 卡5                   enb_id=0x19B, PCI=1, 50 PRB
  IMSI 001012345678905             MCC/MNC/TAC = 001/01/1
        |                                 |
        |  I/Q over ZMQ (TCP):            |  S1AP  -> mme  172.22.0.9:36412
        |  UE tx 绑定 tcp://172.22.0.34:2001                (sctp)
        |  eNB tx 绑定 tcp://172.22.0.22:2000  GTP-U -> sgwu 172.22.0.6:2152
        |  对端互为 rx_port                |
        +---------------------------------+
     以上全部挂在外部网络 docker_open5gs_default（4g-volte-deploy.yaml 创建）
```

- 两个容器的镜像都是 `docker_srslte`（compose 里无 build 段，必须先有镜像：
  `bash scripts/build-images.sh pull` 会拉取 `ghcr.io/herlesupreeth/docker_srslte:master`
  并打 tag；本地 `build` 模式要从源码编译 srsRAN 4G，非常慢，优先 pull）。
- 环境变量来源：`third_party/docker_open5gs/.env`（compose 的 `env_file` +
  `--env-file` 插值）。容器入口 `srslte/srslte_init.sh` 按 `COMPONENT_NAME`
  选模板并 sed 替换：
  - eNB（`enb_zmq`）：`enb_zmq.conf` + `rr_enb_zmq.conf` 等，替换
    `MME_IP / MCC / MNC / SRS_ENB_IP / SRS_UE_IP / TAC`；
  - UE（`ue_zmq`）：`ue_zmq.conf`，替换
    `UE1_IMSI / UE1_KI / UE1_OP / SRS_UE_IP / SRS_ENB_IP`。
- 双方 EARFCN 已统一为 3350（与 `.env.shijian` 的 `LTE_DL_EARFCN=3350` 一致），
  采样率 `base_srate=23.04e6`。

## 本仓库相对上游的改动

| 文件 | 改动 | 原因 |
| --- | --- | --- |
| `third_party/docker_open5gs/.env` | `UE1_IMSI/UE1_KI/UE1_OP` 改为卡5凭据 | 上游默认测试卡不在 HSS 里，鉴权必失败 |
| `third_party/docker_open5gs/srslte/ue_zmq.conf` | `op = UE1_OP` → `opc = UE1_OP` | 实验卡只有 **OPc**（无 OP）。srsUE 若按 OP 处理会重新派生 OPc，与 HSS 不一致，MILENAGE 鉴权必失败 |
| `third_party/docker_open5gs/srslte/ue_zmq.conf` | `dl_earfcn` 3150 → 3350 | 与 `.env.shijian` / 硬件模板 `rr_enb.conf` 对齐 |
| `third_party/docker_open5gs/srslte/rr_enb_zmq.conf` | cell_list 里 `dl_earfcn` 3150 → 3350 | 同上，eNB/UE 两侧必须一致 |

注意：`scripts/configure-env.sh`（start-core-ims.ps1 每次会调用）只重写
MCC/MNC/TAC/IP/网段这几个键，不会碰 `UE1_*`，上述 .env 改动可以长期保留。

## 启动 / 停止

```powershell
# 1) 核心网 + IMS（会创建 docker_open5gs_default 网络）
powershell -File scripts\start-core-ims.ps1

# 2) ZMQ 仿真（脚本内部顺序：先 srsenb_zmq，等 "eNodeB started"，再 srsue_zmq）
powershell -File scripts\start-zmq-sim.ps1

# 停止（只停仿真，不动核心网）
powershell -File scripts\stop-zmq-sim.ps1
```

顺序不能乱的原因：ZMQ 两个 yaml 把网络声明为 `external: true`，核心网不先起
网络就不存在；eNB 起来才对 MME 做 S1 Setup；eNB 的 ZMQ 参数带
`fail_on_disconnect=true`，UE 掉线可能带崩 eNB 的射频侧——单独重启 UE 无效时，
把 eNB 和 UE 一起 `stop-zmq-sim.ps1` 再 `start-zmq-sim.ps1`。

## 验证清单

1. eNB 就绪：`docker logs srsenb_zmq`
   - `Opening 1 channels in RF device=zmq`
   - `==== eNodeB started ===`
   - UE 接入后出现 `RACH:  tti=..., cc=0, pci=1, preamble=..., temp_crnti=0x46`
2. S1 建立：`docker logs mme`，出现来自 172.22.0.22 的 eNB 接入 /
   `S1-Setup response`；attach 完成后有 `Attach complete` 相关字样。
3. UE attach 成功：`docker logs -f srsue_zmq`，依次期待：
   - `Found Cell:  Mode=FDD, PCI=1, PRB=50, ...`
   - `Found PLMN:  Id=00101, TAC=1`
   - `Random Access Complete.` / `RRC Connected`
   - `Network attach successful. IP: 192.168.100.X`  ← **验收关键行**
   - IP 必须落在 `internet` APN 网段 **192.168.100.0/24**
     （`ims` APN 是 192.168.101.0/24，srsUE 默认只建 internet 一个 PDN，
     没有 192.168.101.x 地址是正常的）。
4. HSS 鉴权确认（可选）：`docker logs hss` 中出现 IMSI 001012345678905 的
   Auth-Info/ULA 交互且无 `DIAMETER_AUTHENTICATION_REJECTED`。
5. 用户面 ping（在 UE 容器里走 TUN 口）：

   ```powershell
   docker exec srsue_zmq ip addr show tun_srsue
   docker exec srsue_zmq ping -c 3 -I tun_srsue 192.168.100.1   # APN 网关(ogstun)
   docker exec srsue_zmq ping -c 3 -I tun_srsue 8.8.8.8         # 经 UPF NAT 出公网
   ```

   `-I tun_srsue` 不能省：容器默认路由走 docker 网卡，不指定接口测不到 EPC 用户面。

## 已知坑

- **OP vs OPc**：上游 `ue_zmq.conf` 用 `op =`，我们的卡只有 OPc，已改为
  `opc =`（见上表）。若还原上游文件，鉴权会失败（UE 日志报
  `Network authentication failure` / MME 侧 Authentication reject）。
- **镜像**：`docker_srslte` 必须先 pull（`scripts/build-images.sh pull`），
  start 脚本会检查并给出提示。
- **compose 项目名共享**：ZMQ yaml 与核心网共用项目名 `docker_open5gs`，
  `up`/`down` 时出现 "Found orphan containers" 警告是正常的；
  **千万不要加 `--remove-orphans`**，否则会把核心网容器一并删掉。
- **CPU 占用**：ZMQ 软件射频 23.04 MHz 采样率很吃 CPU，eNB+UE 两个容器
  合计可能占满数个核；Docker Desktop 资源给足（建议 ≥4 CPU）。
- **UE 侧只有 UE1**：上游只有一套 `UE1_*` 变量、一个 srsue_zmq 容器，
  没有 UE2。要用卡6演示：改 `.env` 里 `UE1_IMSI=001012345678906`
  （Ki/OPc 两卡相同，不用动），然后重启 srsue_zmq 即可。
- **VoLTE 范围**：srsUE 没有 IMS/SIP 客户端，ZMQ 仿真只能演示 4G attach +
  数据面；IMS 注册/呼叫演示继续用 `scripts/ims_register_test.py`、
  `scripts/ims_call_test.py`（走 pcscf）。
- **5G 路径未修**：`UE1_OP` 也被 5G 组件引用——`srslte/ue_5g_zmq.conf` 仍是
  `op =`，`ueransim/ueransim-ue.yaml` 是 `opType: 'OP'`。本 4G 实验用不到；
  如果以后跑 srsue_5g_zmq / ueransim，需要把它们改成 OPc 语义才能过鉴权。
- **日志文件**：除 `docker logs` 外，srsenb/srsue 还会把日志写进挂载目录
  `third_party/docker_open5gs/srslte/enb.log`、`ue.log`（级别 warning）。
  抓包选项在 `ue_zmq.conf` / `enb_zmq.conf` 的 `[pcap]` 段，默认关闭。
