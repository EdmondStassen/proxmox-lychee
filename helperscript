#!/usr/bin/env bash
# Proxmox helper script voor Lychee (Lychee-Docker in een LXC met Docker)
# Gebruik: bash lychee-lxc.sh
#
# Dit script:
#  - Maakt een nieuwe Debian LXC aan
#  - Installeert Docker + docker compose in de container
#  - Haalt docker-compose.yml + .env.example uit Lychee-Docker repo
#  - Start Lychee op poort 80 in de container

set -euo pipefail

APP_NAME="Lychee"
DEBIAN_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"  # template naam uit pveam
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

# Volgende vrije CT ID
echo "- Bepaal volgende vrije CT ID..."
CTID="$(pvesh get /cluster/nextid)"
echo "  Gebruik CTID: ${CTID}"

# Kies een storage voor rootfs (eerste rootdir storage)
if ! pvesm status -content rootdir >/dev/null 2>&1; then
  echo "Geen storage gevonden met content type 'rootdir'. Controleer je storage config." >&2
  exit 1
fi

STORAGE="$(pvesm status -content rootdir | awk 'NR==2 {print $1}')"
if [[ -z "${STORAGE}" ]]; then
  echo "Kon geen geschikte rootdir storage vinden." >&2
  exit 1
fi
echo "  Gebruik storage: ${STORAGE}"

# Controleren of template al aanwezig is, zo niet: downloaden
echo "- Controleren op Debian template (${DEBIAN_TEMPLATE})..."
if ! pveam list "${STORAGE}" | grep -q "${DEBIAN_TEMPLATE}"; then
  echo "  Template niet gevonden op ${STORAGE}, download nu..."
  pveam update
  pveam download "${STORAGE}" "${DEBIAN_TEMPLATE}"
else
  echo "  Template al aanwezig."
fi

# LXC aanmaken
echo "- Maak LXC container ${CTID} aan..."
pct create "${CTID}" \
  "${STORAGE}:vztmpl/${DEBIAN_TEMPLATE}" \
  --hostname lychee \
  --cores "${CORES}" \
  --memory "${MEMORY_MB}" \
  --swap "${SWAP_MB}" \
  --rootfs "${STORAGE}:${DISK_SIZE_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1 \
  --ostype debian \
  --password ""

echo "- Start container ${CTID}..."
pct start "${CTID}"

# Wachten op IP
echo "- Wachten tot container een IP-adres heeft..."
for i in {1..30}; do
  IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}') " || true
  IP="${IP%% *}"
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

  # Docker repo toevoegen
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

  # docker-compose.yml + .env voorbeeld ophalen
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/.env.example -o .env

  # Tijdzone eventueel aanpassen (voorbeeld: Europe/Amsterdam)
  sed -i "s/^TIMEZONE=.*/TIMEZONE=Europe\/Amsterdam/" .env || true
  sed -i "s/^PHP_TZ=.*/PHP_TZ=Europe\/Amsterdam/" .env || true

  # Stack starten
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
echo "Configuratie & data in de container:"
echo "  /opt/lychee    -> docker-compose stack"
echo "  uploads/config etc. zoals gedefinieerd in docker-compose.yml"
echo
echo "Wil je later opnieuw starten / beheren?"
echo "  pct enter ${CTID}"
echo "  cd /opt/lychee"
echo "  docker compose ps"
echo "  docker compose up -d"
