#!/bin/bash
# Script para configurar un sistema Ubuntu base con las
# utilidades de desarrollo esenciales.
#
# v1.3 - Añadido soporte para 7z (p7zip-full).

# --- Configuracion Inicial ---
# Detiene el script si un comando falla.
set -e

# Colores para la salida
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"

# --- Funciones Auxiliares ---
print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# --- Validaciones Previas ---
print_info "Realizando validaciones previas..."

# 1. Validar que se ejecuta como root
if [[ "$(id -u)" -ne 0 ]]; then
   print_error "Este script debe ejecutarse como root. Usa 'sudo bash $0'."
   exit 1
fi

# 2. Validar conexión a Internet
if ! curl -s --head http://www.google.com | grep "200 OK" > /dev/null; then
    print_error "No hay conexión a Internet. Verifica tu red."
    exit 1
fi
print_success "Validaciones previas completadas."

# --- Paso 1: Instalar y Actualizar Utilidades Esenciales ---
print_info "Verificando el estado de las utilidades esenciales..."
# Lista maestra de todos los paquetes que nos interesan.
PACKAGES_TO_INSTALL=(
  build-essential cmake make python3 pkg-config curl wget net-tools
  iputils-ping dnsutils git unzip zip tar procps htop tree tmux jq
  gnupg ca-certificates p7zip-full
)

# Primero, encontrar los paquetes que no están instalados en absoluto.
MISSING_PACKAGES=()
for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

# Segundo, refrescar la lista de paquetes para saber qué se puede actualizar.
print_info "Actualizando la lista de paquetes desde los repositorios..."
apt-get update > /dev/null

# Tercero, obtener una lista de los paquetes que se pueden actualizar.
# Filtramos solo aquellos que están en nuestra lista maestra.
UPGRADABLE_PACKAGES=()
# El comando 'apt list' puede fallar si no hay nada que actualizar, por eso el '|| true'
UPGRADABLE_LIST=$(apt list --upgradable 2>/dev/null | awk -F/ '{print $1}' || true)

for pkg in ${UPGRADABLE_LIST}; do
    # Comprobar si el paquete actualizable está en nuestra lista de interés
    if [[ " ${PACKAGES_TO_INSTALL[*]} " =~ " ${pkg} " ]]; then
        UPGRADABLE_PACKAGES+=("$pkg")
    fi
done

# Finalmente, combinar ambas listas (faltantes y actualizables) sin duplicados.
PACKAGES_TO_PROCESS=($(echo "${MISSING_PACKAGES[@]}" "${UPGRADABLE_PACKAGES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

if [ ${#PACKAGES_TO_PROCESS[@]} -gt 0 ]; then
    print_info "Se instalarán/actualizarán los siguientes paquetes: ${PACKAGES_TO_PROCESS[*]}"
    apt-get install -y "${PACKAGES_TO_PROCESS[@]}"
    print_success "Todas las utilidades esenciales están instaladas y actualizadas."
else
    print_success "Todas las utilidades esenciales ya están instaladas y en su última versión."
fi


# --- Paso 2: Limpieza Final ---
print_info "Limpiando caché de paquetes del sistema..."
apt-get clean
apt-get autoremove -y
print_success "Limpieza finalizada."

# --- Paso 3: Mensajes Finales ---
echo " "
echo -e "${GREEN}#############################################################"
echo -e "${GREEN}#          SISTEMA BASE DE UBUNTU CONFIGURADO             #"
echo -e "#############################################################${NC}"
echo " "
echo "El sistema está listo con un conjunto ampliado de utilidades de desarrollo."
