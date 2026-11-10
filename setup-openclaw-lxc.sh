#!/usr/bin/env bash

# ==============================================================================
# OpenClaw Proxmox LXC Automated Setup Script (Con corrección de Storage LXC)
# ==============================================================================

set -euo pipefail

# Definición de colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}     OpenClaw AI Assistant Proxmox LXC Setup        ${NC}"
echo -e "${BLUE}====================================================${NC}"
echo ""

# Verificación de permisos de súperusuario
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root en el host Proxmox VE.${NC}"
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. Parámetros interactivos
# ------------------------------------------------------------------------------

read -sp "Ingrese la contraseña para el contenedor root / VNC: " CONTAINER_PASSWORD
echo ""
if [ -z "$CONTAINER_PASSWORD" ]; then
  echo -e "${RED}[ERROR] La contraseña es obligatoria.${NC}"
  exit 1
fi

read -p "Tamaño de disco (GB) [Por defecto: 32]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-32}

read -p "Memoria RAM (MB) [Por defecto: 4096]: " MEMORY
MEMORY=${MEMORY:-4096}

read -p "Cores de CPU [Por defecto: 4]: " CPU_CORES
CPU_CORES=${CPU_CORES:-4}

read -p "Resolución VNC [Por defecto: 1920x1080]: " VNC_RES
VNC_RES=${VNC_RES:-1920x1080}

# ------------------------------------------------------------------------------
# 2. Autodetección de recursos (MÉTODO 3 APLICADO)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}[+] Detectando configuración del cluster/nodo Proxmox...${NC}"

# 2.1. Obtener el siguiente VMID disponible
NEXT_VMID=$(pvesh get /cluster/nextid)
read -p "VMID del contenedor [Por defecto: ${NEXT_VMID}]: " VMID
VMID=${VMID:-$NEXT_VMID}

# 2.2. MÉTODO 3: Filtrar únicamente almasenamientos que soporten contenedores ('rootdir')
STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)

# Fallback en caso de que no devuelva resultados por formato de versión previa
if [ -z "$STORAGE" ]; then
  STORAGE=$(pvesm status | awk 'NR>1 && ($2=="dir" || $2=="zfspool" || $2=="lvmthin" || $2=="btrfs") {print $1}' | head -n1)
fi

if [ -z "$STORAGE" ]; then
  echo -e "${RED}[ERROR] No se encontró ningún almacenamiento compatible con volúmenes de contenedor (rootdir).${NC}"
  exit 1
fi

echo -e "${GREEN}[+] Almacenamiento LXC seleccionado: ${STORAGE}${NC}"

# 2.3. Detectar almacenamiento de plantillas (vztmpl)
TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
if [ -z "$TEMPLATE_STORAGE" ]; then
  TEMPLATE_STORAGE="local"
fi

# ------------------------------------------------------------------------------
# 3. Descarga de Plantilla LXC y Creación del Contenedor
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[+] Actualizando catálogo de plantillas Debian...${NC}"
pveam update >/dev/null 2>&1 || true

TEMPLATE_FILE=$(pveam available -section system | grep -E "debian-(13|12)-standard" | grep "amd64" | tail -n1 | awk '{print $2}')

if [ -z "$TEMPLATE_FILE" ]; then
  TEMPLATE_FILE="debian-12-standard_12.2-1_amd64.tar.zst"
fi

echo -e "${YELLOW}[+] Descargando plantilla ${TEMPLATE_FILE} en '${TEMPLATE_STORAGE}'...${NC}"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" >/dev/null 2>&1 || true

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

echo -e "${YELLOW}[+] Creando contenedor LXC (VMID: ${VMID}) en storage '${STORAGE}'...${NC}"
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
  --password "$CONTAINER_PASSWORD" \
  --start 1

echo -e "${GREEN}[+] Contenedor iniciado correctamente. Esperando red...${NC}"
sleep 5

# ------------------------------------------------------------------------------
# 4. Aprovisionamiento dentro del LXC
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[+] Instalando paquetes, escritorio LXQt, Chrome y OpenClaw...${NC}"

pct exec "$VMID" -- bash -c "cat << 'EOF' > /tmp/inner-setup.sh
#!/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive

apt-get update && apt-get install -y \
  curl wget git build-essential ca-certificates sudo \
  lxqt lxterminal tigervnc-standalone-server novnc dbus-x11 \
  noto-color-emoji htop net-tools x11-utils

# Instalación de Google Chrome
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
apt-get install -y /tmp/chrome.deb || apt-get install -fy
rm -f /tmp/chrome.deb

# Instalación de Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Instalación de OpenClaw y Homebrew
npm install -g openclaw@latest || true
NONINTERACTIVE=1 bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\" || true

# Configuración VNC y LXQt
mkdir -p /root/.vnc
echo '$CONTAINER_PASSWORD' | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

cat << 'XSTART' > /root/.vnc/xstartup
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startlxqt
XSTART
chmod +x /root/.vnc/xstartup

# Accesos directos de escritorio
mkdir -p /root/Desktop

cat << 'DESK1' > /root/Desktop/OpenClaw-Wizard.desktop
[Desktop Entry]
Type=Application
Name=OpenClaw Setup Wizard
Comment=Run OpenClaw Onboarding Wizard
Exec=lxterminal -e "openclaw onboard"
Icon=utilities-terminal
Terminal=false
Categories=Utility;
DESK1
chmod +x /root/Desktop/OpenClaw-Wizard.desktop

cat << 'DESK2' > /root/Desktop/OpenClaw-Dashboard.desktop
[Desktop Entry]
Type=Application
Name=OpenClaw Dashboard
Comment=Open OpenClaw Dashboard in Chrome
Exec=google-chrome-stable --no-sandbox http://localhost:18789
Icon=google-chrome
Terminal=false
Categories=Network;
DESK2
chmod +x /root/Desktop/OpenClaw-Dashboard.desktop

# Servicios Systemd
cat << 'SERV1' > /etc/systemd/system/openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/env openclaw gateway
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERV1

cat << 'SERV2' > /etc/systemd/system/vncserver.service
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
SERV2

cat << 'SERV3' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC Web Proxy
After=vncserver.service

[Service]
Type=simple
User=root
ExecStart=/usr/share/novnc/utils/novnc_proxy --vnc localhost:5901 --listen 6080
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERV3

systemctl daemon-reload
systemctl enable openclaw-gateway vncserver novnc
systemctl start openclaw-gateway vncserver novnc || true

EOF
"

pct exec "$VMID" -- bash /tmp/inner-setup.sh
pct exec "$VMID" -- rm -f /tmp/inner-setup.sh

# ------------------------------------------------------------------------------
# 5. Información final de acceso
# ------------------------------------------------------------------------------
CONTAINER_IP=""
for i in {1..10}; do
  CONTAINER_IP=$(pct exec "$VMID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true)
  if [ -n "$CONTAINER_IP" ]; then
    break
  fi
  sleep 2
done

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
