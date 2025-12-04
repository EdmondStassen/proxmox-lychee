#!/usr/bin/env bash
# Proxmox helper script voor Lychee (Lychee-Docker in een LXC met Docker)
# Gebruik op de Proxmox-node:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/proxmox-lychee/refs/heads/main/helperscript.sh)"

set -euo pipefail

APP_NAME="Lychee"
DISK_SIZE_GB=20
MEMORY_MB=2048
SWAP_MB=512
CORES=2
BRIDGE="vmbr0"

echo "=== ${APP_NAME} LXC helper script ==="

# Basic checks
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Dit script moet als root worden uitgevoerd (bijv. via Proxmox shell als root)." >&2
  exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
  echo "Dit lijkt geen Proxmox VE host te zijn (pveversion niet gevonden)." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "'pct' niet gevonden – LXC tools lijken niet geïnstalleerd." >&2
  exit 1
fi

echo "- Bepaal volgende vrije CT ID..."
CTID="$(pvesh get /cluster/nextid)"
echo "  Gebruik CTID: ${CTID}"

# Storage kiezen: template vs rootfs
if ! pvesm status -content vztmpl >/dev/null 2>&1; then
  echo "Geen storage gevonden met content type 'vztmpl' (templates). Controleer je storage config." >&2
  exit 1
fi

if ! pvesm status -content rootdir >/dev/null 2>&1; then
  echo "Geen storage gevonden met content type 'rootdir'. Controleer je storage config." >&2
  exit 1
fi

TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR==2 {print $1}')"
ROOTFS_STORAGE="$(pvesm status -content rootdir | awk 'NR==2 {print $1}')"

if [[ -z "${TEMPLATE_STORAGE}" || -z "${ROOTFS_STORAGE}" ]]; then
  echo "Kon geen geschikte template- of rootdir-storage vinden." >&2
  exit 1
fi

echo "  Gebruik template storage: ${TEMPLATE_STORAGE}"
echo "  Gebruik rootfs storage:   ${ROOTFS_STORAGE}"

echo "- Zoeken naar een geschikte Debian 12 template..."
# Laat gebruiker eventueel DEBIAN_TEMPLATE overriden via env var:
DEBIAN_TEMPLATE="${DEBIAN_TEMPLATE:-}"

if [[ -z "${DEBIAN_TEMPLATE}" ]]; then
  # Probeer eerst een bekende naam
  DEFAULT_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
  if pveam available | awk '{print $2}' | grep -qx "${DEFAULT_NAME}"; then
    DEBIAN_TEMPLATE="${DEFAULT_NAME}"
  else
    # Pak eerste best passende debian-12-standard template
    DEBIAN_TEMPLATE="$(
      pveam available \
        | awk '/debian-12-standard_.*amd64\.tar\.zst/ {print $2; exit}'
    )"
  fi
fi

if [[ -z "${DEBIAN_TEMPLATE}" ]]; then
  echo "Kon geen Debian 12 template vinden in 'pveam available'." >&2
  echo "Controleer met:  pveam available | grep debian-12-standard" >&2
  echo "En probeer eventueel met: DEBIAN_TEMPLATE=naam.tar.zst bash helperscript.sh" >&2
  exit 1
fi

echo "  Gekozen Debian template: ${DEBIAN_TEMPLATE}"

echo "- Controleren of Debian template al op ${TEMPLATE_STORAGE} staat..."
if ! pveam list "${TEMPLATE_STORAGE}" | awk '{print $2}' | grep -qx "${DEBIAN_TEMPLATE}"; then
  echo "  Template niet gevonden op ${TEMPLATE_STORAGE}, download nu..."
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${DEBIAN_TEMPLATE}"
else
  echo "  Template al aanwezig op ${TEMPLATE_STORAGE}."
fi

echo "- Maak LXC container ${CTID} aan..."
pct create "${CTID}" \
  "${TEMPLATE_STORAGE}:vztmpl/${DEBIAN_TEMPLATE}" \
  --hostname lychee \
  --cores "${CORES}" \
  --memory "${MEMORY_MB}" \
  --swap "${SWAP_MB}" \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1 \
  --ostype debian \
  --password ""

echo "- Start container ${CTID}..."
pct start "${CTID}"

echo "- Wachten tot container een IP-adres heeft..."
IP=""
for i in {1..30}; do
  IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')" || true
  if [[ -n "${IP}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${IP}" ]]; then
  echo "Kon geen IP-adres ophalen van de container. Controleer netwerkconfig." >&2
  exit 1
fi
echo "  Container IP: ${IP}"

echo "- Installeer Docker en dependencies in de container..."
pct exec "${CTID}" -- bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    git \
    apt-transport-https \
    software-properties-common

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/${ID} \
    ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl start docker
'

echo "- Download Lychee-Docker stack in de container..."
pct exec "${CTID}" -- bash -c '
  set -e
  mkdir -p /opt/lychee
  cd /opt/lychee

  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/.env.example -o .env

  sed -i "s/^TIMEZONE=.*/TIMEZONE=Europe\/Amsterdam/" .env || true
  sed -i "s/^PHP_TZ=.*/PHP_TZ=Europe\/Amsterdam/" .env || true

  docker compose pull
  docker compose up -d
'

echo
echo "=== Klaar! ${APP_NAME} draait nu in LXC ${CTID}. ==="
echo
echo "Container IP: ${IP}"
echo "Lychee zou bereikbaar moeten zijn op:"
echo "  http://${IP}/"
echo
echo "Beheer later:"
echo "  pct enter ${CTID}"
echo "  cd /opt/lychee"
echo "  docker compose ps"
echo "  docker compose up -d"
