#!/usr/bin/env bash
# Proxmox helper script voor Lychee (Lychee-Docker in een LXC met Docker)
# Nu mét interactief root-wachtwoord voor de container
# Gebruik:
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
echo "- Root wachtwoord ingesteld."
# ----------------------------

# Basic checks
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Dit script moet als root worden uitgevoerd." >&2
  exit 1
fi

echo "- Bepaal volgende vrije CT ID..."
CTID="$(pvesh get /cluster/nextid)"
echo "  Gebruik CTID: ${CTID}"

# Storage kiezen
TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR==2 {print $1}')"
ROOTFS_STORAGE="$(pvesm status -content rootdir | awk 'NR==2 {print $1}')"

echo "  Template storage: ${TEMPLATE_STORAGE}"
echo "  Rootfs storage:   ${ROOTFS_STORAGE}"

# Template detectie
echo "- Zoeken naar een geschikte Debian 12 template..."
DEBIAN_TEMPLATE="$(pveam available | awk '/debian-12-standard_.*amd64\.tar\.zst/ {print $2; exit}')"

if [[ -z "$DEBIAN_TEMPLATE" ]]; then
  echo "Geen Debian 12 template gevonden." >&2
  exit 1
fi

echo "  Gekozen template: ${DEBIAN_TEMPLATE}"

# Download template indien nodig
if ! pveam list "${TEMPLATE_STORAGE}" | grep -q "${DEBIAN_TEMPLATE}"; then
  echo "- Template downloaden..."
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${DEBIAN_TEMPLATE}"
fi

# Container aanmaken (password wordt later ingesteld)
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

# Docker AppArmor workaround
CONF="/etc/pve/lxc/${CTID}.conf"
echo "- Docker AppArmor fix toepassen..."
{
  echo "lxc.apparmor.profile: unconfined"
  echo "lxc.mount.entry: /dev/null sys/module/apparmor/parameters/enabled none bind 0 0"
} >> "${CONF}"

echo "- Start container..."
pct start "${CTID}"

# Root wachtwoord instellen binnen de container
echo "- Root wachtwoord instellen in container..."
pct exec "${CTID}" -- bash -c "echo -e '${ROOT_PW_1}\n${ROOT_PW_1}' | passwd root"

# IP ophalen
echo "- IP-adres ophalen..."
for i in {1..30}; do
  IP="$(pct exec ${CTID} -- hostname -I 2>/dev/null | awk '{print $1}')" || true
  [[ -n "${IP}" ]] && break
  sleep 2
done

echo "  Container IP: ${IP}"

# Docker installeren
echo "- Docker installeren..."
pct exec "${CTID}" -- bash -c '
  set -e
  apt-get update
  apt-get install -y ca-certificates curl gnupg git software-properties-common
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
'

# Random DB password
DB_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

echo "- Lychee stack installeren..."
pct exec "${CTID}" -- env DB_PASSWORD="$DB_PASSWORD" bash -c '
  set -e
  mkdir -p /opt/lychee
  cd /opt/lychee
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/docker-compose.yml -o docker-compose.yml
  curl -fsSL https://raw.githubusercontent.com/LycheeOrg/Lychee-Docker/master/.env.example -o .env
  sed -i "s/^TIMEZONE=.*/TIMEZONE=Europe\/Amsterdam/" .env
  sed -i "s/^PHP_TZ=.*/PHP_TZ=Europe\/Amsterdam/" .env
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DB_PASSWORD}/" .env || echo "DB_PASSWORD=${DB_PASSWORD}" >> .env
  docker compose pull
  docker compose up -d
'

echo
echo "=== Installatie voltooid! ==="
echo "Lychee draait in container ${CTID}"
echo "URL:       http://${IP}/"
echo "Root login:"
echo "  user:     root"
echo "  password: (het wachtwoord dat je invoerde)"
echo
echo "Database:"
echo "  user: lychee"
echo "  db:   lychee"
echo "  pass: ${DB_PASSWORD}"
