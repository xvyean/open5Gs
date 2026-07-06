# USRP B210 真机 OTA VoLTE 测试流程

> 适用:B210 到货后,用**真实 4G 空口**让 2 部手机(白卡)接入 Open5GS + Kamailio IMS,完成注册与 VoLTE 音视频呼叫,并与 PC 客户端三方互通。
> 前置:核心网 + IMS 已按 `README.md` 启动并开户(HSS + pyHSS)。无硬件时的仿真验证见 README【步骤5·路径A(ZMQ)】。

---

## 0. 器材与参数清单

**硬件**
- USRP B210 ×1、USB 3.0 线(必须 USB3,USB2 供电/带宽不足会掉线)
- 天线:**2 根**(一根接 `TX/RX A`,一根接 `RX2 A`),或用 Band 3 双工器
- **屏蔽箱 / 射频衰减器**(20–40 dB):必须,严禁对空辐射
- 手机 ×2:需支持 **LTE Band 3** 且支持 **VoLTE**
- 白卡(卡5、卡6)——**已按 `卡信息.txt` 预烧,无需读卡器**;仅当附着鉴权失败需排查/重烧时才另借 PC/SC 读卡器

**关键无线参数(已在 `runtime/srsran4g/` 与 `.env.shijian` 配好)**

| 项 | 值 |
|---|---|
| 频段 / EARFCN | Band 3 FDD / DL `3350`(≈1857.5 MHz,UL≈1762.5 MHz) |
| 带宽 | 10 MHz(`n_prb=50`) |
| PLMN | MCC `001` / MNC `01` → 手动选网 `00101` |
| TAC / PCI / cell_id | 1 / 1 / 0x01 |
| SDR device_args | `type=b200,master_clock_rate=23.04e6` |
| 发射/接收增益 | `tx_gain=80` / `rx_gain=40`(屏蔽箱内近距离可下调,见排障) |

**安全:** 只在屏蔽箱或经衰减的隔离环境测试;测试频段为示教用途,不得在许可频段对外发射。

---

## 1. 确认核心网 + IMS 就绪(先决条件)

> **重要(引擎归属):** 本套核心网当前跑在 **WSL Ubuntu 的原生 dockerd**(`docker context = default`,主机名 `tean`),**不是** Windows 的 Docker Desktop。
> B210 之后也用 `usbipd attach` 挂进同一个 WSL,eNB 容器才能透传到 `/dev/bus/usb`。
> **不要**跑 `start-core-ims.ps1`——那会在 Docker Desktop 里另起一套,导致双栈/端口冲突。核心网操作一律在 **WSL 内**做:

```bash
# WSL 内(核心网已长期 Up 时无需重复启动;需要启动时):
cd /g/study/Third/lab/shijian && bash scripts/start-core-ims.sh
docker ps                      # 21 个容器 Up
docker logs mme | tail         # 看到 S1AP 36412 已监听、已连 HSS
```

确认两张卡已写入 HSS 与 pyHSS(**本套已核验:mongo 与 ims_hss_db 均含 …905/…906,无需重跑**;如需重做):

```bash
# WSL 内
docker exec mongo mongosh --quiet open5gs --eval 'db.subscribers.find({},{_id:0,imsi:1}).toArray()'
docker exec mysql sh -lc 'mysql -uroot -N -e "select imsi from ims_hss_db.subscriber; select msisdn from ims_hss_db.ims_subscriber;"'
# 若为空才需 provision(在 WSL 内跑 .sh 版本,勿用 .ps1)
```

> **卡数据必须三处一致**:物理卡 ⟷ Open5GS HSS ⟷ pyHSS。基准值见 `卡信息.txt`:
> 卡5 IMSI `001012345678905`,卡6 IMSI `001012345678906`,两卡 Ki `000102030405060708090A0C0B0D0E0F`,OPc `C6413837878F5B826F4F8162A1C8D879`。

---

## 2. 写卡 / 验卡(物理白卡对齐 HSS)

> **本环境实际情况:卡5/卡6 已由供应商按 `卡信息.txt` 烧录好,手头没有 PC/SC 读卡器 → 本节 2.1~2.3 全部跳过。**
> 网络侧(Open5GS HSS + pyHSS)本就是用同一份 `卡信息.txt` 开的户,且已实测两库数据一致;因此只要**物理卡确实等于 `卡信息.txt`**,三处就一致。
> 没有读卡器就无法离线核对,**验证改到"附着阶段"**做(见 §5:`mme` 打出 Attach accept = 卡的 Ki/OPc 与 HSS 匹配)。
>
> **烧录唯一盲点(建议向供应商确认一句):** 卡必须烧的是 **OPc = `C6413837878F5B826F4F8162A1C8D879`(不是 OP)**,IMSI/Ki 与 `卡信息.txt` 逐位一致。这是没读卡器时唯一查不了、又最常翻车的点。
> 万一 §5 附着报鉴权失败(Authentication reject / MAC failure)= 卡 ≠ HSS,此时才需借一台读卡器走下面的 pySim 流程(已装好,见 2.1)排查或重烧。

**⬇️ 以下 2.1~2.3 仅在"能借到读卡器且需排查/重烧"时才用;正常流程直接跳到 [§3](#3-把-b210-接入-wslusbipd)。**

### 2.1 安装 pySim(Osmocom)

> **已安装完成**(`~/pysim`,含独立 venv `~/pysim/venv`)。因 Ubuntu 24.04 是 Python 3.12,系统 `pip3` 受 PEP 668 限制,依赖装在 **venv** 里——所以下文所有 pySim 命令都用 `~/pysim/venv/bin/python`,**不要**用系统 `python3`(会 ModuleNotFoundError)。
> 如需重装:

```bash
# WSL 内
sudo service pcscd restart
git clone https://gitea.osmocom.org/sim-card/pysim ~/pysim
python3 -m venv ~/pysim/venv
~/pysim/venv/bin/python -m pip install -r ~/pysim/requirements.txt
pcsc_scan        # 插入读卡器+卡,应看到 ATR;Ctrl-C 退出
```

usbipd 把读卡器挂进 WSL 的方法同【第3节】(读卡器也是 USB 设备)。

### 2.2 读卡核对(不需要 ADM)

```bash
cd ~/pysim
~/pysim/venv/bin/python pySim-read.py -p 0        # 打印 ICCID / IMSI 等
```

核对打印的 **IMSI** 是否等于卡5/卡6 的值。一致 → 跳到【第3节】;不一致 → 2.3 写卡。

### 2.3 写卡(需要该卡的 ADM 写保护密钥)

> **ADM/PIN(ADM1)由白卡供应商随卡提供**(通常一张 CSV,每卡一个 ADM)。没有 ADM 无法写入 Ki。
> `-t` 卡型按实际白卡填(如 `sysmoUSIM-SJS1`、`sysmoISIM-SJA2`,不确定可先 `~/pysim/venv/bin/python pySim-read.py -p 0` 看识别结果)。

以**卡5**为例(卡6 把 IMSI 换成 `...906`):

```bash
cd ~/pysim
~/pysim/venv/bin/python pySim-prog.py -p 0 \
  -t sysmoUSIM-SJS1 \
  -a <该卡ADM密钥> \
  -x 001 -y 01 \
  -i 001012345678905 \
  -k 000102030405060708090A0C0B0D0E0F \
  --opc C6413837878F5B826F4F8162A1C8D879 \
  -n OPEN5GS
# 说明:-x/-y 写 MCC/MNC;-k 写 Ki;--opc 写 OPc(不是 -o/OP);
#      不带 -s 则保留卡原 ICCID(避免 Luhn 校验问题);-n 写运营商名。
```

写完**再读一次核对**:`~/pysim/venv/bin/python pySim-read.py -p 0`。

> 仓库 `third_party/docker_open5gs/sim/` 另有 pySim-shell 脚本(`readall-5g.script` 读全量、`iphone-private-5g.script` 激活 5G 文件),4G VoLTE 测试用不到 5G 部分,忽略即可。

---

## 3. 把 B210 接入 WSL(usbipd)

Windows **管理员** PowerShell:

```powershell
usbipd list                          # 找到 USRP B210 的 BUSID(厂商 Ettus / "USRP B210")
usbipd bind   --busid <BUSID>        # 首次绑定(管理员,一次即可)
usbipd attach --wsl --busid <BUSID>  # 挂进 WSL(每次插拔后都要重挂)
```

WSL 内确认:

```bash
lsusb                                # 出现 "Ettus Research LLC USRP B210"(或 2500:0020)
uhd_find_devices                     # 找到 B210
uhd_usrp_probe                       # 首次会加载 FPGA image(bootstrap 已 uhd_images_downloader)
```

> `uhd_usrp_probe` 打印出主板/子板信息即代表 UHD 与 B210 正常。若报找不到 image,跑 `sudo uhd_images_downloader` 再试。

---

## 4. 启动 srsRAN 4G eNB(docker 模式 + B210)

`srsenb.yaml` 已配 `privileged` + `/dev/bus/usb` 透传,容器内置 srsRAN,连内部 MME —— 直接用 docker 模式:

```bash
cd /g/study/Third/lab/shijian
bash scripts/start-srsenb.sh docker
```

> **docker 模式的射频参数来自哪里(重要):** `srslte_init.sh` 只用模板 `third_party/docker_open5gs/srslte/enb.conf` + `rr_enb.conf`,**不读** `.env.shijian` 的 `SRSRAN_DEVICE_ARGS/LTE_DL_EARFCN/LTE_N_PRB`。当前模板已配好:`enb.conf` 里 `device_args = type=b200,master_clock_rate=23.04e6`、`n_prb=50`;`rr_enb.conf` 里 `dl_earfcn=3350`。**要改频点/增益就改这两个模板文件**,改完重启 `srsenb` 容器生效(无需重生成 .env)。

启动成功的标志(该命令会 attach 到 srsenb 输出):

```
Opening USRP channels=1, args: type=b200,master_clock_rate=23.04e6
...
==== eNodeB started ===
```

另开一个终端验证 S1 建立:

```bash
docker logs srsenb | tail          # UHD 打开 B210、无 "No supported RF device" 报错
docker logs mme    | tail          # 看到来自 SRS_ENB_IP 的 S1 Setup Request / Response
```

> 容器内看 UHD 是否见到 B210:`docker exec srsenb uhd_find_devices`。
> 若容器里报 image 缺失,`docker exec srsenb uhd_images_downloader` 后重启 `srsenb`。

---

## 5. 手机侧配置与附着

对**每部手机**:

1. **关机 → 插入白卡 → 开机**(卡5 一部、卡6 一部)。
2. 移动网络设置 → 关闭"自动选网" → **手动选网,选 `00101`**(可能显示为运营商名 OPEN5GS 或 "001 01")。
3. **APN 配置**(两条):
   - `internet`:APN=`internet`,类型 `default,supl`(默认上网)
   - `ims`:APN=`ims`,类型 `ims`(VoLTE 信令承载)
4. 开启 **VoLTE**(设置里"通话"或"移动网络"中的 VoLTE/高清通话开关)。

**附着验证:**

```bash
docker logs -f mme                 # 看到该 IMSI 的 Attach Request → Attach Complete
```

- Open5GS WebUI(`http://<主机IP>:9999`)→ 该 UE 显示 attached。
- 手机状态栏出现 4G/信号;拿到 `internet` APN 的 IP(可用手机浏览器测试)。

---

## 6. IMS 注册与 VoLTE 呼叫验证

**6.1 IMS 注册**(手机开 VoLTE 且 `ims` APN 起来后自动发起 SIP REGISTER)

```bash
docker logs -f pcscf               # 收到手机 REGISTER
docker logs -f scscf               # 200 OK、contact 落库([registered])
```

**6.2 手机 ↔ 手机 VoLTE 呼叫**

- 手机A(卡5)拨手机B 的号码 **`12345678906`**(卡6 MSISDN);反向拨 `12345678905`。
- 预期:接通、双向通话;若终端支持视频通话,发起视频验证**音视频互通**。
- 抓信令看 `INVITE → 100/180 → 200 OK → ACK`,挂断 `BYE → 200`。

**6.3 加入 PC 客户端(达成"2 手机 + 1 PC")**

- PC 客户端按 `README.md`【步骤6】接入 IMS:服务器填域名 `ims.mnc001.mcc001.3gppnetwork.org`、hosts 映射、用一张卡登录(与两部手机不同的身份)。
- PC ↔ 手机 双向拨打,验证三方互通与音视频。

**6.4 抓包/留档(验收证据)**

```bash
# 在 pcscf 抓 SIP,rtpengine 抓 RTP(示例)
docker exec pcscf sh -c "tcpdump -i any -w /tmp/ims_sip.pcap port 5060" &
# 完成一通呼叫后停止,拷出:
docker cp pcscf:/tmp/ims_sip.pcap ./runtime/ota_ims_sip.pcap
```

同时保存:`mme`/`pcscf`/`scscf`/`srsenb` 日志、WebUI attached 截图、手机通话中截图。

---

## 7. 常见问题排查

| 现象 | 可能原因 / 处理 |
|---|---|
| 手机搜不到 `00101` | 手机不支持 Band 3 → 改 `.env.shijian` 的 `LTE_DL_EARFCN` 到手机支持的频点,`configure-env.sh` 后重启 eNB;确认天线接 `TX/RX A`+`RX2 A`;屏蔽箱内先把 `tx_gain` 调到 60–70 避免饱和 |
| 搜到网但附着失败(鉴权失败/MAC failure) | 卡的 Ki/OPc 与 HSS 不一致。无读卡器时先向供应商确认烧的是 **OPc(非 OP)**、IMSI/Ki 与 `卡信息.txt` 逐位一致;确认 provision 已写入(HSS/pyHSS 双库);MNC 必须 2 位 `01`。仍失败再借读卡器走【第2节】pySim 读卡对比/重烧 |
| 附着成功但无 IMS 注册 | 未开 VoLTE;`ims` APN 未配或类型不对;P-CSCF 地址经 PCO 下发,查 `docker logs pcscf` 是否收到 REGISTER |
| 能注册不能通话 / 无声音 | 见 `README.md`【已知问题】:477(udp_mtu)、404(Record-Route);媒体不通查 rtpengine 通告 IP(`apply-client-access.ps1` 里 `DOCKER_HOST_IP`)与编解码 |
| `uhd_find_devices` 找不到 B210 | usbipd 重新 `attach`;换 USB3 口;`sudo uhd_images_downloader`;供电不足→用带供电的 USB3 或外接电源 |
| eNB 频繁掉 UE / RLF | 增益过高或过低,微调 `tx_gain`/`rx_gain`;USB2 带宽不足;CPU 占满→关其它负载 |
| B210 过热 | 加散热/风扇,长测降 `tx_gain` |

---

## 8. 演示编排(验收:2 手机 + 1 PC,4G 仿真环境)

```
  手机A(卡5) ──┐                          ┌── 手机B(卡6)
               │   B210 真实 4G 空口        │
               └──►  srsRAN eNB  ──► Open5GS EPC + Kamailio IMS ◄── PC 客户端(IP)
```

演示脚本建议:
1. 展示 eNB 起来、两部手机 attach(WebUI)。
2. 手机A ↔ 手机B VoLTE 通话(音频 + 视频)。
3. PC 客户端注册,PC ↔ 手机 通话。
4. 展示信令/抓包与日志,说明"接入→注册→呼叫→媒体"全链路。

---

## 9. 停止

```bash
# 停 eNB:Ctrl-C 退出 attach,然后
cd /g/study/Third/lab/shijian/third_party/docker_open5gs && docker compose -f srsenb.yaml down
```

```powershell
powershell -File .\scripts\stop-core-ims.ps1     # 需要时停核心网
```

---

## 附:一次完整 OTA 测试的最小命令序列

```bash
# 1) 核心网+IMS+开户(README 步骤2-3)已完成
# 2) 卡:已预烧(卡信息.txt),无读卡器 → 跳过,验证放到附着阶段(见步骤5 mme Attach accept)
# 3) 挂 B210(Windows 管理员)
#    usbipd attach --wsl --busid <BUSID>
uhd_usrp_probe                                       # WSL 内确认 B210
# 4) 起 eNB
cd /g/study/Third/lab/shijian && bash scripts/start-srsenb.sh docker
# 5) 手机:选网 00101 + APN internet/ims + 开 VoLTE → attach
docker logs -f mme      # Attach Complete
docker logs -f scscf    # IMS registered
# 6) 手机A 拨 12345678906 → VoLTE 音视频;PC 客户端加入三方
```
