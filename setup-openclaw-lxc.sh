#!/usr/bin/env bash

# ==============================================================================
# OpenClaw Proxmox LXC Setup Script (Despliegue Completo y Automatizado)
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

# ------------------------------------------------------------------------------
# 1. Entrada de datos interactiva
# ------------------------------------------------------------------------------
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

# Configuración de Red Estática
read -p "IP estática del contenedor con CIDR (ej. 192.168.1.100/24): " IP_ADDR
if [ -z "$IP_ADDR" ]; then
  echo -e "${RED}[ERROR] La dirección IP no puede estar vacía.${NC}"
  exit 1
fi

read -p "Puerta de enlace / Gateway (ej. 192.168.1.1): " GATEWAY
if [ -z "$GATEWAY" ]; then
  echo -e "${RED}[ERROR] El gateway no puede estar vacío.${NC}"
  exit 1
fi

read -p "Servidores DNS [1.1.1.1 8.8.8.8]: " DNS_SERVERS; DNS_SERVERS=${DNS_SERVERS:-"1.1.1.1 8.8.8.8"}

# ------------------------------------------------------------------------------
# 2. Selección estricta de almacenamiento LXC (Filtrando contenido 'rootdir')
# ------------------------------------------------------------------------------
STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)
if [ -z "$STORAGE" ]; then
  echo -e "${RED}[ERROR] No se encontró ningún almacenamiento que admita contenedores (rootdir).${NC}"
  exit 1
fi
echo -e "${GREEN}[+] Almacenamiento asignado: ${STORAGE}${NC}"

TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}

# ------------------------------------------------------------------------------
# 3. Descarga de plantilla Debian (amd64)
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 4. Creación e inicio del contenedor con IP Estática
# ------------------------------------------------------------------------------
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
  --net0 name=eth0,bridge=vmbr0,ip="${IP_ADDR}",gw="${GATEWAY}" \
  --nameserver "${DNS_SERVERS}" \
  --password "$CONTAINER_PASSWORD" \
  --start 1

echo -e "${YELLOW}[+] Esperando inicialización del contenedor...${NC}"
sleep 5

# ------------------------------------------------------------------------------
# 5. Generación del script interno de aprovisionamiento
# ------------------------------------------------------------------------------
HOST_TEMP_SCRIPT="/tmp/openclaw-provision-${VMID}.sh"

cat << 'EOF_PROVISION' > "$HOST_TEMP_SCRIPT"
#!/bin/bash
set -ex

CONTAINER_PASSWORD="$1"
VNC_RES="$2"
DNS_SERVERS="$3"

export DEBIAN_FRONTEND=noninteractive

# Forzar configuración DNS asignada
> /etc/resolv.conf
for dns in $DNS_SERVERS; do
  echo "nameserver $dns" >> /etc/resolv.conf
done

# Obtención dinámica del lsbdistcodename / VERSION_CODENAME
CODENAME=$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME")
CODENAME=${CODENAME:-$(lsb_release -sc 2>/dev/null || echo "trixie")}

# Generación dinámica de debian.sources según el codename detectado
cat << SOURCES > /etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian/
Suites: ${CODENAME} ${CODENAME}-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: ${CODENAME}-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SOURCES

# Espera activa de conectividad a la red
echo "[+] Verificando resolución de red y DNS dentro del contenedor..."
for i in {1..20}; do
  if ping -c 1 deb.debian.org >/dev/null 2>&1; then
    echo "[+] Red y DNS operativos."
    break
  fi
  echo "Esperando respuesta de red ($i/20)..."
  sleep 2
done

# Configuración de reintentos automáticos en APT
echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries
echo 'Acquire::http::Timeout "15";' >> /etc/apt/apt.conf.d/80retries

# ------------------------------------------------------------------------------
# Configuración e Instalación Temprana de Locales (es_ES.UTF-8)
# ------------------------------------------------------------------------------
apt-get update
apt-get install -y locales

sed -i 's/# es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

update-locale LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8 LANGUAGE=es_ES.UTF-8
export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8
export LANGUAGE=es_ES.UTF-8

# ------------------------------------------------------------------------------
# Instalación de dependencias del sistema y entorno gráfico
# ------------------------------------------------------------------------------
apt-get install -y \
  curl wget git build-essential ca-certificates sudo \
  lxqt lxterminal tigervnc-standalone-server novnc dbus-x11 \
  fonts-noto-color-emoji htop net-tools x11-utils x11-xserver-utils xauth

# Instalación de Google Chrome
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O /tmp/chrome.deb
apt-get install -y /tmp/chrome.deb || apt-get install -fy
rm -f /tmp/chrome.deb

# Instalación de OpenClaw mediante el script oficial oneliner
curl -fsSL https://openclaw.ai/install.sh | bash

# Detección dinámica de la ruta absoluta del binario de OpenClaw
OPENCLAW_BIN=$(which openclaw 2>/dev/null || find / -name openclaw -type f 2>/dev/null | head -n1)
OPENCLAW_BIN=${OPENCLAW_BIN:-/usr/local/bin/openclaw}

# ------------------------------------------------------------------------------
# Configuración de VNC (Inicio Directo Xvnc)
# ------------------------------------------------------------------------------
mkdir -p /root/.vnc
printf "%s\n%s\nn\n" "$CONTAINER_PASSWORD" "$CONTAINER_PASSWORD" | vncpasswd /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# Script ejecutable de inicio directo Xvnc + LXQt con control de señales y limpieza
cat << VNC_LAUNCHER > /usr/local/bin/start-vnc.sh
#!/bin/bash
set -e

# Matar procesos Xvnc huérfanos anteriores
pkill -9 -f Xvnc >/dev/null 2>&1 || true
sleep 1

# Limpieza de archivos de bloqueo
rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/.X11-unix/X1-lock /root/.vnc/*.pid /root/.vnc/*.log
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

export DISPLAY=:1
export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8
export LANGUAGE=es_ES.UTF-8

trap 'pkill -9 -f Xvnc >/dev/null 2>&1 || true' EXIT

# Lanzar binario Xvnc directamente
/usr/bin/Xvnc :1 -geometry ${VNC_RES} -depth 24 -rfbauth /root/.vnc/passwd -rfbport 5901 -pn &

# Espera activa del socket X11
for i in {1..10}; do
  if [ -S /tmp/.X11-unix/X1 ]; then
    break
  fi
  sleep 0.5
done

# Ejecutar sesión LXQt integrada con D-Bus
exec dbus-run-session startlxqt
VNC_LAUNCHER

chmod +x /usr/local/bin/start-vnc.sh

# ------------------------------------------------------------------------------
# Unidades Systemd (VNC, noVNC, OpenClaw Gateway)
# ------------------------------------------------------------------------------
cat << 'SERV_VNC' > /etc/systemd/system/vncserver.service
[Unit]
Description=TigerVNC Server Direct
After=network.target

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=USER=root
Environment=LANG=es_ES.UTF-8
Environment=LC_ALL=es_ES.UTF-8
Environment=LANGUAGE=es_ES.UTF-8
ExecStart=/usr/local/bin/start-vnc.sh
Restart=always

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

cat << SERV_OPENCLAW > /etc/systemd/system/openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway Service
After=network.target

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.openclaw/bin
Environment=LANG=es_ES.UTF-8
Environment=LC_ALL=es_ES.UTF-8
Environment=LANGUAGE=es_ES.UTF-8
ExecStart=${OPENCLAW_BIN} gateway
Restart=always

[Install]
WantedBy=multi-user.target
SERV_OPENCLAW

# Recargar e iniciar todos los servicios
systemctl daemon-reload
systemctl enable openclaw-gateway vncserver novnc
systemctl start openclaw-gateway vncserver novnc || true

EOF_PROVISION

# ------------------------------------------------------------------------------
# 6. Copia y ejecución del script dentro del contenedor LXC
# ------------------------------------------------------------------------------
echo -e "${YELLOW}[+] Transfiriendo script de instalación al contenedor...${NC}"
pct push "$VMID" "$HOST_TEMP_SCRIPT" /tmp/provision.sh
pct exec "$VMID" -- chmod +x /tmp/provision.sh

echo -e "${YELLOW}[+] Ejecutando instalación dentro del contenedor LXC...${NC}"
pct exec "$VMID" -- /tmp/provision.sh "$CONTAINER_PASSWORD" "$VNC_RES" "$DNS_SERVERS"

# Limpieza de archivos temporales
rm -f "$HOST_TEMP_SCRIPT"
pct exec "$VMID" -- rm -f /tmp/provision.sh

# ------------------------------------------------------------------------------
# 7. Resumen de instalación
# ------------------------------------------------------------------------------
CONTAINER_IP_ONLY=$(echo "$IP_ADDR" | cut -d'/' -f1)

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}    ¡Instalación de OpenClaw completada con éxito!  ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "VMID del contenedor : ${VMID}"
echo -e "Almacenamiento usado: ${STORAGE}"
echo -e "IP del contenedor   : ${CONTAINER_IP_ONLY}"
echo -e "----------------------------------------------------"
echo -e "Dashboard OpenClaw  : http://${CONTAINER_IP_ONLY}:18789/"
echo -e "Escritorio noVNC    : http://${CONTAINER_IP_ONLY}:6080/vnc.html"
echo -e "Acceso SSH          : ssh root@${CONTAINER_IP_ONLY}"
echo -e "====================================================\n"
