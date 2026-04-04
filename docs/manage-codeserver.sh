#!/bin/bash
# Code-Server Toolkit: Un script unificado para instalar, configurar y gestionar
# code-server con una estructura persistente y robusta.
# v1.8 - Corregido el bucle lógico después de una operación de 'Purge'.

# Salir inmediatamente si un comando falla (-e), si una variable no está definida (-u),
# y si un comando en un pipeline falla (-o pipefail).
set -euo pipefail

# --- VARIABLES GLOBALES DE CONFIGURACIÓN ---
CONFIG_DIR="$HOME/.config/code-server"
USER_DATA_DIR="$HOME/.local/share/code-server"
EXTENSIONS_DIR="$HOME/.local/share/vscode-extensions"
WORKSPACE_DIR="$HOME/home/Documents"

CONFIG_FILE="$CONFIG_DIR/config.yaml"
PID_FILE="$CONFIG_DIR/code-server.pid"
LOG_FILE="$CONFIG_DIR/code-server.log"

# --- VARIABLES DE RENDIMIENTO ---
NODE_MEMORY_LIMIT="--max-old-space-size=4096"
CS_PERFORMANCE_ARGS="--disable-update-check --disable-workspace-trust"
STARTUP_DELAY_SECONDS=5

# --- FUNCIONES AUXILIARES ---
check_internet_connection() {
    if ! curl --silent --head --fail "https://github.com" >/dev/null; then
        echo "[ERROR] No se pudo establecer conexión a Internet."
        echo "        Verifica tu conexión antes de instalar o reinstalar."
        return 1
    fi
    return 0
}

# --- FUNCIONES DE INSTALACIÓN Y CONFIGURACIÓN ---
create_robust_config() {
    local password="$1"
    echo "[INFO] Creando estructura de directorios persistentes..."
    mkdir -p "$WORKSPACE_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$USER_DATA_DIR"
    mkdir -p "$EXTENSIONS_DIR"

    echo "[INFO] Generando archivo de configuración en '$CONFIG_FILE'..."
    cat > "$CONFIG_FILE" <<- EOM
bind-addr: 0.0.0.0:8443
auth: password
password: ${password}
cert: false
user-data-dir: ${USER_DATA_DIR}
extensions-dir: ${EXTENSIONS_DIR}
disable-telemetry: true
EOM
    echo "[ÉXITO] Configuración robusta creada."
}

# Esta función ahora se usa para la primera vez y para la reconfiguración post-purga.
install_and_configure() {
    local is_reconfiguring=false
    if command -v code-server >/dev/null 2>&1; then
        is_reconfiguring=true
    fi

    if [[ "$is_reconfiguring" = false ]]; then
        echo "[INFO] Iniciando el proceso de instalación por primera vez."
        if ! check_internet_connection; then return 1; fi

        if ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
            echo "[INFO] Instalando dependencias necesarias (curl, git)..."
            apt-get update >/dev/null
            apt-get install -y git curl >/dev/null
        fi
        echo "[INFO] Descargando e instalando la última versión de code-server..."
        curl -fsSL https://code-server.dev/install.sh | sh
    fi

    local password
    read -s -r -p "Introduce la nueva contraseña para code-server: " password
    echo
    if [[ -z "$password" ]]; then
        echo "[ERROR] La contraseña no puede estar vacía." >&2
        exit 1
    fi

    create_robust_config "$password"

    if command -v git >/dev/null 2>&1; then
        echo "[INFO] Configurando Git con valores por defecto..."
        git config --global user.name "ancrz" || true
        git config --global user.email "anthony_cruz@outlook.com" || true
    fi

    echo
    echo "[ÉXITO] Instalación y configuración completadas."
}

validate_and_fix_config() {
    # Esta función ahora asume que el archivo de configuración existe.
    if ! grep -q "extensions-dir:" "$CONFIG_FILE"; then
        echo "[CORRECCIÓN] La configuración no especifica un directorio de extensiones persistente."
        echo "             Añadiendo la configuración recomendada a '$CONFIG_FILE'..."
        echo "extensions-dir: ${EXTENSIONS_DIR}" >> "$CONFIG_FILE"
    fi

    if [[ ! -d "$EXTENSIONS_DIR" ]] || [[ ! -d "$WORKSPACE_DIR" ]]; then
        echo "[INFO] Creando directorios de trabajo y extensiones que faltaban..."
        mkdir -p "$WORKSPACE_DIR"
        mkdir -p "$EXTENSIONS_DIR"
    fi
}

# --- FUNCIONES DE GESTIÓN DEL SERVIDOR ---
is_running() {
    if [[ -f "$PID_FILE" ]] && ps -p "$(cat "$PID_FILE")" > /dev/null; then return 0; fi
    [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
    return 1
}

health_check() {
    if curl --silent --output /dev/null --fail "http://127.0.0.1:8443/healthz"; then return 0; else return 1; fi
}

start() {
    if is_running; then
        echo "[ADVERTENCIA] code-server ya se está ejecutando (PID: $(cat "$PID_FILE"))."
        return
    fi
    echo "[INFO] Iniciando code-server en segundo plano..."
    
    NODE_OPTIONS="$NODE_MEMORY_LIMIT" nohup code-server --config "$CONFIG_FILE" $CS_PERFORMANCE_ARGS "$WORKSPACE_DIR" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    echo "[INFO] Esperando ${STARTUP_DELAY_SECONDS}s para la estabilización del servicio..."
    sleep "$STARTUP_DELAY_SECONDS"

    echo "[INFO] Verificando que el servicio esté respondiendo..."
    local retries=5
    local count=0
    while [[ $count -lt $retries ]]; do
        if health_check; then
            echo "[ÉXITO] Servidor iniciado correctamente (PID: $(cat "$PID_FILE"))."
            return
        fi
        count=$((count + 1))
        sleep 2
    done

    echo "[ERROR] El servidor se inició (PID: $(cat "$PID_FILE")) pero no responde." >&2
    echo "         Revisa los logs (opción 5) para más detalles." >&2
}

stop() {
    if ! is_running; then
        echo "[INFO] code-server no se está ejecutando."
        return
    fi
    echo "[INFO] Deteniendo code-server (PID: $(cat "$PID_FILE"))..."
    kill "$(cat "$PID_FILE")"
    sleep 1
    rm -f "$PID_FILE"
    echo "[ÉXITO] Servidor detenido."
}

reinstall() {
    echo "[ADVERTENCIA] Estás a punto de reinstalar code-server a la última versión."
    read -r -p "¿Deseas continuar? [s/N]: " choice
    if [[ ! "$choice" =~ ^[Ss]$ ]]; then
        echo "Reinstalación cancelada."
        return
    fi

    if ! check_internet_connection; then return 1; fi
    stop
    echo "[INFO] Descargando la última versión..."
    curl -fsSL https://code-server.dev/install.sh | sh
    echo "[ÉXITO] Reinstalación completada. Tu configuración se ha mantenido."
}

purge_installation() {
    echo "[ALERTA] Esta acción es destructiva y eliminará TODA la configuración y extensiones."
    echo "         Se borrarán los siguientes directorios:"
    echo "         - $CONFIG_DIR"
    echo "         - $USER_DATA_DIR"
    echo "         - $EXTENSIONS_DIR"
    read -r -p "¿Estás absolutamente seguro de que quieres continuar? [s/N]: " choice
    if [[ ! "$choice" =~ ^[Ss]$ ]]; then
        echo "Operación de borrado cancelada."
        return
    fi

    echo "[INFO] Procediendo con el borrado completo..."
    if is_running; then
        stop
    fi
    echo "[INFO] Eliminando directorios de configuración y datos..."
    rm -rf "$CONFIG_DIR" "$USER_DATA_DIR" "$EXTENSIONS_DIR"
    echo "[ÉXITO] Todos los datos de code-server han sido eliminados."
    echo "[ACCIÓN REQUERIDA] Ejecuta este script de nuevo para realizar una instalación limpia."
    exit 0
}

status() {
    if is_running; then
        echo -n "[ESTADO] Proceso: CORRIENDO (PID: $(cat "$PID_FILE")). "
        if health_check; then
            echo "Servicio: ACTIVO."
        else
            echo "Servicio: INACTIVO (no responde)."
        fi
    else
        echo "[ESTADO] Proceso: DETENIDO."
    fi
}

view_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "--- Mostrando últimas 20 líneas de '$LOG_FILE' ---"
        tail -n 20 "$LOG_FILE"
        echo "----------------------------------------------------"
    else
        echo "[INFO] No se ha encontrado el archivo de log en '$LOG_FILE'."
    fi
}

show_configuration() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[ADVERTENCIA] No se encuentra el archivo de configuración."
        echo "               Puede que necesites instalar code-server primero."
        return
    fi
    echo "--- Configuración y Optimizaciones del Toolkit ---"
    echo
    echo "[ Rutas Persistentes ]"
    echo "  Directorio de Trabajo:   $WORKSPACE_DIR"
    echo "  Directorio de Extensiones: $EXTENSIONS_DIR"
    echo "  Archivo de Configuración:  $CONFIG_FILE"
    echo
    echo "[ Optimización de Rendimiento ]"
    echo "  Límite de Memoria (RAM):     4GB ($NODE_MEMORY_LIMIT)"
    echo "  Argumentos de Inicio Rápido: $CS_PERFORMANCE_ARGS"
    echo "  Delay de inicio (script):    ${STARTUP_DELAY_SECONDS}s"
    echo "------------------------------------------------"
}

# --- SCRIPT PRINCIPAL Y MENÚ ---
if [[ "$(whoami)" != "root" ]]; then
    echo "[ERROR] Este script debe ejecutarse como root." >&2
    exit 1
fi

# Flujo principal mejorado para manejar el estado post-purga
if ! command -v code-server >/dev/null 2>&1; then
    # Caso 1: code-server no está instalado en absoluto.
    install_and_configure
    echo && read -r -p "Instalación finalizada. Presiona Enter para ir al menú de gestión..."
elif [[ ! -f "$CONFIG_FILE" ]]; then
    # Caso 2: El comando existe, pero la configuración no (estado después de purgar).
    echo "[INFO] Se ha detectado una instalación de code-server sin configuración."
    echo "       Esto es normal después de una operación de 'Reset Total'."
    echo "       Iniciando el proceso de reconfiguración..."
    install_and_configure
    echo && read -r -p "Reconfiguración finalizada. Presiona Enter para ir al menú de gestión..."
else
    # Caso 3: Instalación normal y existente. Validar y continuar.
    echo "[INFO] Se ha detectado una instalación existente de code-server."
    validate_and_fix_config
    sleep 1
fi


while true; do
    clear
    echo "================================================"
    echo "           Code-Server Toolkit v1.8"
    echo "================================================"
    status
    echo "------------------------------------------------"
    echo " 1. Iniciar code-server"
    echo " 2. Detener code-server"
    echo " 3. Reinstalar / Actualizar"
    echo " 4. Reset Total (Purge)"
    echo " 5. Ver logs"
    echo " 6. Mostrar configuración y tweaks"
    echo " 7. Salir"
    echo "------------------------------------------------"
    read -r -p "Selecciona una opción [1-7]: " choice

    [[ "$choice" != "7" ]] && clear

    case "$choice" in
        1) start ;;
        2) stop ;;
        3) reinstall ;;
        4) purge_installation ;;
        5) view_logs ;;
        6) show_configuration ;;
        7) exit 0 ;;
        *) echo "[ERROR] Opción inválida. Inténtalo de nuevo." ;;
    esac

    [[ "$choice" != "7" ]] && echo && read -r -p "Presiona Enter para volver al menú..."
done
