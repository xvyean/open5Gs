# Open5GS + Kamailio IMS + srsRAN Lab

This directory is the environment project for the joint practice. It is separate
from the `sip` experiment.

The primary runnable target is LTE + VoLTE:

```text
Phone / programmable USIM
        |
     USRP B210
        |
   srsRAN 4G eNB
        |
Open5GS EPC + Kamailio IMS + pyHSS + DNS + RTPengine
```

The checked-in upstream stack is `third_party/docker_open5gs`, which provides
Open5GS, Kamailio IMS, pyHSS, srsENB, 5G SA, and VoNR compose files. The local
scripts in this directory configure it for the two supplied cards.

## Current Local Status

- WSL2 Ubuntu 24.04 is present.
- Docker Desktop and Windows `docker compose` are usable for the core network.
- Ubuntu WSL has Docker CLI, Docker Compose, UHD, PC/SC, usbutils, tcpdump, and
  build dependencies installed.
- Docker Desktop WSL daemon bridge for `Ubuntu` is still not connected on this
  machine. Use the PowerShell scripts for the running core network, or restart
  Docker Desktop WSL integration from the Docker Desktop popup/settings.
- `usbipd-win` is installed for passing USB devices into WSL.
- No USRP B210 was visible to Windows or WSL during the check.
- The active host IP selected in `.env.shijian` is `10.129.164.17`.

Run the checker any time:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-prereqs.ps1
```

## Files

- `.env.shijian`: lab PLMN, host IP, UE subnets, and radio defaults.
- `config/subscribers.csv`: card 5 and card 6 IMSI/MSISDN/Ki/OPc records.
- `config/docker-compose.enb-external.override.yaml`: exposes S1AP and GTP-U for
  an external eNB.
- `scripts/bootstrap-wsl.sh`: installs WSL packages for UHD, SIM reader, and
  packet capture.
- `scripts/build-images.sh`: builds Open5GS, Kamailio IMS, srsRAN images.
- `scripts/start-core-ims.ps1`: starts Open5GS EPC + Kamailio IMS through
  Windows Docker.
- `scripts/start-core-ims.sh`: starts Open5GS EPC + Kamailio IMS through WSL
  Docker integration.
- `scripts/provision-subscribers.sh`: writes Open5GS HSS records and generates
  pyHSS IMS payloads.
- `scripts/provision-pyhss.ps1`: writes pyHSS APN, AuC, subscriber, and IMS
  subscriber records.
- `scripts/start-srsenb.sh`: starts srsENB in Docker or native mode.

## Prerequisites

1. Start Docker Desktop.
2. Docker Desktop WSL integration for `Ubuntu` is optional for the core network.
   If Docker shows a WSL integration timeout, choose "Skip WSL distro
   integration" and use the PowerShell scripts below.
3. Connect USRP B210 over USB 3.0. If WSL cannot see it, install `usbipd-win`
   and attach the USB device to WSL.
4. Use a shield box, RF attenuators, or a lab-isolated setup. Do not radiate on
   licensed spectrum outside the lab.
5. Use test PLMN `001/01`, matching the provided IMSIs.

## Setup

From PowerShell:

```powershell
cd G:\study\Third\lab\shijian
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-prereqs.ps1
```

From Ubuntu WSL:

```bash
cd /mnt/g/study/Third/lab/shijian
bash scripts/bootstrap-wsl.sh
bash scripts/configure-env.sh
```

Build or pull images. Pull mode is the default and is much faster:

```bash
bash scripts/build-images.sh pull
```

Start core network and IMS from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-core-ims.ps1
```

If the Docker Desktop Ubuntu integration popup is active, skip WSL config
generation and use the already generated compose environment:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-core-ims.ps1 -SkipConfigure
```

The Bash scripts that call `docker` require Docker Desktop's WSL daemon bridge
to be healthy. If `check-prereqs.ps1` reports `Docker Desktop WSL daemon bridge`
as failed, keep using the PowerShell scripts.

If WSL Docker integration is healthy, the Bash equivalent is:

```bash
bash scripts/start-core-ims.sh
```

Useful URLs after startup:

- Open5GS WebUI: `http://10.129.164.17:9999` (`admin` / `1423`)
- pyHSS Swagger: `http://10.129.164.17:8080/docs/`
- Grafana: `http://10.129.164.17:3000` (`open5gs` / `open5gs`)

Provision the two cards into Open5GS HSS:

```bash
bash scripts/provision-subscribers.sh
```

If WSL Docker integration is unavailable, use Windows Docker directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-subscribers.ps1
```

Provision pyHSS APN, AuC, subscriber, and IMS subscriber data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-pyhss.ps1
```

Start the radio side:

```bash
# Docker mode, using docker_open5gs' srsENB container
bash scripts/start-srsenb.sh docker

# Native mode, if srsRAN_4G is installed in WSL
bash scripts/start-srsenb.sh native
```

## Phone Settings

Print subscriber and APN settings:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\print-ue-settings.ps1
```

APNs:

- `internet`: APN `internet`, IPv4, type `default,supl`
- `ims`: APN `ims`, IPv4, type `ims`

Enable VoLTE on the phone. If the network is not selected automatically, use
manual network selection and choose PLMN `00101`.

## Verification

Static project validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-lab-config.ps1
```

Runtime checks:

```bash
docker ps
docker logs -f mme
docker logs -f hss
docker logs -f pcscf
docker logs -f scscf
docker logs -f srsenb
```

Expected milestones:

1. `mme` starts and listens on SCTP `36412`.
2. `sgwu` exposes UDP `2152`.
3. srsENB completes S1 setup with MME.
4. Phone camps on PLMN `00101`.
5. Open5GS WebUI shows the UE attached.
6. Phone gets an `internet` APN address.
7. IMS APN is established.
8. SIP REGISTER reaches P-CSCF/S-CSCF and VoLTE call setup can be tested.

## Sources

- Open5GS Dockerized VoLTE Setup: https://open5gs.org/open5gs/docs/tutorial/03-VoLTE-dockerized/
- Open5GS Your First LTE: https://open5gs.org/open5gs/docs/tutorial/01-your-first-lte/
- Open5GS VoLTE Setup with Kamailio IMS: https://open5gs.org/open5gs/docs/tutorial/02-VoLTE-setup/
- srsRAN Project OTA/Open5GS example: https://docs.srsran.com/projects/project/en/latest/tutorials/source/srsUE/source/index.html
- Kamailio IMS notes: https://www.kamailio.org/wikidocs/tutorials/ims/installation-howto/
