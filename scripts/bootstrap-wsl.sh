#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "[bootstrap] Installing WSL packages for Docker, USRP B210, SIM reader, and packet capture..."
APT_OPTS=(
  -o Acquire::Retries=2
  -o Acquire::http::Timeout=30
  -o Acquire::https::Timeout=30
)

$SUDO apt-get "${APT_OPTS[@]}" update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -y \
  bash-completion \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  git \
  iproute2 \
  iputils-ping \
  libboost-program-options-dev \
  libconfig++-dev \
  libfftw3-dev \
  libmbedtls-dev \
  libpcsclite-dev \
  libsctp-dev \
  net-tools \
  pcsc-tools \
  pcscd \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  tcpdump \
  uhd-host \
  usbutils

if command -v uhd_images_downloader >/dev/null 2>&1; then
  echo "[bootstrap] Downloading UHD FPGA/firmware images..."
  $SUDO uhd_images_downloader || true
fi

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files pcscd.service >/dev/null 2>&1; then
  $SUDO systemctl enable --now pcscd || true
else
  $SUDO service pcscd restart || true
fi

echo "[bootstrap] Done. If Docker is still unavailable inside WSL, enable Docker Desktop WSL integration for Ubuntu."
