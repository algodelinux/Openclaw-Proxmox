#!/usr/bin/env bash

# ==============================================================================
# OpenClaw Proxmox LXC Setup Script
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}     OpenClaw AI Assistant Proxmox LXC Setup        ${NC}"
echo -e "${BLUE}====================================================${NC}\n"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root en Proxmox.${NC}"
  exit 1
fi

# 1. Entrada de datos
read -sp "Ingrese la contraseña para el contenedor root / VNC: " CONTAINER_PASSWORD
echo ""
if [ -z "$CONTAINER_PASSWORD" ]; then
  echo -e "${RED}[ERROR] La contraseña no puede estar vacía.${NC}"
  exit 1
fi

read -p "Tamaño de disco (GB) [32]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-32}
read -p "Memoria RAM (MB) [4096]: " MEMORY; MEMORY=${MEMORY:-4096}
read -p "Cores CPU [4]: " CPU_CORES; CPU_CORES=${CPU_CORES:-4}
read -p "Resolución VNC [1920x1080]: " VNC_RES; VNC_RES=${VNC_RES:-1920x1080}

NEXT_VMID=$(pvesh get /cluster/nextid)
read -p "VMID del contenedor [${NEXT_VMID}]: " VMID; VMID=${VMID:-$NEXT_VMID}

# 2. Selección estricta de almacenamiento LXC (Filtrando contenido 'rootdir')
STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)
if [ -z "$STORAGE" ]; then
  echo -e "${RED}[ERROR] No se encontró ningún almacenamiento que admita contenedores (rootdir).${NC}"
  exit 1
fi
echo -e "${GREEN}[+] Almacenamiento asignado: ${STORAGE}${NC}"

TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}

# 3. Descarga de plantilla Debian (amd64)
echo -e "${YELLOW}[+] Buscando plantilla Debian (amd64)...${NC}"
pveam update >/dev/null 2>&1 || true

TEMPLATE_FILE=$(pveam available -section system | grep -E "debian-(13|12)-standard" | grep "amd64" | tail -n1 | awk '{print $2}')
if [ -z "$TEMPLATE_FILE" ]; then
  echo -e "${RED}[ERROR] No se encontró plantilla Debian (12/13) amd64 en el catálogo de Proxmox.${NC}"
  exit 1
fi

echo -e "${YELLOW}[+] Descargando ${TEMPLATE_FILE} en '${TEMPLATE_STORAGE}'...${NC}"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" >/dev/null 2>&1 || true
TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

# 4. Creación e inicio del contenedor con DNS asignado
echo -e "${YELLOW}[+] Creando contenedor LXC ${VMID}...${NC}"
pct create "$VMID" "$TEMPLATE_PATH" \
  --ostype debian \
  --hostname openclaw-ai \
  --cores "$CPU_CORES" \
  --memory "$MEMORY" \
  --swap 1024 \
  --features nesting=1 \
  --unprivileged 0 \
  --storage "$STORAGE" \
  --rootfs "${STORAGE}:${DISK_SIZE}" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --nameserver "1.1.1.1 8.8.8.8" \
  --password "$CONTAINER_PASSWORD" \
  --start 1

echo -e "${YELLOW}[+] Esperando a que el contenedor inicie red...${NC}"
sleep 5

# 5. Generación del script interno en el host
HOST_TEMP_SCRIPT="/tmp/openclaw-provision-${VMID}.sh"

cat << EOF > "$HOST_TEMP_SCRIPT"
#!/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive

# Forzar resolución DNS pública antes de actualizar repositorios
echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

# Reemplazar la configuración de debian.sources con la estructura corregida
cat << 'SOURCES' > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES

# Actualizar repos e instalar dependencias básicas y entorno gráfico
apt-get update && apt-get install -y \\
  curl wget git build-essential ca-certificates sudo \\
  lxqt lxterminal tigervnc-standalone-server novnc dbus-x11 \\
  noto-color-emoji htop net-tools x11-utils

# Google Chrome
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
apt-get install -y /tmp/chrome.deb || apt-get install -fy
rm -f /tmp/chrome.deb

# Node.js 22 y OpenClaw
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g openclaw@latest || true

# Configuración VNC
mkdir -p /root/.vnc
echo '${CONTAINER_PASSWORD}' | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

cat << 'XSTART' > /root/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startlxqt
XSTART
chmod +x /root/.vnc/xstartup

# Servicios Systemd
cat << 'SERV_VNC' > /etc/systemd/system/vncserver.service
[Unit]
Description=TigerVNC Server
After=network.target

[Service]
Type=forking
User=root
ExecStart=/usr/bin/vncserver :1 -geometry ${VNC_RES} -depth 24
ExecStop=/usr/bin/vncserver -kill :1
Restart=on-failure

[Install]
WantedBy=multi-user.target
SERV_VNC

cat << 'SERV_NOVNC' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC Web Proxy
After=vncserver.service

[Service]
Type=simple
User=root
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5901 --listen 6080
Restart=always

[Install]
WantedBy=multi-user.target
SERV_NOVNC

cat << 'SERV_OPENCLAW' > /etc/systemd/system/openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/env openclaw gateway
Restart=always

[Install]
WantedBy=multi-user.target
SERV_OPENCLAW

systemctl daemon-reload
systemctl enable openclaw-gateway vncserver novnc
systemctl start openclaw-gateway vncserver novnc || true

EOF

# 6. Copiar script al contenedor y ejecutarlo
echo -e "${YELLOW}[+] Transfiriendo script de instalación al contenedor...${NC}"
pct push "$VMID" "$HOST_TEMP_SCRIPT" /tmp/provision.sh
pct exec "$VMID" -- chmod +x /tmp/provision.sh

echo -e "${YELLOW}[+] Ejecutando instalación dentro del contenedor LXC...${NC}"
pct exec "$VMID" -- /tmp/provision.sh

# Limpieza de archivos temporales
rm -f "$HOST_TEMP_SCRIPT"
pct exec "$VMID" -- rm -f /tmp/provision.sh

# 7. Resumen final
CONTAINER_IP=$(pct exec "$VMID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}    ¡Instalación de OpenClaw completada con éxito!  ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "VMID del contenedor : ${VMID}"
echo -e "Almacenamiento usado: ${STORAGE}"
echo -e "IP del contenedor   : ${CONTAINER_IP:-'Asignada por DHCP'}"
echo -e "----------------------------------------------------"
echo -e "Dashboard OpenClaw  : http://${CONTAINER_IP:-'<IP-CONTENEDOR>'}:18789/"
echo -e "Escritorio noVNC    : http://${CONTAINER_IP:-'<IP-CONTENEDOR>'}:6080/vnc.html"
echo -e "Acceso SSH          : ssh root@${CONTAINER_IP:-'<IP-CONTENEDOR>'}"
echo -e "====================================================\n"
