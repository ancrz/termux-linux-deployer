#!/bin/bash
# ==============================================================================
# TITULO: Hyper-Pipeline Gemini (Maintenance & Evolution)
# VERSION: 5.3.0 (Golden Master)
# DESCRIPCION: Orquestador inteligente para Termux/Proot.
#              FIX: Redirección de IO para menús interactivos.
#              FIX: Detección agnóstica de rutas para UV.
# ==============================================================================

# --- 0. Configuración del Núcleo ---
set -o nounset  # Salir si se usan variables no definidas

# Paleta de Colores de Alta Visibilidad
BOLD='\033[1m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
PURPLE='\033[1;35m'
NC='\033[0m'

# Constantes de Configuración
NODE_TARGET_MAJOR="22"
GEMINI_PKG="@google/gemini-cli"
SYS_PYTHON="/usr/bin/python3"
DEFAULT_PYTHON_TARGET="3.14" # Actualizado a tu estándar actual

# --- 1. Motor de Logs y Validación ---

log_header() { echo -e "\n${BOLD}${PURPLE}=== $1 ===${NC}"; }
log_step() { echo -e "${CYAN}➜${NC} $1..."; }
log_success() { echo -e "${GREEN}✔ [EXITO]${NC} $1"; }
log_fail() { echo -e "${RED}✖ [FALLO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠ [AVISO]${NC} $1"; }

validate_cmd() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# --- 2. Capa 1: Herramientas de Sistema ---

maintain_system_layer() {
    log_header "Capa 1: Herramientas de Compilación (C++/System)"
    
    log_step "Verificando integridad de paquetes base"
    local PKGS=(
        build-essential 
        python3 
        python3-pip 
        python3-venv
        pkg-config 
        libsecret-1-dev 
        curl 
        git 
        ca-certificates
        jq
    )
    
    apt-get update -qq
    
    local NEEDS_INSTALL=0
    for pkg in "${PKGS[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            log_warn "Falta paquete crítico: $pkg"
            NEEDS_INSTALL=1
        fi
    done

    if [ $NEEDS_INSTALL -eq 1 ]; then
        log_step "Reparando capa de sistema..."
        if apt-get install -y -qq "${PKGS[@]}"; then
            log_success "Capa de sistema sincronizada."
        else
            log_fail "Error crítico actualizando apt."
            return 1
        fi
    else
        log_success "Sistema base optimizado."
    fi
}

# --- 3. Capa 2: Python Next-Gen (UV Manager) ---

# FIX CRÍTICO: UI enviada a >&2 para evitar captura de variable
fetch_and_select_version() {
    echo -e "${CYAN}➜ Consultando catálogo global de Python...${NC}" >&2
    
    local RAW_JSON
    RAW_JSON=$(curl -s --connect-timeout 5 https://endoflife.date/api/python.json)
    
    if [ -z "$RAW_JSON" ]; then
        echo -e "${YELLOW}⚠ API no disponible. Usando modo manual.${NC}" >&2
        echo -e "${YELLOW}Ingresa la versión manualmente (ej. 3.14):${NC}" >&2
        local MANUAL_VER
        read -r MANUAL_VER
        echo "${MANUAL_VER:-$DEFAULT_PYTHON_TARGET}"
        return
    fi

    local STABLE_VERSIONS
    mapfile -t STABLE_VERSIONS < <(echo "$RAW_JSON" | jq -r '.[0:5] | .[].latest')

    local MENU_OPTIONS=()
    # Actualizado para 2026+
    MENU_OPTIONS+=("3.15-dev (Bleeding Edge)")
    MENU_OPTIONS+=("3.14t (Free-Threading)")
    
    for ver in "${STABLE_VERSIONS[@]}"; do
        MENU_OPTIONS+=("$ver (Stable)")
    done

    echo -e "\n${BOLD}${CYAN}Versiones de Python Disponibles:${NC}" >&2
    local i=1
    for opt in "${MENU_OPTIONS[@]}"; do
        echo -e "  ${BOLD}$i)${NC} $opt" >&2
        ((i++))
    done
    echo -e "  ${BOLD}0)${NC} Escribir manualmente..." >&2

    local SELECTION
    read -r -p "Selecciona una opción [1-$((i-1))]: " SELECTION >&2

    # La única salida a STDOUT debe ser el resultado final limpio
    if [[ "$SELECTION" == "0" ]]; then
        local CUSTOM_VER
        read -r -p "Escribe la versión exacta: " CUSTOM_VER >&2
        echo "$CUSTOM_VER"
    elif [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -lt "$i" ]; then
        local CHOSEN="${MENU_OPTIONS[$((SELECTION-1))]}"
        echo "$CHOSEN" | awk '{print $1}'
    else
        echo "$DEFAULT_PYTHON_TARGET"
    fi
}

maintain_python_layer() {
    log_header "Capa 2: Python Next-Gen (Powered by UV)"
    
    if ! validate_cmd "uv"; then
        log_step "Instalando UV (The Astral Python Manager)"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        
        # Carga agnóstica de rutas (fix previo)
        if [ -f "$HOME/.local/bin/env" ]; then
            # shellcheck disable=SC1091
            source "$HOME/.local/bin/env"
        elif [ -f "$HOME/.cargo/env" ]; then
            # shellcheck disable=SC1091
            source "$HOME/.cargo/env"
        fi
        export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    else
        log_success "UV detectado: $(uv --version)"
        uv self update > /dev/null 2>&1 || true
    fi

    echo -e "\n${YELLOW}--- Selector de Versiones Python ---${NC}"
    # La magia ocurre aquí: fetch_and_select_version usa stderr para UI
    # y stdout SOLO para el valor de retorno.
    local TARGET_VER
    TARGET_VER=$(fetch_and_select_version)
    
    if [ -z "$TARGET_VER" ]; then
        TARGET_VER="$DEFAULT_PYTHON_TARGET"
    fi

    log_step "Instalando/Activando Python ${TARGET_VER}..."
    
    if uv python install "${TARGET_VER}"; then
        local INSTALLED_PATH
        INSTALLED_PATH=$(uv python find "${TARGET_VER}" 2>/dev/null)
        log_success "Python ${TARGET_VER} instalado en: $INSTALLED_PATH"
        log_warn "Entorno listo. Para usarlo: 'uv run --python ${TARGET_VER} tu_script.py'"
    else
        log_fail "No se pudo instalar Python ${TARGET_VER} vía UV."
    fi
}

# --- 4. Capa 3: Node.js Runtime ---

maintain_node_layer() {
    log_header "Capa 3: Node.js Runtime"
    
    local INSTALLED_VER=""
    if validate_cmd "node"; then
        INSTALLED_VER=$(node -v)
    fi

    if [[ "$INSTALLED_VER" != "v${NODE_TARGET_MAJOR}"* ]]; then
        log_step "Actualizando Node.js a la línea v${NODE_TARGET_MAJOR} LTS..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_TARGET_MAJOR}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -qq
        apt-get install -y -qq nodejs
        log_success "Node.js actualizado a $(node -v)"
    else
        log_success "Node.js está al día ($INSTALLED_VER)."
    fi

    npm config set fetch-retries 5
    npm config set fetch-retry-mintimeout 20000
}

# --- 5. Capa 4: Gemini CLI ---

maintain_gemini_layer() {
    log_header "Capa 4: Gemini CLI & Compilación"
    
    if [ ! -f "$SYS_PYTHON" ]; then
        log_fail "Python del sistema no encontrado en $SYS_PYTHON."
        log_step "Intentando linkear..."
        # shellcheck disable=SC2046
        ln -s "$(which python3)" "$SYS_PYTHON" || true
    fi

    log_step "Consultando estado de @google/gemini-cli..."
    
    local DO_INSTALL=0
    if ! validate_cmd "gemini"; then
        log_warn "Gemini CLI no está instalado."
        DO_INSTALL=1
    else
        # shellcheck disable=SC2155
        local LOCAL_VER=$(gemini --version)
        # shellcheck disable=SC2155
        local REMOTE_VER=$(npm view "$GEMINI_PKG" version --timeout=5000 2>/dev/null || echo "Unknown")
        
        if [ "$REMOTE_VER" != "Unknown" ] && [ "$LOCAL_VER" != "$REMOTE_VER" ]; then
            log_warn "Actualización disponible: $LOCAL_VER -> $REMOTE_VER"
            DO_INSTALL=1
        elif [ "$REMOTE_VER" == "Unknown" ]; then
             log_warn "No se pudo verificar versión remota."
             DO_INSTALL=1
        else
            log_success "Gemini CLI está en la última versión ($LOCAL_VER)."
        fi
    fi

    if [ $DO_INSTALL -eq 1 ]; then
        log_step "Iniciando compilación nativa (Watcher Activo)"
        log_warn "Usando Python del Sistema ($SYS_PYTHON) para asegurar compilación."
        
        if npm install -g "$GEMINI_PKG"@latest --python="$SYS_PYTHON" --foreground-scripts --no-audit; then
            echo ""
            log_success "Instalación/Actualización finalizada. Nueva versión: $(gemini --version)"
        else
            echo ""
            log_fail "La compilación falló."
        fi
    fi
}

# --- 6. Interfaz de Control ---

show_menu() {
    echo -e "\n${BOLD}${BLUE}██ Hyper-Pipeline Gemini v5.3.0 ██${NC}"
    echo -e "${CYAN}Entorno: Termux/Proot (Aarch64)${NC}"
    echo "-------------------------------------"
    echo "1. Diagnóstico de Salud (Validación)"
    echo "2. Mantenimiento Total (Actualizar Todo)"
    echo "3. Gestión Python (Menú Interactivo)"
    echo "4. Solo Actualizar Gemini CLI"
    echo "5. Limpieza de Emergencia (Caché/Tmp)"
    echo "6. Salir"
    echo "-------------------------------------"
}

run_diagnostics() {
    log_header "Diagnóstico del Pipeline"
    
    echo -n "System Python..: "
    if [ -f "$SYS_PYTHON" ]; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}MISSING${NC}"; fi
    
    echo -n "Build Tools....: "
    if dpkg -s build-essential &>/dev/null; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}MISSING${NC}"; fi
    
    echo -n "JQ (JSON Tool).: "
    if validate_cmd "jq"; then echo -e "${GREEN}OK${NC}"; else echo -e "${RED}MISSING${NC}"; fi

    echo -n "UV (Manager)...: "
    if validate_cmd "uv"; then echo -e "${GREEN}$(uv --version)${NC}"; else echo -e "${RED}MISSING${NC}"; fi
    
    echo -n "Node.js........: "
    if validate_cmd "node"; then echo -e "${GREEN}$(node -v)${NC}"; else echo -e "${RED}MISSING${NC}"; fi
    
    echo -n "Gemini CLI.....: "
    if validate_cmd "gemini"; then echo -e "${GREEN}$(gemini --version)${NC}"; else echo -e "${RED}MISSING${NC}"; fi
}

clean_house() {
    log_step "Purgando cachés..."
    npm cache clean --force
    apt-get clean
    uv cache clean
    log_success "Limpieza completada."
}

# --- Main Loop ---

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

while true; do
    show_menu
    read -r -p "Selecciona operación [1-6]: " OP
    case $OP in
        1) run_diagnostics; read -r -p "Enter..." ;;
        2) 
            maintain_system_layer
            maintain_python_layer 
            maintain_node_layer
            maintain_gemini_layer
            run_diagnostics
            read -r -p "Mantenimiento Total Completado. Enter..." 
            ;;
        3) maintain_python_layer; read -r -p "Enter..." ;;
        4) maintain_gemini_layer; read -r -p "Enter..." ;;
        5) clean_house; read -r -p "Enter..." ;;
        6) exit 0 ;;
        *) log_fail "Opción inválida." ;;
    esac
done