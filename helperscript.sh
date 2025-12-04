#!/usr/bin/env bash
# Proxmox helper script voor Lychee (Lychee-Docker in een LXC met Docker)
# Mét:
#  - automatische Debian 12 template-detectie
#  - AppArmor workaround voor Docker in LXC
#  - interactief root-wachtwoord voor de container
#  - veilig genereren van DB_PASSWORD onder pipefail
#
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

# --- ROOT PASSWORD INPUT ---
echo "- Voer een wachtwoord in voor de root gebruiker van de container."
while true; do
    read -s -p "Root wachtwoord: " ROOT_PW_1; echo
    read -s -p "Bevestig wachtwoord: " ROOT_PW_2; echo
    [[ "$ROOT_PW_1" == "$ROOT_PW_2" ]] && break
    echo "Wachtwoorden komen niet overeen, probeer opnieuw."
done
echo "- Root wachtwoord opgeslagen (wordt zo in de container gezet)."
# ----------------------------

# Basic checks
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Dit script moet als root worden uitgevoerd." >&2
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

if ! command -v pveam >/dev/null 2>&1; then
  echo "'pveam' niet gevonden – Proxmox template manager ontbreekt?" >&2
  exit 1
fi

echo "- Bepaal volgende vrije CT ID..."
CTID="$(pvesh get /cluster/nextid)"
echo "  Gebruik CTID: ${CTID}"

# Storage kiezen
if ! pvesm status -content vztmpl >/dev/null 2>&1; then
  echo "Geen storage met content type 'vztmpl' (templates) gevonden." >&2
  exit 1
fi
if ! pvesm status -content rootdir >/dev/null 2>&1; then
  echo "Geen storage met content type 'rootdir' (container rootfs) gevonden." >&2
  exit 1
fi

TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR==2 {print $1}')"
ROOTFS_STORAGE="$(pvesm status -content rootdir | awk 'NR==2 {print $1}')"

echo "  Template storage: ${TEMPLATE_STORAGE}"
echo "  Rootfs storage:   ${ROOTFS_STORAGE}"

# Template detectie
echo "- Zoeken naar een geschikte Debian 12 template..."
DEBIAN_TEMPLATE="${DEBIAN_TEMPLATE:-}"
if [[ -z "${DEBIAN_TEMPLATE}" ]]; then
  DEBIAN_TEMPLATE="$(
    pveam available \
      | awk '/debian-12-standard_.*amd64\.tar\.zst/ {print $2; exit}'
  )"
fi

if [[ -z "${DEBIAN_TEMPLATE}" ]]; then
  echo "Geen Debian 12 template gevonden in 'pveam available'." >&2
  echo "Controleer met:" >&2
  echo "  pveam available | grep debian-12-standard" >&2
  exit 1
fi

echo "  Gekozen template: ${DEBIAN_TEMPLATE}"

# Template downloaden indien nodig
echo "- Controleren of template al aanwezig is op ${TEMPLATE_STORAGE}..."
if ! pveam list "${TEMPLATE_STORAGE}" | awk '{print $2}' | grep -qx "${DEBIAN_TEMPLATE}"; then
  echo "  Template niet gevonden op ${TEMPLATE_STORAGE}, downloaden..."
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${DEBIAN_TEMPLATE}"
else
  echo "  Template is al aanwezig."
fi

# Container aanmaken (wachtwoord later goed zetten)
echo "- Maak container ${CTID} aan..."
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
  --password "IGNOREME"

# Docker / AppArmor workaround
CONF="/etc/pve/lxc/${CTID}.conf"
echo "- Docker AppArmor workaround toepassen..."
{
  echo "lxc.apparmor.profile: unconfined"
  echo "lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind 0 0"
} >> "${CONF}"

echo "- Start container..."
pct start "${CTID}"

# Root wachtwoord instellen in de container
echo "- Root wachtwoord instellen in container..."
pct exec "${CTID}" -- bash -c "echo -e '${ROOT_PW_1}\n${ROOT_PW_1}' | passwd root"

# IP ophalen
echo "- IP-adres ophalen..."
IP=""
for i in {1..30}; do
  IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')" || true
  [[ -n "${IP}" ]] && break
  sleep 2
done

if [[ -z "${IP}" ]]; then
  echo "Kon geen IP-adres ophalen, maar de container bestaat. Controleer later met:" >&2
  echo "  pct enter ${CTID}" >&2
else
  echo "  Container IP: ${IP}"
fi

# Docker installeren
echo "- Docker installeren in container..."
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
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

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

# 🔑 VEILIG DB_PASSWORD GENEREREN ONDER PIPEFAIL
echo "- Genereer database wachtwoord..."
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)"
if [[ -z "${DB_PASSWORD}" ]]; then
  DB_PASSWORD="ChangeMe$(date +%s)"
fi

echo "- Lychee Docker stack installeren..."
pct exec "${CTID}" -- env DB_PASSWORD="${DB_PASSWORD}" bash -c '
  set -e
  mkdir -p /opt/lychee
  cd /opt/lychee

  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/.env.example -o .env

  sed -i "s/^TIMEZONE=.*/TIMEZONE=Europe\/Amsterdam/" .env || true
  sed -i "s/^PHP_TZ=.*/PHP_TZ=Europe\/Amsterdam/" .env || true

  if grep -q '^DB_PASSWORD=' .env; then
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" .env
  else
    echo "DB_PASSWORD=${DB_PASSWORD}" >> .env
  fi

  docker compose pull
  docker compose up -d
'

echo
echo "=== Klaar! ${APP_NAME} draait nu in LXC ${CTID}. ==="
echo
if [[ -n "${IP}" ]]; then
  echo "Lychee zou bereikbaar moeten zijn op:"
  echo "  http://${IP}/"
else
  echo "Lychee is gestart, maar IP was niet direct te bepalen."
  echo "Controleer later met: pct exec ${CTID} -- hostname -I"
fi
echo
echo "Container root login:"
echo "  user:     root"
echo "  password: (het wachtwoord dat je in het begin hebt ingevoerd)"
echo
echo "Database instellingen:"
echo "  DB user: lychee"
echo "  DB name: lychee"
echo "  DB pass: ${DB_PASSWORD}"
echo "(Ook terug te vinden in /opt/lychee/.env in de container.)"
echo
echo "Beheer later:"
echo "  pct enter ${CTID}"
echo "  cd /opt/lychee"
echo "  docker compose ps"
echo "  docker compose logs"
