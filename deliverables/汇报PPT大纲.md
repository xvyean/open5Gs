# 项目汇报 PPT 大纲（03 组）

> 时长要求：PPT 汇报 5 分钟 + 系统演示与交流 20 分钟（合计 25 分钟）。
> 本大纲共 9 页，按每页约 30~35 秒设计。讲稿只列要点句，实际汇报可口语化。

## 第 1 页　封面

- 标题：基于 Open5GS + Kamailio IMS + srsRAN 的端到端 4G VoLTE 网络搭建与音视频互通
- 小组编号：03 组；成员：【待填：成员名单】；指导教师：刘传昌
- 讲稿：各位老师好，我们是 03 组。我们的题目是搭建端到端 4G VoLTE 网络，并把实践 1 的 PC 客户端和实践 2 的 Android 客户端接入，实现音视频互通。

## 第 2 页　实践目标与总体思路

- 要点：① Open5GS 核心网 + srsRAN 接入网 + USRP B210 + 白卡真机搭 4G 网络；② 集成 Kamailio IMS 提供 VoLTE；③ 自研 PC/Android 客户端接入实现音视频互通
- 思路：全栈容器化（docker_open5gs），空口采用 USRP B210 真实射频（硬件到货前以 ZMQ 虚拟射频做过渡验证）
- 讲稿：整体分三层——核心网、IMS、终端，全部网元跑在 Docker 里。空口以 USRP B210 承载真机白卡；在拿到 USRP 之前，我们先用 ZMQ 虚拟射频把射频以外的全链路验证通过，降低现场调试风险。

## 第 3 页　系统架构图

- 要点：拓扑图（手机/白卡 → USRP B210（射频）→ srsRAN eNB → Open5GS EPC → Kamailio IMS（P/I/S-CSCF + pyHSS + DNS + rtpengine）→ PC/Android 客户端；ZMQ 为硬件到货前的过渡验证路径，可括注）
- 标注：PLMN 001/01；IMS 域 ims.mnc001.mcc001.3gppnetwork.org；21 个容器
- 讲稿：这是系统架构。信令面从 eNB 经 S1 进 MME，IMS 注册和呼叫经 P、I、S 三级 CSCF，用户数据在 pyHSS，媒体由 rtpengine 锚定。整套环境共 21 个网元容器。

## 第 4 页　环境与关键配置

- 要点：Windows 11 + WSL2 Ubuntu 24.04 + Docker Desktop；两张白卡 IMSI 001012345678905/906；APN internet + ims；Band 3 / EARFCN 3350
- 管理面：Open5GS WebUI、pyHSS Swagger、Grafana
- 讲稿：环境是单机 Windows + WSL2 + Docker。两张白卡按测试 PLMN 00101 开户，各配 internet 和 ims 两个 APN，开户脚本以 subscribers.csv 为单一数据源，一键写入 HSS 和 pyHSS。

## 第 5 页　关键技术点 1：两条鉴权路径

- 要点：真机白卡 → IMS-AKA（Ki/OPc，pyHSS AuC）；自研软电话 → S-CSCF 兼容逻辑强制 MD5 Digest，pyHSS 把 Ki 当口令
- 客户端零改动：用户名填 IMSI、密码填 Ki、服务器填 IMS 域
- 讲稿：IMS 鉴权我们走两条路：真机用标准 IMS-AKA；自研客户端没有 SIM，利用 S-CSCF 对非 IMS 终端的 MD5 兼容路径接入，客户端代码不用改。

## 第 6 页　关键技术点 2：踩坑与解决

- 要点三条：① Docker Desktop WSL bridge 异常 → 核心网改走 Windows Docker + PowerShell 脚本；② P-CSCF WITH_RX 门禁把无承载的 PC 软电话拒为 403 → 注释 WITH_RX 放行；③ 单机模拟器双 UE 共用 IP 仅监听 UDP 导致终呼 477 → 确认为假象，真实独立 IP 端点不受影响
- 讲稿：过程中解决了三个典型问题（逐条一句话带过）。这三个问题的定位过程写在实验报告里。

## 第 7 页　测试与验证结果

- 要点：21 容器全部 Up；MME S1AP + HSS Diameter 已连；CSCF↔pyHSS Cx 已通；卡5/卡6 REGISTER→401→200 OK 实测通过；INVITE 完整穿过 IMS 并触发 rtpengine 媒体锚定
- 【截图：注册 200 OK 与 INVITE 日志】
- 讲稿：验证结果——注册和呼叫信令链路已经全部实测打通，媒体面 rtpengine 也已正确介入。空口侧【待填：按实际情况说 ZMQ 仿真/OTA 的最新结果】。

## 第 8 页　分工与贡献度

- 要点：分工表（部署 / IMS 联调 / PC 客户端 / Android 客户端 / 报告 PPT）+ 各成员贡献度
- 讲稿：分工如表所示，贡献度为【待填】。

## 第 9 页　总结与演示预告

- 要点：已完成核心网 + IMS + 客户端链路；演示环节将展示环境状态、UE 接入、双端注册与互打音视频
- 讲稿：下面进入演示环节，我们按照从底层到上层的顺序展示整个系统。

---

# 20 分钟演示脚本

> 演示要求：在 4G/5G 仿真环境下进行，2 台手机 + 1 台 PC。
> 建议提前 30 分钟完成预启动，演示时只做"检查 + 操作"，不现场冷启动。
> 每步给出：操作 → 预期现象 → 兜底方案。

## 步骤 0（演示前准备，不占用演示时间）

- 操作：`start-core-ims.ps1` 启动全套容器；确认 WITH_RX 门禁状态与演示口径一致；准备好两部手机 / ZMQ srsUE、PC 客户端、Android 客户端；提前录好一段完整成功流程的备份视频。
- 兜底总原则：任何一步现场失败，展示对应的日志/截图/备份视频并口头说明原理，继续后面步骤。

## 步骤 1　启动状态检查（约 2 分钟）

- 操作：`docker ps` 展示容器列表；`docker logs mme | tail` 展示 S1AP 36412 监听与 HSS Diameter 连接。
- 预期现象：21 个容器全部 `Up`；MME 日志显示 S1AP 已启动。
- 兜底：个别容器不健康则 `docker restart <容器>`；仍失败则展示【截图：docker ps 全部 Up】并继续。

## 步骤 2　WebUI 查看订户（约 2 分钟）

- 操作：浏览器打开 Open5GS WebUI（`http://10.129.164.17:9999`，admin/1423）展示卡5/卡6 订户及 internet/ims 两个 APN；可加开 pyHSS Swagger `/docs/` 查询 IMS subscriber。
- 预期现象：两条订户记录完整，IMSI 001012345678905/906。
- 兜底：WebUI 打不开则用 `provision-*.ps1` 的输出或 pyHSS API 查询结果替代。

## 步骤 3　UE 空口接入与 attach（约 3 分钟）

- 主线（USRP + 真机）：接入 USRP B210 启动 srsENB（`scripts/start-srsenb.sh`），真机手动选网 `00101` → attach → 手机状态栏出现 VoLTE 图标；WebUI 可见 UE 在网、获得 internet/ims APN 地址。
- 过渡验证已备（无硬件时/对照演示）：`start-zmq-sim.ps1` 启动 srsENB+srsUE 的 ZMQ 虚拟射频，srsUE（卡5）已实测 attach 成功——日志 `Found PLMN 00101` → `RRC Connected` → `Network attach successful. IP: 192.168.100.2`。可作为「射频之外全链路已通」的佐证同时展示。
- 预期现象：eNB 完成 S1 Setup；UE 鉴权通过并 attach，拿到 internet APN（192.168.100.x），ims APN 建立。
- 兜底：attach 失败先核对 UE 侧 IMSI/Ki/OPc 与 HSS 记录一致；仍失败则展示 mme 日志与已录制的 ZMQ attach 成功日志说明流程，并声明 IMS 侧演示不依赖此步（软电话可直连 P-CSCF）。

## 步骤 4　PC / Android 客户端注册 IMS（约 4 分钟）

- 操作：PC 客户端（实践 1）用卡5 身份、Android 客户端（实践 2）用卡6 身份登录：用户名填 IMSI、密码填 Ki、域 `ims.mnc001.mcc001.3gppnetwork.org`。
- 预期现象：两端各自 REGISTER → 401（MD5 挑战）→ 200 OK，界面显示注册成功。
- 兜底：失败则运行 `scripts/ims_register_test.py`（在 pyhss 容器内执行）证明 IMS 注册链路正常，把问题隔离到客户端配置；同时展示【截图：REGISTER 200 OK】。

## 步骤 5　双端互打音视频（约 5 分钟）

- 操作：PC 呼 Android（被叫填对方 IMSI，如 `001012345678906`），接通后双向通话；再反向 Android 呼 PC；有条件则演示视频通话。
- 预期现象：被叫振铃、接通，语音（及视频）双向可通；媒体经 rtpengine 中继。
- 兜底：若终呼投递异常（477），说明其根因已定位为 P-CSCF `udp_mtu` 强制切 TCP 并已修复（客户端亦可同端口监听 TCP 兜底）；改用 `scripts/ims_ue.py` 双端演示 REGISTER→INVITE→200(rtpengine)→ACK→BYE 的完整信令流；最后放备份视频【待填：备份视频路径】。

## 步骤 6　查看 CSCF / rtpengine 日志收尾（约 2 分钟）

- 操作：`docker logs pcscf / scscf / rtpengine` 截取刚才呼叫的时间段，指出 INVITE 路径（orig P-CSCF → S-CSCF → term S-CSCF → term P-CSCF）与 rtpengine 的 offer/answer（NATMANAGE 段）。
- 预期现象：日志与刚才的呼叫一一对应，证明呼叫确实经过 IMS 而非客户端点对点直连。
- 兜底：现场日志刷屏则用预先保存的日志文件讲解。

## 剩余时间　答辩交流（约 2 分钟机动）

- 预留提问；常见问题准备：为什么放开 WITH_RX、MD5 与 AKA 的差别、rtpengine 的作用、终呼 477 的根因（udp_mtu）、ZMQ 过渡验证与 USRP 真机测试的关系（前者证明射频外全链路正确、后者为最终形态）。
