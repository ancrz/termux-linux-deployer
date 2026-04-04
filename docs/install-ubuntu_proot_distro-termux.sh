#!/data/data/com.termux/files/usr/bin/bash
# Script para automatizar la instalación de un entorno Ubuntu base
# y funcional en Termux, sin componentes gráficos.

# --- Configuración de Seguridad del Script ---
# Salir inmediatamente si un comando falla (-e), si una variable no está definida (-u),
# y si un comando en un pipeline falla (-o pipefail).
set -euo pipefail

# --- Funciones ---

# Muestra el banner principal del script.
print_banner() {
    echo " "
    echo "#########################################################"
    echo "#      Instalador de Entorno Ubuntu Base para Termux    #"
    echo "#########################################################"
    echo " "
}

# Prepara el entorno de Termux actualizando e instalando dependencias.
prepare_termux() {
    echo "[+] Actualizando e instalando dependencias de Termux..."
    pkg update -y && pkg upgrade -y
    pkg install proot-distro -y
}

# Instala y configura la distribución de Ubuntu.
install_and_configure_ubuntu() {
    echo "[+] Instalando Ubuntu (esto puede tardar varios minutos)..."
    # Elimina una instalación previa para asegurar un inicio limpio.
    # Redirigimos la salida a /dev/null para no mostrar errores si no existe.
    proot-distro remove ubuntu &>/dev/null || true
    proot-distro install ubuntu

    echo "[+] Creando script de configuración de utilidades básicas..."
    # Usamos una variable para la ruta del script para mayor claridad.
    local setup_script_path="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu/root/setup-base.sh"

    # Usamos un heredoc (<<-) para crear el script de configuración.
    # El '-' permite usar tabulaciones para indentar el contenido del script.
    cat > "$setup_script_path" <<- EOM
		#!/bin/bash
		set -eu # Añadir seguridad también al script interno.

		echo "--- Actualizando paquetes de Ubuntu ---"
		apt-get update && apt-get upgrade -y

		echo "--- Instalando utilidades esenciales de línea de comandos ---"
		# Instala herramientas para edición, descarga, compilación y gestión de código.
		apt-get install -y nano curl wget git build-essential unzip

		echo "--- Limpiando caché de paquetes ---"
		apt-get clean

		echo " "
		echo "--- Configuración base dentro de Ubuntu completada ---"
	EOM

    echo "[+] Asignando permisos y ejecutando el script de configuración..."
    proot-distro login ubuntu -- chmod +x /root/setup-base.sh
    proot-distro login ubuntu -- /root/setup-base.sh
}

# Muestra el mensaje final con los próximos pasos.
print_final_message() {
    # Definimos los colores para usarlos fácilmente.
    local GREEN='\033[1;32m'
    local NC='\033[0m' # No Color

    echo " "
    echo -e "${GREEN}#############################################################"
    echo -e "${GREEN}#         ENTORNO UBUNTU BASE INSTALADO CORRECTAMENTE       #"
    echo -e "${GREEN}#############################################################${NC}"
    echo " "
    echo "Se ha instalado un entorno Ubuntu funcional sin interfaz gráfica."
    echo -e "Herramientas preinstaladas: ${GREEN}nano, curl, wget, git, build-essential, unzip${NC}"
    echo " "
    echo "--- Próximos Pasos ---"
    echo "1. Inicia sesión en tu nuevo entorno Ubuntu con:"
    echo -e "   ${GREEN}proot-distro login ubuntu${NC}"
    echo " "
    echo "2. Una vez dentro, puedes instalar las herramientas que necesites,"
    echo "   como 'code-server' u otros servidores."
    echo " "
}

# --- Flujo Principal del Script ---
main() {
    print_banner
    prepare_termux
    install_and_configure_ubuntu
    print_final_message
}

# Ejecutar la función principal.
main
