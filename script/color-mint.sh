#!/usr/bin/env bash
# ==============================================================================
#  Color Mint — personalización estética avanzada para Linux Mint 22.3 Cinnamon
#  Versión 3.0 · Autor: Filonux
#
#  Copyright (C) 2026 Filonux
#  Licencia:
#  ColorMint es software libre distribuido bajo los términos de la
#  GNU General Public License versión 3 (GPLv3).
#  Consulte el archivo LICENSE para obtener el texto completo de la licencia.
#
#  Todo el script vive en un único archivo (antes repartido en gui/, lib/,
#  presets/). No requiere sudo ni instala paquetes por su cuenta; solo avisa
#  si falta alguna herramienta.
#
#  USO:
#    ./color-mint.sh                → abre la interfaz gráfica (recomendado)
#    ./color-mint.sh gui            → igual que sin argumentos
#    ./color-mint.sh --help         → lista completa de comandos de línea de
#                                      órdenes (theme/panel/desktop/terminal/
#                                      fonts/backup/preset), para quien
#                                      prefiera la terminal a la GUI
#
#  Datos, backups, presets y logs viven en ~/.local/share/color-mint.
#
#  NOTAS TÉCNICAS (para quien mantenga este script):
#   - Cinnamon lee su propia copia de gtk-theme/icon-theme/cursor-theme/
#     cursor-size/font-name/text-scaling-factor bajo el esquema
#     "org.cinnamon.desktop.interface", NO bajo "org.gnome.desktop.interface"
#     (ese esquema existe en el sistema pero Muffin/cinnamon-settings-daemon
#     no lo escucha). Excepción: "monospace-font-name" NO tiene copia en
#     Cinnamon (Cinnamon no usa fuente monoespaciada en su propio shell) y
#     vive solo en "org.gnome.desktop.interface". Igualmente button-layout/
#     theme/titlebar-font van bajo "org.cinnamon.desktop.wm.preferences", no
#     "org.gnome.desktop.wm.preferences".
#   - El perfil por defecto de gnome-terminal se identifica con el esquema
#     "org.gnome.Terminal.ProfilesList" (clave "default"), no con
#     "org.gnome.terminal.legacy.profile-manager" (no existe).
#   - En un --field de yad tipo :NUM, el rango personalizado se expresa como
#     "valor!min..max!paso"; el tipo :SCL ignora cualquier rango y siempre
#     opera en 0..100.
#   - Cambiar el tamaño de cursor (org.cinnamon.desktop.interface cursor-
#     size) no siempre reemite XSETTINGS en caliente: es una limitación
#     conocida de cinnamon-settings-daemon, no de este script. cm_refresh_
#     cursor() aplica varias mitigaciones de mejor esfuerzo (ver esa
#     función); si el puntero ya dibujado no cambia, cerrar sesión sí lo
#     aplica siempre.
#   - Cada pestaña de la GUI es un proceso "yad --plug" independiente
#     embebido en el notebook principal ("yad --notebook --key"); --key/
#     --plug exige una clave entera (aquí se usa "$$"). Los procesos de
#     pestaña se lanzan en bucle infinito para poder redibujarse tras cada
#     "Aplicar" sin cerrar la pestaña.
#   - IMPORTANTE: YAD no conserva la barra de botones ("--button=...") de
#     un diálogo que se empotra en un notebook vía "--plug" — solo se
#     "traga" el área de contenido (campos), no la barra de acción. Por
#     eso los botones de cada pestaña se definen como CAMPOS del formulario
#     (tipo ":FBTN"), que sí viven en el área de contenido.
#   - Cada botón "Aplicar..." aplica los cambios DIRECTAMENTE: su comando
#     invoca este mismo script en modo "__apply <modo> ..." pasándole los
#     valores de los demás campos vía "%N" (YAD los sustituye ya citados
#     como un solo argumento cada uno, preservando espacios). No depende de
#     cerrar el diálogo ni de capturar su salida (ver cm_fbtn_apply): un
#     "--plug" embebido en un notebook NUNCA emite su salida al recibir
#     SIGUSR1 (confirmado con YAD 0.40.0), así que el mecanismo antiguo
#     basado en esa señal dejaba el bucle exterior esperando para siempre
#     y ningún ajuste llegaba a aplicarse. El valor de un campo BTN/FBTN
#     tampoco se ejecuta a través de una shell (YAD lo trocea en palabras
#     y ejecuta la primera como programa literal), por eso siempre va
#     envuelto en "bash -c '...'".
#   - "Nombre!Tooltip:TIPO" (tooltip por campo) NO funciona en YAD 0.40.0
#     (el que trae Mint 22.3): el texto tras "!" se muestra literalmente
#     como parte de la etiqueta, no como un tooltip aparte (confirmado
#     visualmente). Por eso cada pestaña usa un "--text=" corto al
#     principio y campos ":LBL" (con nombre vacío, o en negrita como
#     encabezado de grupo) para organizar en vez de tooltips.
# ==============================================================================
set -uo pipefail

# ============================================================================
# Rutas y configuración general
# ============================================================================
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

# Se asegura el bit +x sobre el propio archivo (silencioso si falla, p.ej.
# sistema de archivos de solo lectura): así funciona tanto si se lanzó con
# "bash script.sh" como con doble clic desde Nemo, sin "Permiso denegado"
# al reinvocarse a sí mismo más abajo (__tab).
[ -f "$SCRIPT_PATH" ] && [ ! -x "$SCRIPT_PATH" ] && chmod +x "$SCRIPT_PATH" 2>/dev/null

CM_HOME="${CM_HOME:-$HOME/.local/share/color-mint}"
CM_BACKUP_DIR="$CM_HOME/backups"
CM_PRESETS_DIR="$CM_HOME/presets"
CM_LOG_DIR="$CM_HOME/logs"
CM_LOG_FILE="$CM_LOG_DIR/color-mint.log"
CM_CSS_FILE="$CM_HOME/style.css"
CM_STATE_FILE="$CM_HOME/state.conf"
CM_THEME_PREFIX="CM"
CM_VERSION="3.0.0"
CM_AUTHOR="Filonux"

mkdir -p "$CM_BACKUP_DIR" "$CM_PRESETS_DIR" "$CM_LOG_DIR"

# ============================================================================
# utils — logging, notificaciones, helpers de color
# ============================================================================
cm_log() {
    local level="$1"; shift
    local msg="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $msg" >> "$CM_LOG_FILE" 2>/dev/null
}

cm_notify() {
    local title="$1" body="$2" icon="${3:-preferences-desktop-theme}"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -i "$icon" "$title" "$body" 2>/dev/null
    fi
    cm_log "INFO" "$title: $body"
}

# Escapa & < > para insertar texto dinámico (nombres de preset/backup,
# mensajes de error del sistema) dentro de marcado Pango sin romperlo. yad
# interpreta --text como Pango markup por defecto (ver --no-markup en su
# manual), así que cualquier "&" o "<" sin escapar rompía el diálogo.
_pango_escape() {
    local s="$1"
    # El '&' del reemplazo debe ir escapado como '\&': sin escapar, bash lo
    # trata como referencia al texto encontrado (igual que en sed), no como
    # carácter literal, y el resultado saldría mal formado.
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    printf '%s' "${s//>/\&gt;}"
}

# cm_notify_applied <título> <resumen> [línea1] [línea2] ...
# Complementa la notificación de escritorio (fácil de no ver, o desactivada)
# con un diálogo que el usuario debe cerrar a propósito, con el detalle real
# de lo aplicado. Se usa desde las seis pestañas tras cada "Aplicar". Si
# algún ítem trae "⚠" (lo añade cm_report en un fallo real), el diálogo se
# distingue con icono, título y color de cabecera de aviso en vez de éxito.
cm_notify_applied() {
    local title="$1" summary="$2"; shift 2
    local -a items=("$@")
    local it has_warning=0
    for it in "${items[@]}"; do
        case "$it" in ⚠*) has_warning=1; break ;; esac
    done

    local head dlg_title icon
    local -a dlg_type=(--info)
    if [ "$has_warning" -eq 1 ]; then
        head="<span size='large' weight='bold' foreground='#bf616a'>⚠ $(_pango_escape "$summary") — con avisos</span>"
        dlg_title="⚠ ${title} — avisos"
        icon="dialog-warning"
        dlg_type=(--warning)
    else
        head="<span size='large' weight='bold' foreground='#a3be8c'>✔ $(_pango_escape "$summary")</span>"
        dlg_title="$title"
        icon="preferences-desktop-theme"
    fi

    local body="$head"
    if [ ${#items[@]} -gt 0 ]; then
        body="${body}"$'\n\n'
        local esc
        for it in "${items[@]}"; do
            esc=$(_pango_escape "$it")
            case "$it" in
                ⚠*) body="${body}  <span foreground='#bf616a'>${esc}</span>"$'\n' ;;
                *)  body="${body}  ${esc}"$'\n' ;;
            esac
        done
    fi
    cm_notify "$title" "$summary" "$icon"
    if command -v yad >/dev/null 2>&1; then
        yad "${dlg_type[@]}" --css="$CM_CSS_FILE" --image="$icon" --title="$dlg_title" \
            --text="$body" --width=420 --button="Entendido:0" 2>/dev/null
    fi
}

# cm_report <etiqueta_de_éxito> <función_cm_apply_*> [args...]
# Ejecuta una función de aplicación y añade al array "applied" (ya declarado
# por quien llama, típicamente una pestaña de la GUI) su etiqueta de éxito o
# una advertencia con el error real devuelto por la función. Evita repetir
# el mismo "capturar salida + comprobar código" en cada ajuste de cada
# pestaña — y que un fallo real quede sin avisar, como pasaba antes.
cm_report() {
    local ok_label="$1"; shift
    local _m _clean
    if _m=$("$@" 2>&1); then
        applied+=("$ok_label")
    else
        _clean="${_m#ERROR: }"; _clean="${_clean#ADVERTENCIA: }"
        applied+=("⚠ ${ok_label%%:*} NO se pudo aplicar — ${_clean}")
    fi
}

# cm_gset <esquema> <clave> <valor> — igual que "gsettings set" pero
# comprobando de verdad el código de salida.
#
cm_gset() {
    local schema="$1" key="$2" out
    if ! out=$(gsettings set "$@" 2>&1); then
        cm_log "ERROR" "gsettings set ${schema} ${key} -> ${out}"
        echo "ERROR: no se pudo aplicar '${schema} ${key}': ${out:-fallo desconocido}" >&2
        return 1
    fi
    return 0
}

# cm_dwrite <ruta-dconf> <valor-gvariant> — igual que "dconf write" pero
# comprobando de verdad el código de salida (ver nota de cm_gset arriba; el
# mismo problema existía en cm_apply_terminal_palette con "dconf write").
cm_dwrite() {
    local path="$1" value="$2" out
    if ! out=$(dconf write "$path" "$value" 2>&1); then
        cm_log "ERROR" "dconf write ${path} ${value} -> ${out}"
        echo "ERROR: no se pudo escribir '${path}': ${out:-fallo desconocido}" >&2
        return 1
    fi
    return 0
}

cm_is_valid_hex() {
    [[ "$1" =~ ^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$ ]]
}

# yad --field=...:CLR puede devolver "#RRGGBB", "#RRGGBBAA" o "rgb(r,g,b)"
# según la versión instalada. Esta función normaliza a "#RRGGBB".
cm_normalize_hex() {
    local input="$1"
    if [[ "$input" =~ ^rgb\(([0-9]+),[[:space:]]*([0-9]+),[[:space:]]*([0-9]+)\)$ ]]; then
        printf '#%02X%02X%02X\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    elif [[ "$input" =~ ^#[0-9A-Fa-f]{8}$ ]]; then
        echo "${input:0:7}"
    elif [[ "$input" =~ ^#[0-9A-Fa-f]{6}$ ]]; then
        echo "$input"
    else
        echo "$input"
    fi
}

# yad --field=...:NUM devuelve el número formateado según la configuración
# regional: con punto ("32.000000") en locales tipo C/en_US, pero con COMA
# ("32,000000") en locales como es_ES/es_CO/es_MX (lo habitual en un Mint en
# español). Recortar solo "${var%%.*}" no hace nada en ese segundo caso, y el
# valor resultante ("32,000000") falla la validación numérica de todas las
# cm_apply_* correspondientes: el cambio se descarta EN SILENCIO. Esta
# función se queda solo con los dígitos iniciales sin importar el separador.
cm_num_int() {
    local raw="${1:-}"
    [[ "$raw" =~ ^[[:space:]]*(-?[0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

# Reinicia Cinnamon (nglayer) sin cerrar la sesión, para refrescar
# panel/menús/temas tras un cambio.
#
cm_reload_cinnamon() {
    cm_log "INFO" "Solicitando reinicio de Cinnamon"
    if command -v gdbus >/dev/null 2>&1; then
        if gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
             --method org.Cinnamon.Restart >/dev/null 2>&1; then
            return 0
        fi
        if gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
             --method org.Cinnamon.RestartCinnamon boolean:false >/dev/null 2>&1; then
            return 0
        fi
        cm_log "WARN" "Ninguna llamada D-Bus de reinicio funcionó; probando 'cinnamon --replace'"
    fi
    if [ -n "${DISPLAY:-}" ] && command -v cinnamon >/dev/null 2>&1; then
        nohup cinnamon --replace >/dev/null 2>&1 &
        disown 2>/dev/null || true
        return 0
    fi
    cm_log "WARN" "No se pudo reiniciar Cinnamon por ningún método (¿sesión no-Cinnamon?)"
    return 1
}

# cm_confirm <mensaje>  -> devuelve 0 si el usuario acepta
cm_confirm() {
    local msg="$1"
    yad --question --text="$msg" --title="Confirmar" \
        --button="Sí:0" --button="No:1" 2>/dev/null
}

# ============================================================================
# state — pequeño almacén clave=valor para recordar el ÚLTIMO valor aplicado
# de ajustes que no se pueden releer fiablemente desde gsettings/dconf
# (acento, opacidad del panel, paleta de terminal). Lo usan cm_save_preset
# (para no perder esos valores) y la GUI (para precargar los campos con lo
# último aplicado en vez de un valor fijo).
# ============================================================================
cm_state_set() {
    local key="$1" value="$2"
    mkdir -p "$CM_HOME"
    touch "$CM_STATE_FILE" 2>/dev/null
    { grep -v "^${key}=" "$CM_STATE_FILE" 2>/dev/null; printf '%s="%s"\n' "$key" "$value"; } \
        > "${CM_STATE_FILE}.tmp" 2>/dev/null && mv "${CM_STATE_FILE}.tmp" "$CM_STATE_FILE" 2>/dev/null
}

# cm_state_get <clave> <valor_por_defecto>
cm_state_get() {
    local key="$1" default="${2:-}" line val
    [ -f "$CM_STATE_FILE" ] || { echo "$default"; return 0; }
    line=$(grep "^${key}=" "$CM_STATE_FILE" 2>/dev/null | tail -n1)
    if [ -z "$line" ]; then
        echo "$default"
        return 0
    fi
    val="${line#*=}"
    val="${val%\"}"
    val="${val#\"}"
    echo "$val"
}

# Reordena una lista para que "$1" (el valor actualmente aplicado) quede
# primero, ya que YAD preselecciona siempre el primer elemento de un :CB.
# Si "$1" está vacío o no aparece en la lista, se añade igualmente al
# principio (si no está vacío) para reflejar la realidad del sistema aunque
# no coincida con ninguna opción conocida.
cm_reorder_current_first() {
    local current="$1"; shift
    local -a rest=()
    local it
    for it in "$@"; do
        [ "$it" = "$current" ] && continue
        rest+=("$it")
    done
    if [ -n "$current" ]; then
        printf '%s\n' "$current" "${rest[@]}"
    else
        printf '%s\n' "${rest[@]}"
    fi
}

# ============================================================================
# deps — comprobación e instalación de dependencias (solo para el modo GUI)
# ============================================================================
cm_check_dependencies() {
    local missing=() cmd m
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    local resp=""
    if [ -t 0 ]; then
        echo "Faltan las siguientes dependencias: ${missing[*]}"
        read -rp "¿Instalar automáticamente con apt (requiere sudo)? [s/N]: " resp
    elif command -v yad >/dev/null 2>&1; then
        if yad --question --title="Color Mint" \
             --text="Faltan las siguientes dependencias:\n${missing[*]}\n\n¿Instalar automáticamente con apt?\nSe abrirá una terminal para pedir la contraseña de sudo." \
             --button="Sí:0" --button="No:1" 2>/dev/null; then
            resp="s"
        fi
    else
        cm_notify "Color Mint" "Faltan dependencias (${missing[*]}) y no hay terminal ni yad disponibles para preguntar. Instálalas manualmente con: sudo apt install ${missing[*]}"
        exit 1
    fi

    if [[ "$resp" =~ ^[sS]$ ]]; then
        local pkgs=()
        for m in "${missing[@]}"; do
            case "$m" in
                yad)       pkgs+=("yad") ;;
                dconf)     pkgs+=("dconf-cli") ;;
                gsettings) pkgs+=("libglib2.0-bin") ;;
                gdbus)     pkgs+=("libglib2.0-bin") ;;
                *)         pkgs+=("$m") ;;
            esac
        done
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)

        if [ -t 0 ]; then
            sudo apt-get update && sudo apt-get install -y "${pkgs[@]}"
        elif command -v x-terminal-emulator >/dev/null 2>&1; then
            local sentinel
            sentinel="$(mktemp -u /tmp/color-mint-install-XXXXXX.done)"
            rm -f "$sentinel" 2>/dev/null

            cm_notify "Color Mint" "Instalando dependencias (${pkgs[*]})... esto puede tardar unos minutos."

            x-terminal-emulator -e bash -c \
                "sudo apt-get update && sudo apt-get install -y ${pkgs[*]}; echo \$? > '$sentinel'; echo; read -rp 'Pulsa Enter para cerrar...'" &

            local waited=0 max_wait=600   # tope de 10 minutos
            while [ ! -f "$sentinel" ] && [ "$waited" -lt "$max_wait" ]; do
                sleep 1
                waited=$((waited + 1))
            done

            if [ -f "$sentinel" ]; then
                rm -f "$sentinel" 2>/dev/null
            else
                cm_notify "Color Mint" "La instalación está tardando más de lo esperado; revisa la ventana de terminal abierta y vuelve a lanzar Color Mint cuando termine."
                exit 1
            fi
        else
            cm_notify "Color Mint" "No se encontró una terminal para instalar. Ejecuta manualmente: sudo apt install ${pkgs[*]}"
            exit 1
        fi
    else
        if [ -t 0 ]; then
            echo "No es posible continuar sin: ${missing[*]}"
        fi
        exit 1
    fi

    local still_missing=()
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        cm_notify "Color Mint" "No se pudieron instalar todas las dependencias (${still_missing[*]}). Instálalas manualmente con: sudo apt install ${still_missing[*]}"
        exit 1
    fi

    return 0
}

# ============================================================================
# backup — copias de seguridad y restauración
#
# Antes de aplicar cualquier cambio, el resto de funciones llaman a
# cm_backup_current, que vuelca los ajustes dconf relevantes y copia los
# archivos de tema/fuente tocados, para poder deshacer cualquier cambio.
# ============================================================================
cm_backup_current() {
    mkdir -p "$CM_BACKUP_DIR"
    local ts dest
    ts="$(date '+%Y%m%d_%H%M%S')"
    dest="$CM_BACKUP_DIR/backup_$ts"
    mkdir -p "$dest"

    dconf dump /org/cinnamon/               > "$dest/dconf_cinnamon.ini"         2>/dev/null
    dconf dump /org/gnome/desktop/interface/ > "$dest/dconf_gnome_interface.ini" 2>/dev/null
    dconf dump /org/gnome/terminal/         > "$dest/dconf_gnome_terminal.ini"  2>/dev/null
    dconf dump /org/nemo/                   > "$dest/dconf_nemo.ini"            2>/dev/null

    [ -d "$HOME/.themes" ]                       && cp -r "$HOME/.themes"                       "$dest/themes_snapshot"    2>/dev/null
    [ -d "$HOME/.config/gtk-3.0" ]               && cp -r "$HOME/.config/gtk-3.0"               "$dest/gtk-3.0_snapshot"   2>/dev/null
    [ -f "$HOME/.config/fontconfig/fonts.conf" ] && cp "$HOME/.config/fontconfig/fonts.conf"    "$dest/fonts.conf.snapshot" 2>/dev/null

    echo "$ts" > "$dest/manifest.txt"
    cm_log "INFO" "Backup creado en $dest"
    basename "$dest"
}

cm_list_backups() {
    mkdir -p "$CM_BACKUP_DIR"
    ls -1 "$CM_BACKUP_DIR" 2>/dev/null | sort -r
}

cm_restore_backup() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un backup (usa 'backup list' para verlos)." >&2; return 1; }
    case "$name" in */*|*..*) echo "ERROR: el nombre del backup no puede contener '/' ni '..'." >&2; return 1 ;; esac
    local src="$CM_BACKUP_DIR/$name"
    [ -d "$src" ] || { echo "Backup no encontrado: $name" >&2; return 1; }

    [ -f "$src/dconf_cinnamon.ini" ]         && dconf load /org/cinnamon/               < "$src/dconf_cinnamon.ini"
    [ -f "$src/dconf_gnome_interface.ini" ]  && dconf load /org/gnome/desktop/interface/ < "$src/dconf_gnome_interface.ini"
    [ -f "$src/dconf_gnome_terminal.ini" ]   && dconf load /org/gnome/terminal/         < "$src/dconf_gnome_terminal.ini"
    [ -f "$src/dconf_nemo.ini" ]             && dconf load /org/nemo/                   < "$src/dconf_nemo.ini"

    if command -v rsync >/dev/null 2>&1; then
        [ -d "$src/themes_snapshot" ]  && rsync -a --delete "$src/themes_snapshot/"  "$HOME/.themes/"        2>/dev/null
        [ -d "$src/gtk-3.0_snapshot" ] && rsync -a --delete "$src/gtk-3.0_snapshot/" "$HOME/.config/gtk-3.0/" 2>/dev/null
    else
        [ -d "$src/themes_snapshot" ]  && cp -r "$src/themes_snapshot/."  "$HOME/.themes/"        2>/dev/null
        [ -d "$src/gtk-3.0_snapshot" ] && cp -r "$src/gtk-3.0_snapshot/." "$HOME/.config/gtk-3.0/" 2>/dev/null
    fi
    [ -f "$src/fonts.conf.snapshot" ] && cp "$src/fonts.conf.snapshot" "$HOME/.config/fontconfig/fonts.conf" 2>/dev/null

    cm_reload_cinnamon
    cm_log "INFO" "Backup restaurado: $name"
}

# ============================================================================
# apply_theme — selección y aplicación de temas GTK / iconos / cursor / Cinnamon
# ============================================================================
cm_list_gtk_themes() {
    local d
    for d in /usr/share/themes "$HOME/.themes"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null
    done | sort -u
}

cm_list_icon_themes() {
    local d
    for d in /usr/share/icons "$HOME/.icons"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null
    done | sort -u
}

cm_list_cursor_themes() {
    # Los temas de cursor viven normalmente en las mismas carpetas que los de iconos
    cm_list_icon_themes
}

# Solo lista temas que tienen soporte real para Cinnamon (subcarpeta cinnamon/).
#
cm_list_cinnamon_themes() {
    local d sub
    for d in "$HOME/.themes" /usr/share/themes; do
        [ -d "$d" ] || continue
        while IFS= read -r sub; do
            [ -d "$sub/cinnamon" ] && basename "$sub"
        done < <(find "$d" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    done | sort -u
}

# ============================================================================
cm_list_mint_y_colors() {
    local base="$1"   # "Mint-Y" o "Mint-Y-Dark"
    local d
    { for d in /usr/share/themes "$HOME/.themes"; do
          [ -d "$d" ] || continue
          find "$d" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null
      done
    } | grep -E "^${base}-[A-Za-z]+$" | sed -E "s/^${base}-//" | sort -u
}

# cm_apply_mint_y_pack <color> <claro|oscuro>
cm_apply_mint_y_pack() {
    local color="${1:-}" mode="${2:-claro}"
    [ -z "$color" ] && { echo "ERROR: indica un color (usa 'theme list-mint-y-colors claro|oscuro')." >&2; return 1; }
    local base="Mint-Y"
    [ "$mode" = "oscuro" ] && base="Mint-Y-Dark"
    local gtk_name="${base}-${color}" icon_name="Mint-Y-${color}"

    cm_panel_locate_base "$gtk_name" >/dev/null 2>&1
    local has_cinnamon=$?
    if [ ! -d "/usr/share/themes/$gtk_name" ] && [ ! -d "$HOME/.themes/$gtk_name" ]; then
        echo "ERROR: no se encontró el tema '$gtk_name' instalado en este sistema." >&2
        return 1
    fi

    cm_apply_gtk_theme "$gtk_name"
    if [ -d "/usr/share/icons/$icon_name" ] || [ -d "$HOME/.icons/$icon_name" ]; then
        cm_apply_icon_theme "$icon_name"
    fi
    if [ "$has_cinnamon" -eq 0 ]; then
        cm_apply_cinnamon_theme "$gtk_name"
    fi
    cm_state_set "MINT_Y_COLOR" "$color"
    cm_state_set "MINT_Y_MODE" "$mode"
    echo "Paquete de color oficial Mint-Y aplicado: $gtk_name (iconos: $icon_name)"
}

cm_apply_gtk_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un tema GTK." >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface gtk-theme "$name" || return 1
    gsettings set org.cinnamon.desktop.wm.preferences theme "$name" 2>/dev/null || true
    echo "Tema GTK aplicado: $name"
}

cm_apply_icon_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un tema de iconos." >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface icon-theme "$name" || return 1
    echo "Tema de iconos aplicado: $name"
}

cm_apply_cursor_theme() {
    local name="${1:-}" skip_reload="${2:-0}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un tema de cursor." >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface cursor-theme "$name" || return 1
    cm_refresh_cursor "$skip_reload"
    echo "Tema de cursor aplicado: $name"
}

# Fuerza, con el mejor esfuerzo posible SIN sudo, un refresco del cursor tras
# cambiar su tema o tamaño.
#
CM_XRES_BEGIN="! >>> Color Mint: cursor (autogenerado, no editar a mano) >>>"
CM_XRES_END="! <<< Color Mint: cursor <<<"

# Quita de <archivo> el bloque delimitado por dos marcadores literales, si
# existe. Patrón "strip + append" compartido por gtk.css (acento GTK
# global), ~/.Xresources (cursor) y los overrides de cinnamon.css (red de
# seguridad de color, ver cm_css_ensure_override): evita acumular bloques
# duplicados cada vez que se reaplica el mismo ajuste.
cm_strip_marked_block() {
    local file="$1" b="$2" e="$3"
    [ -f "$file" ] || return 0
    awk -v b="$b" -v e="$e" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        skip!=1 {print}
    ' "$file" > "${file}.cm_tmp" 2>/dev/null && mv "${file}.cm_tmp" "$file" 2>/dev/null
}

cm_strip_xresources_block() { cm_strip_marked_block "$1" "$CM_XRES_BEGIN" "$CM_XRES_END"; }

cm_refresh_cursor() {
    local skip_reload="${1:-0}"
    local size current_theme other_theme envdir envfile xresfile
    size=$(gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'")
    current_theme=$(gsettings get org.cinnamon.desktop.interface cursor-theme 2>/dev/null | tr -d "'")

    if [ -n "$current_theme" ]; then
        other_theme="Adwaita"
        [ "$current_theme" = "Adwaita" ] && other_theme="Mint-Y"
        gsettings set org.cinnamon.desktop.interface cursor-theme "$other_theme" 2>/dev/null
        sleep 0.4
        gsettings set org.cinnamon.desktop.interface cursor-theme "$current_theme" 2>/dev/null
        sleep 0.2
    fi

    if [ -n "$size" ]; then
        gsettings set org.gnome.desktop.interface cursor-size "$size" 2>/dev/null || true
    fi
    if [ -n "$current_theme" ]; then
        gsettings set org.gnome.desktop.interface cursor-theme "$current_theme" 2>/dev/null || true
    fi

    # ~/.Xresources: además de aplicarlo en caliente con "xrdb -merge" (vale
    # solo para la sesión X actual), se deja también escrito en el archivo
    # para que sobreviva a un cierre de sesión — que sigue siendo, aun con
    # todas estas mitigaciones, la única vía 100% fiable de refrescar el
    # puntero ya dibujado (ver nota en cm_apply_cursor_size).
    if [ -n "$size" ] || [ -n "$current_theme" ]; then
        xresfile="$HOME/.Xresources"
        touch "$xresfile" 2>/dev/null
        cm_strip_xresources_block "$xresfile"
        {
            echo "$CM_XRES_BEGIN"
            [ -n "$current_theme" ] && echo "Xcursor.theme: ${current_theme}"
            [ -n "$size" ]          && echo "Xcursor.size: ${size}"
            echo "$CM_XRES_END"
        } >> "$xresfile" 2>/dev/null
        if command -v xrdb >/dev/null 2>&1; then
            xrdb -merge "$xresfile" 2>/dev/null
        fi
    fi

    if [ -n "$size" ]; then
        envdir="$HOME/.config/environment.d"
        envfile="$envdir/60-color-mint-cursor.conf"
        mkdir -p "$envdir" 2>/dev/null
        printf 'XCURSOR_SIZE=%s\n' "$size" > "$envfile" 2>/dev/null
    fi

    if [ -n "$size" ] && command -v cinnamon-settings-daemon >/dev/null 2>&1; then
        nohup cinnamon-settings-daemon --replace >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi

    [ "$skip_reload" = "1" ] || cm_reload_cinnamon
}

# Tamaño de cursor (org.cinnamon.desktop.interface cursor-size; valores
# habituales: 24 (por defecto), 32, 48, 64, 96).
#
cm_apply_cursor_size() {
    local size="${1:-}" skip_reload="${2:-0}"
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 16 ] || [ "$size" -gt 96 ]; then
        echo "ERROR: el tamaño de cursor debe ser un número entero entre 16 y 96." >&2
        return 1
    fi
    cm_gset org.cinnamon.desktop.interface cursor-size "$size" || return 1

    # Relectura real (no basta con que "gsettings set" devuelva 0): así se
    # distingue un guardado que de verdad falló de la limitación conocida de
    # Cinnamon en la que el puntero YA DIBUJADO no se refresca en caliente.
    local verify
    verify=$(gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'")
    if [ "$verify" != "$size" ]; then
        echo "ERROR: gsettings aceptó el cambio pero al releerlo el valor guardado es '${verify:-vacío}', no ${size}. Revisa el log." >&2
        return 1
    fi

    cm_refresh_cursor "$skip_reload"
    echo "Tamaño de cursor guardado y verificado en ${size}px. Nota: Cinnamon tiene un fallo conocido (no es de este script) por el que el puntero visible no siempre se refresca en caliente en ventanas ya abiertas; si no lo notas, cierra sesión y vuelve a entrar — el tamaño ya ha quedado guardado para entonces."
}

cm_current_cursor_size() {
    gsettings get org.cinnamon.desktop.interface cursor-size 2>/dev/null | tr -d "'" || echo "24"
}

cm_apply_cinnamon_theme() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un tema de Cinnamon." >&2; return 1; }
    cm_gset org.cinnamon.theme name "$name" || return 1
    echo "Tema de Cinnamon aplicado: $name"
}

# ============================================================================
# import_theme — instala un tema descargado (.zip/.tar.*, o carpeta ya
# descomprimida). Detecta si es un tema GTK/Cinnamon (gtk-3.0/, cinnamon/) o
# de iconos/cursor (cursors/, index.theme) y lo copia a ~/.themes o ~/.icons.
# No instala paquetes: si falta la herramienta de descompresión, avisa.
# ============================================================================
cm_import_theme() {
    local src="$1"
    if [ -z "$src" ]; then
        echo "ERROR: indica un archivo de tema (.zip/.tar.gz/.tar.xz/.tar.bz2) o una carpeta ya descomprimida." >&2
        return 1
    fi
    if [ ! -e "$src" ]; then
        echo "ERROR: no existe la ruta '$src'" >&2
        return 1
    fi

    local work extracted_dir
    work=$(mktemp -d) || { echo "ERROR: no se pudo crear un directorio temporal" >&2; return 1; }

    if [ -d "$src" ]; then
        extracted_dir="$src"
    else
        case "$src" in
            *.zip)
                if ! command -v unzip >/dev/null 2>&1; then
                    echo "ERROR: falta 'unzip' para abrir archivos .zip. Instálalo con: sudo apt install unzip" >&2
                    rm -rf "$work"; return 1
                fi
                unzip -q "$src" -d "$work" || { echo "ERROR: no se pudo extraer el .zip (¿archivo corrupto?)" >&2; rm -rf "$work"; return 1; }
                ;;
            *.tar.gz|*.tgz)
                tar -xzf "$src" -C "$work" 2>/dev/null || { echo "ERROR: no se pudo extraer el .tar.gz (¿archivo corrupto?)" >&2; rm -rf "$work"; return 1; }
                ;;
            *.tar.xz)
                tar -xJf "$src" -C "$work" 2>/dev/null || { echo "ERROR: no se pudo extraer el .tar.xz (¿falta xz-utils?)" >&2; rm -rf "$work"; return 1; }
                ;;
            *.tar.bz2|*.tbz2)
                tar -xjf "$src" -C "$work" 2>/dev/null || { echo "ERROR: no se pudo extraer el .tar.bz2 (¿falta bzip2?)" >&2; rm -rf "$work"; return 1; }
                ;;
            *.tar)
                tar -xf "$src" -C "$work" 2>/dev/null || { echo "ERROR: no se pudo extraer el .tar" >&2; rm -rf "$work"; return 1; }
                ;;
            *)
                echo "ERROR: formato no soportado ('$src'). Usa .zip, .tar.gz, .tar.xz, .tar.bz2/.tbz2, .tar o una carpeta ya descomprimida." >&2
                rm -rf "$work"; return 1
                ;;
        esac
        extracted_dir="$work"

        # Si el archivo tenía una única carpeta raíz (p.ej. "MiTema-main/"),
        # bajamos un nivel para no crear "Tema/Tema/", salvo que esa entrada
        # ya sea la propia estructura del tema (cinnamon, gtk-3.0, cursors...).
        local entries entry_count only_entry only_name
        entries=$(find "$extracted_dir" -mindepth 1 -maxdepth 1 2>/dev/null)
        entry_count=$(printf '%s\n' "$entries" | grep -c .)
        if [ "$entry_count" -eq 1 ]; then
            only_entry=$(printf '%s\n' "$entries")
            only_name=$(basename "$only_entry")
            case "$only_name" in
                cinnamon|gtk-3.0|gtk-2.0|cursors|index.theme) : ;;
                *) [ -d "$only_entry" ] && extracted_dir="$only_entry" ;;
            esac
        fi
    fi

    local dest_base
    if [ -d "$extracted_dir/cinnamon" ] || [ -d "$extracted_dir/gtk-3.0" ] || [ -d "$extracted_dir/gtk-2.0" ]; then
        dest_base="$HOME/.themes"
    elif [ -d "$extracted_dir/cursors" ]; then
        dest_base="$HOME/.icons"
    elif [ -f "$extracted_dir/index.theme" ] && grep -qi '^\[Icon Theme\]' "$extracted_dir/index.theme" 2>/dev/null; then
        dest_base="$HOME/.icons"
    elif [ -f "$extracted_dir/index.theme" ]; then
        dest_base="$HOME/.themes"
    else
        echo "ADVERTENCIA: no se reconoce la estructura del tema (sin gtk-3.0/, gtk-2.0/, cinnamon/, cursors/ ni index.theme). Se instalará en ~/.themes; revisa el contenido manualmente si no aparece donde esperas." >&2
        dest_base="$HOME/.themes"
    fi

    local dest_name dest
    if [ "$extracted_dir" = "$work" ]; then
        # El archivo no tenía una carpeta contenedora con nombre útil (su
        # contenido ya estaba "aplanado" en la raíz), así que usamos el
        # nombre del archivo original en vez del nombre aleatorio del
        # directorio temporal.
        dest_name=$(basename "$src")
        dest_name="${dest_name%.tar.gz}"; dest_name="${dest_name%.tgz}"
        dest_name="${dest_name%.tar.xz}"; dest_name="${dest_name%.tar.bz2}"
        dest_name="${dest_name%.tbz2}";   dest_name="${dest_name%.tar}"
        dest_name="${dest_name%.zip}"
    else
        dest_name=$(basename "$extracted_dir")
    fi
    [ -z "$dest_name" ] && dest_name="tema-importado"
    mkdir -p "$dest_base"
    dest="$dest_base/$dest_name"
    [ -e "$dest" ] && dest="${dest}-$(date '+%Y%m%d%H%M%S')-$$"

    if ! cp -r "$extracted_dir" "$dest"; then
        echo "ERROR: no se pudo copiar el tema a '$dest'" >&2
        rm -rf "$work"
        return 1
    fi

    rm -rf "$work" 2>/dev/null
    cm_log "INFO" "Tema importado: $src -> $dest"
    echo "$dest"
}

# Abre ~/.themes en el gestor de archivos (Nemo en Mint) para poder editar a
# mano un tema importado: cambiar iconos, retocar cinnamon.css, renombrar la
# carpeta, etc. Complementa la vía "Panel -> acento/opacidad", que siempre
# trabaja ya sobre una copia editable (CM-<tema>) del tema activo.
cm_open_themes_folder() {
    mkdir -p "$HOME/.themes"
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$HOME/.themes" >/dev/null 2>&1 &
    elif command -v nemo >/dev/null 2>&1; then
        nemo "$HOME/.themes" >/dev/null 2>&1 &
    elif command -v nautilus >/dev/null 2>&1; then
        nautilus "$HOME/.themes" >/dev/null 2>&1 &
    else
        echo "No se encontró un gestor de archivos (xdg-open/nemo/nautilus). Ruta: $HOME/.themes"
        return 1
    fi
    echo "$HOME/.themes"
}

# ============================================================================
# apply_panel — color de acento, fondo y opacidad del panel/menús de Cinnamon
#
# Cinnamon no expone variables CSS en sus temas ya compilados, así que este
# módulo edita una COPIA del tema (~/.themes/CM-<tema>/), nunca el original.
# Si el resultado no es el esperado: "Restaurar backup", o edita a mano
# ~/.themes/CM-<tema>/cinnamon/cinnamon.css
# ============================================================================
cm_panel_target_dir() {
    local base="$1"
    echo "$HOME/.themes/${CM_THEME_PREFIX}-${base}"
}

cm_panel_locate_base() {
    local base="$1" d
    for d in "$HOME/.themes/$base" "/usr/share/themes/$base"; do
        [ -d "$d/cinnamon" ] && { echo "$d"; return 0; }
    done
    return 1
}

# Prepara (o reutiliza) una copia editable del tema Cinnamon activo.
# Devuelve "ruta_destino|nombre_base" por stdout.
cm_panel_prepare_custom_theme() {
    local base
    base=$(gsettings get org.cinnamon.theme name 2>/dev/null | tr -d "'")
    [ -z "$base" ] && base="Mint-Y-Dark"

    # Si ya estamos trabajando sobre una copia CM-*, seguimos editando esa misma
    if [[ "$base" == ${CM_THEME_PREFIX}-* ]]; then
        echo "$HOME/.themes/$base|${base#"${CM_THEME_PREFIX}"-}"
        return 0
    fi

    cm_state_set "ORIGINAL_CINNAMON_THEME" "$base"

    local src target
    src=$(cm_panel_locate_base "$base") || { echo "ERROR: no se encontró el tema base '$base'" >&2; return 1; }
    target=$(cm_panel_target_dir "$base")

    mkdir -p "$HOME/.themes"
    [ -d "$target" ] || cp -r "$src" "$target"

    echo "$target|$base"
}

# Paleta de acentos predefinidos para la pestaña "Panel": pura conveniencia de
# GUI, no añade ninguna clave gsettings nueva. Al elegir uno se rellena el
# color con un clic en vez de tener que teclear/seleccionar el hex a mano;
# "personalizado" dice "usa lo que hay en el selector de color de arriba".
CM_ACCENT_PRESET_ORDER=(personalizado nord mint dracula gruvbox solarized rose-pine carmesi bosque catppuccin tokyo-night one-dark monokai cyberpunk sakura lavanda ambar turquesa esmeralda)
declare -A CM_ACCENT_PRESET_LABELS=(
    [personalizado]="Personalizado (usa el selector de color)"
    [nord]="Nord Frost — #88C0D0"
    [mint]="Mint Verde — #56B6C2"
    [dracula]="Dracula Púrpura — #BD93F9"
    [gruvbox]="Gruvbox Ámbar — #D79921"
    [solarized]="Solarized Azul — #268BD2"
    [rose-pine]="Rosé Pine — #EBBCBA"
    [carmesi]="Carmesí — #DC322F"
    [bosque]="Bosque — #3B7A57"
    [catppuccin]="Catppuccin Mocha — #89B4FA"
    [tokyo-night]="Tokyo Night — #7AA2F7"
    [one-dark]="One Dark — #61AFEF"
    [monokai]="Monokai — #66D9EF"
    [cyberpunk]="Cyberpunk Neón — #FF2E97"
    [sakura]="Sakura Rosa — #F7A8C4"
    [lavanda]="Lavanda Pastel — #B39DDB"
    [ambar]="Ámbar Cálido — #F5A623"
    [turquesa]="Turquesa — #1ABC9C"
    [esmeralda]="Esmeralda — #2ECC71"
)
declare -A CM_ACCENT_PRESET_HEX=(
    [nord]="#88C0D0"
    [mint]="#56B6C2"
    [dracula]="#BD93F9"
    [gruvbox]="#D79921"
    [solarized]="#268BD2"
    [rose-pine]="#EBBCBA"
    [carmesi]="#DC322F"
    [bosque]="#3B7A57"
    [catppuccin]="#89B4FA"
    [tokyo-night]="#7AA2F7"
    [one-dark]="#61AFEF"
    [monokai]="#66D9EF"
    [cyberpunk]="#FF2E97"
    [sakura]="#F7A8C4"
    [lavanda]="#B39DDB"
    [ambar]="#F5A623"
    [turquesa]="#1ABC9C"
    [esmeralda]="#2ECC71"
)

# Activa (gsettings) la copia editable del tema tras escribirle un color
# nuevo. Antes esto era un "gsettings set" suelto, sin comprobar el código de
# salida, en las 8 funciones de color de más abajo: si esa activación
# fallaba, el color quedaba escrito en el CSS pero Cinnamon seguía usando el
# tema anterior, y la función igualmente informaba "aplicado" — cambio
# invisible reportado como éxito. Con cm_gset el fallo se detecta y se
# propaga como error real.
cm_panel_activate_custom_theme() {
    local base="$1"
    cm_gset org.cinnamon.theme name "${CM_THEME_PREFIX}-${base}" || {
        echo "ERROR: el color se guardó en el tema personalizado pero Cinnamon no pudo activarlo. Prueba 'Restaurar último backup' o revisa el log." >&2
        return 1
    }
}

cm_accent_preset_key_from_label() {
    local label="$1" k
    for k in "${CM_ACCENT_PRESET_ORDER[@]}"; do
        [ "${CM_ACCENT_PRESET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# El fondo real del panel NO vive en "#panel" (ese bloque solo trae
# font-weight/height/width/color de icono) sino en el selector agrupado
# ".panel-top, .panel-bottom, .panel-left, .panel-right" (confirmado contra
# el cinnamon.css real de Mint-Y, rama master.mint22). "#panel" se sigue
# usando aparte para texto/iconos (CM_PANEL_FG_BLOCK_RE), donde sí es
# correcto: ahí vive "color:" para el tray y los símbolos del panel.
#
# Los *_BLOCK_RE exigen "," "{" o ":" justo tras el nombre (espacios de por
# medio permitidos) en vez de cualquier carácter: así el selector cuenta solo
# si ES ese elemento, no un descendiente ni un id/clase que solo comparte
# prefijo (".popup-menu #notification...", "#panelLeft", ".menu-top"...).
# Verificado contra el cinnamon.css real de Mint-Y: sin ese límite, el rango
# de sed arrancaba ahí y el color se colaba en bloques sin relación.
CM_PANEL_BG_BLOCK_RE='\.panel-(top|bottom|left|right)([[:space:]]*[,{]|:)'
CM_PANEL_FG_BLOCK_RE='(#|\.)panel([[:space:]]*[,{]|:)'
CM_MENU_BLOCK_RE='\.(menu|popup-menu)([[:space:]]*[,{]|:)'
CM_TOOLTIP_BLOCK_RE='(#[Tt]ooltip|\.tooltip)([[:space:]]*[,{]|:)'

# cm_css_ensure_override <cinnamon.css> <id> <selector-css> <declaración>
# Red de seguridad: cuando un tema no trae el selector esperado (o no hay
# ningún color de referencia que sustituir), en vez de fallar con un aviso,
# añade una regla propia al final del archivo. En CSS, a igual especifi-
# cidad, la regla declarada más tarde gana — así que repetir el MISMO
# selector al final basta para imponerse, sin "!important". Se marca con un
# id (vía cm_strip_marked_block) para poder reemplazarla en la siguiente
# aplicación sin acumular copias.
cm_css_ensure_override() {
    local css="$1" id="$2" selector="$3" decl="$4"
    local b="/* >>> Color Mint override:${id} (autogenerado, no editar a mano) >>> */"
    local e="/* <<< Color Mint override:${id} <<< */"
    cm_strip_marked_block "$css" "$b" "$e"
    { echo "$b"; echo "${selector} { ${decl} }"; echo "$e"; } >> "$css" 2>/dev/null
}

CM_COLOR_TARGET_ORDER=(acento fondo texto menu_fondo menu_texto tooltip_fondo tooltip_texto acento_gtk)
declare -A CM_COLOR_TARGET_LABELS=(
    [acento]="Acento (resaltados, casillas y enlaces)"
    [fondo]="Fondo del panel"
    [texto]="Texto e iconos del panel"
    [menu_fondo]="Fondo de los menús"
    [menu_texto]="Texto de los menús"
    [tooltip_fondo]="Fondo de los globos de ayuda"
    [tooltip_texto]="Texto de los globos de ayuda"
    [acento_gtk]="Acento en todas las apps (no solo el panel)"
)
cm_color_target_key_from_label() {
    local label="$1" k
    for k in "${CM_COLOR_TARGET_ORDER[@]}"; do
        [ "${CM_COLOR_TARGET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "acento"
}

# Detecta el color hexadecimal más repetido en TODO el archivo, ignorando
# negros/blancos/grises típicos y, opcionalmente, una lista adicional de hex
# a excluir pasados como argumentos: cm_panel_dominant_hex <css> [hex...]
#
cm_panel_dominant_hex() {
    local css="$1"; shift
    local pattern='^#(000000|ffffff|f0f0f0|fafafa|303030|202020'
    local hex clean
    for hex in "$@"; do
        [ -z "$hex" ] && continue
        clean="${hex#\#}"
        pattern="${pattern}|${clean}"
    done
    pattern="${pattern})\$"
    grep -oE '#[0-9A-Fa-f]{6}' "$css" 2>/dev/null \
        | grep -viE "$pattern" \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_panel_bg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

# Igual, pero para el color de TEXTO/iconos: busca la propiedad "color:" (no
# "background-color:"). El ancla "^" al inicio de línea es la clave para
# distinguirlas, ya que el CSS compilado de Cinnamon suele llevar una
# declaración por línea (si no encuentra nada, el tema probablemente no
# fija un color de texto plano ahí y no hay nada seguro que sustituir).
cm_panel_fg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_PANEL_FG_BLOCK_RE}/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_accent_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        echo "ERROR: indica un color en formato #RRGGBB." >&2
        return 1
    fi

    # Admite también la salida cruda de yad --field=:CLR (rgb(...), #RRGGBBAA)
    # por si esta función se llama con ese valor sin pasar antes por el form.
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2
        return 1
    fi
    # Expande #RGB a #RRGGBB para que el reemplazo en el CSS sea consistente
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"

    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }

    local excl_bg excl_fg excl_menu_bg excl_menu_fg excl_tip_bg excl_tip_fg
    excl_bg=$(cm_panel_bg_dominant_hex "$css")
    excl_fg=$(cm_panel_fg_dominant_hex "$css")
    excl_menu_bg=$(cm_panel_menu_bg_dominant_hex "$css")
    excl_menu_fg=$(cm_panel_menu_fg_dominant_hex "$css")
    excl_tip_bg=$(cm_panel_tooltip_bg_dominant_hex "$css")
    excl_tip_fg=$(cm_panel_tooltip_fg_dominant_hex "$css")
    old_hex=$(cm_panel_dominant_hex "$css" "$excl_bg" "$excl_fg" "$excl_menu_bg" "$excl_menu_fg" "$excl_tip_bg" "$excl_tip_fg")
    if [ -z "$old_hex" ]; then
        echo "ADVERTENCIA: no se detectó un color de acento dominante; no se aplicó ningún cambio." >&2
        return 1
    fi

    sed -i "s/${old_hex}/${new_hex}/gI" "$css"
    # Aplica también al gtk.css incluido en el mismo tema, si existe
    [ -f "$target/gtk-3.0/gtk.css" ] && sed -i "s/${old_hex}/${new_hex}/gI" "$target/gtk-3.0/gtk.css"

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "ACCENT_COLOR" "$new_hex"
    echo "Acento aplicado: ${old_hex} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_replace_block_bg_color() {
    local css="$1" block="$2" new_hex="$3"
    local r g b before_sum after_sum old_desc
    r=$((16#${new_hex:1:2})); g=$((16#${new_hex:3:2})); b=$((16#${new_hex:5:2}))

    old_desc=$(sed -n -E "/${block}/,/\}/ s/.*(rgba\\([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9.]+\\)).*/\\1/p" "$css" 2>/dev/null | head -n1)
    before_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
    sed -i -E "/${block}/,/\}/ s/rgba\\([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+,[[:space:]]*([0-9.]+)\\)/rgba(${r}, ${g}, ${b}, \\1)/gI" "$css"
    after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')

    if [ "$before_sum" != "$after_sum" ]; then
        echo "${old_desc:-rgba(...)}"
        return 0
    fi

    local old_hex
    old_hex=$(sed -n -E "/${block}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\\2/p" "$css" 2>/dev/null | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
    [ -z "$old_hex" ] && return 1

    sed -i -E "/${block}/,/\}/ s/(background(-color)?:[[:space:]]*)#[0-9A-Fa-f]{6}/\\1${new_hex}/gI" "$css"
    echo "$old_hex"
    return 0
}

cm_apply_panel_bg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        echo "ERROR: indica un color en formato #RRGGBB." >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }

    if ! old_desc=$(cm_replace_block_bg_color "$css" "$CM_PANEL_BG_BLOCK_RE" "$new_hex"); then
        cm_css_ensure_override "$css" "panel-bg" ".panel-top, .panel-bottom, .panel-left, .panel-right" "background-color: ${new_hex};"
        old_desc="(sin coincidencia en el tema, aplicado como override)"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_BG_COLOR" "$new_hex"
    echo "Fondo del panel: ${old_desc} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_apply_panel_fg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        echo "ERROR: indica un color en formato #RRGGBB." >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }

    old_hex=$(cm_panel_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "panel-fg" "#panel" "color: ${new_hex};"
        old_hex="(sin coincidencia en el tema, aplicado como override)"
    else
        sed -i -E "/${CM_PANEL_FG_BLOCK_RE}/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" "$css"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_FG_COLOR" "$new_hex"
    echo "Texto/iconos del panel: ${old_hex} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_panel_menu_bg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}
cm_panel_menu_fg_dominant_hex() {
    local css="$1"
    sed -n -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$css" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_menu_bg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        echo "ERROR: indica un color en formato #RRGGBB." >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }

    if ! old_desc=$(cm_replace_block_bg_color "$css" "$CM_MENU_BLOCK_RE" "$new_hex"); then
        cm_css_ensure_override "$css" "menu-bg" ".menu, .popup-menu" "background-color: ${new_hex};"
        old_desc="(sin coincidencia en el tema, aplicado como override)"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "MENU_BG_COLOR" "$new_hex"
    echo "Fondo de menús: ${old_desc} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_apply_menu_fg_color() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        echo "ERROR: indica un color en formato #RRGGBB." >&2
        return 1
    fi
    local new_hex
    new_hex=$(cm_normalize_hex "$raw")
    if ! cm_is_valid_hex "$new_hex"; then
        echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2
        return 1
    fi
    if [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }

    old_hex=$(cm_panel_menu_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "menu-fg" ".menu, .popup-menu" "color: ${new_hex};"
        old_hex="(sin coincidencia en el tema, aplicado como override)"
    else
        sed -i -E "/${CM_MENU_BLOCK_RE}/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" "$css"
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "MENU_FG_COLOR" "$new_hex"
    echo "Texto de menús: ${old_hex} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_panel_tooltip_fg_dominant_hex() {
    sed -n -E "/#[Tt]ooltip|\.tooltip([^-]|$)/,/\}/ s/^[[:space:]]*color:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\1/p" "$1" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_panel_tooltip_bg_dominant_hex() {
    sed -n -E "/#[Tt]ooltip|\.tooltip([^-]|$)/,/\}/ s/.*background(-color)?:[[:space:]]*#([0-9A-Fa-f]{6}).*/#\2/p" "$1" 2>/dev/null \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

cm_apply_tooltip_bg_color() {
    local raw="${1:-}" new_hex
    [ -z "$raw" ] && { echo "ERROR: indica un color en formato #RRGGBB." >&2; return 1; }
    new_hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$new_hex" || { echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2; return 1; }
    [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    local info target base css old_desc
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"; base="${info##*|}"; css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }
    if ! old_desc=$(cm_replace_block_bg_color "$css" '#[Tt]ooltip' "$new_hex"); then
        cm_css_ensure_override "$css" "tooltip-bg" "#Tooltip" "background-color: ${new_hex};"
        old_desc="(sin coincidencia en el tema, aplicado como override)"
    fi
    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "TOOLTIP_BG_COLOR" "$new_hex"
    echo "Fondo de tooltips: ${old_desc} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_apply_tooltip_fg_color() {
    local raw="${1:-}" new_hex
    [ -z "$raw" ] && { echo "ERROR: indica un color en formato #RRGGBB." >&2; return 1; }
    new_hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$new_hex" || { echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2; return 1; }
    [[ "$new_hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && new_hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    local info target base css old_hex
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"; base="${info##*|}"; css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado en $target" >&2; return 1; }
    old_hex=$(cm_panel_tooltip_fg_dominant_hex "$css")
    if [ -z "$old_hex" ]; then
        cm_css_ensure_override "$css" "tooltip-fg" "#Tooltip" "color: ${new_hex};"
        old_hex="(sin coincidencia en el tema, aplicado como override)"
    else
        sed -i -E "/#[Tt]ooltip/,/\}/ s/^([[:space:]]*color:[[:space:]]*)#[0-9A-Fa-f]{6}/\1${new_hex}/gI" "$css"
    fi
    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "TOOLTIP_FG_COLOR" "$new_hex"
    echo "Texto de tooltips: ${old_hex} -> ${new_hex} (tema: ${CM_THEME_PREFIX}-${base})"
}

cm_reset_panel_colors() {
    local original had_gtk_accent=0
    original=$(cm_state_get "ORIGINAL_CINNAMON_THEME" "")
    cm_reset_gtk_accent_color >/dev/null 2>&1 && had_gtk_accent=1
    if [ -z "$original" ] && [ "$had_gtk_accent" -eq 0 ]; then
        echo "No hay ninguna personalización de color que restablecer todavía." >&2
        return 1
    fi
    local restore_fail=0
    if [ -n "$original" ]; then
        cm_gset org.cinnamon.theme name "$original" || restore_fail=1
    fi
    local _msg="Colores restablecidos"
    if [ -n "$original" ]; then
        if [ "$restore_fail" -eq 1 ]; then
            _msg="${_msg} (⚠ no se pudo reactivar el tema original: $original)"
        else
            _msg="${_msg} (tema original: $original)"
        fi
    fi
    [ "$had_gtk_accent" -eq 1 ] && _msg="${_msg}, acento GTK global incluido"
    echo "${_msg}."
}

# --- acento GTK global: afecta a TODAS las apps GTK3/GTK4, no solo al panel
#
# GTK no ofrece una clave gsettings de "color de acento" en GTK3 (eso es cosa
# de libadwaita/GTK4 en escritorios más nuevos); el truco estándar es
# redefinir los "named colors" que los temas ya usan internamente
# (theme_selected_bg_color/fg_color, y sus equivalentes accent_* de GTK4) en
# el gtk.css de USUARIO, que GTK carga con prioridad más alta que la del
# tema y aplica en caliente a las apps que ya estén abiertas.
CM_GTK_ACCENT_BEGIN="/* >>> Color Mint: acento GTK global (autogenerado, no editar a mano) >>> */"
CM_GTK_ACCENT_END="/* <<< Color Mint: acento GTK global <<< */"

# Quita el bloque de Color Mint de un gtk.css si existe (usado tanto al
# reaplicar como al restablecer, para no acumular bloques duplicados).
cm_strip_gtk_accent_block() { cm_strip_marked_block "$1" "$CM_GTK_ACCENT_BEGIN" "$CM_GTK_ACCENT_END"; }

cm_apply_gtk_accent_color() {
    local raw="${1:-}" hex
    [ -z "$raw" ] && { echo "ERROR: indica un color en formato #RRGGBB." >&2; return 1; }
    hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$hex" || { echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2; return 1; }
    if [[ "$hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]]; then
        hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"
    fi

    # Texto blanco o negro según la luminancia del acento, para que siga
    # siendo legible sobre cualquier color elegido.
    local r g b fg
    r=$((16#${hex:1:2})); g=$((16#${hex:3:2})); b=$((16#${hex:5:2}))
    if [ $(( (r*299 + g*587 + b*114) / 1000 )) -gt 150 ]; then fg="#000000"; else fg="#ffffff"; fi

    local dir file
    for dir in "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"; do
        mkdir -p "$dir" 2>/dev/null
        file="$dir/gtk.css"
        touch "$file" 2>/dev/null
        cm_strip_gtk_accent_block "$file"
        {
            echo "$CM_GTK_ACCENT_BEGIN"
            echo "@define-color theme_selected_bg_color ${hex};"
            echo "@define-color theme_selected_fg_color ${fg};"
            echo "@define-color accent_color ${hex};"
            echo "@define-color accent_bg_color ${hex};"
            echo "@define-color accent_fg_color ${fg};"
            echo "*:selected, *:selected:focus { background-color: ${hex}; color: ${fg}; }"
            echo "$CM_GTK_ACCENT_END"
        } >> "$file"
    done

    cm_state_set "GTK_ACCENT_COLOR" "$hex"
    echo "Acento GTK global aplicado: $hex (afecta a todas las apps GTK3/GTK4; las que ya estaban abiertas suelen refrescarse solas, si no, reábrelas)"
}

cm_reset_gtk_accent_color() {
    local dir file found=0
    for dir in "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"; do
        file="$dir/gtk.css"
        [ -f "$file" ] || continue
        grep -qF "$CM_GTK_ACCENT_BEGIN" "$file" 2>/dev/null || continue
        cm_strip_gtk_accent_block "$file"
        found=1
    done
    if [ "$found" -eq 1 ]; then
        echo "Acento GTK global restablecido (quitado el override de Color Mint)"
        return 0
    fi
    echo "No hay ningún acento GTK global aplicado por Color Mint." >&2
    return 1
}

cm_apply_panel_opacity() {
    local pct="${1:-}"   # 0-100
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 0 ] || [ "$pct" -gt 100 ]; then
        echo "ERROR: la opacidad debe ser un número entero entre 0 y 100." >&2
        return 1
    fi

    local info target base css alpha
    info=$(cm_panel_prepare_custom_theme) || return 1
    target="${info%%|*}"
    base="${info##*|}"
    css="$target/cinnamon/cinnamon.css"
    [ -f "$css" ] || { echo "ERROR: cinnamon.css no encontrado" >&2; return 1; }

    # LC_ALL=C: awk formatea "%.2f" con la coma decimal del locale regional
    # (es_ES/es_CO/es_MX...) en vez del punto, p.ej. "0,90". Ese valor se
    # inyecta tal cual en "rgba(r, g, b, 0,90)", sintaxis CSS inválida que
    # Cinnamon descarta en silencio (bug confirmado, ver cabecera del script).
    alpha=$(LC_ALL=C awk -v p="$pct" 'BEGIN{printf "%.2f", p/100}')

    # Ajusta el alfa de los fondos rgba(...) dentro de los bloques del panel.
    # Se compara el archivo antes/después para poder avisar si el tema no usa
    # rgba(...) en ese bloque (p.ej. usa colores hex planos) y por tanto el
    # cambio no tuvo ningún efecto visual real.
    local before_sum after_sum
    before_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
    sed -i -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/rgba\\(([0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+),[[:space:]]*[0-9.]+\\)/rgba(\\1, ${alpha})/g" "$css"
    after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')

    if [ "$before_sum" = "$after_sum" ]; then
        local hexbg r g b
        hexbg=$(cm_panel_bg_dominant_hex "$css")
        if [ -n "$hexbg" ]; then
            r=$((16#${hexbg:1:2})); g=$((16#${hexbg:3:2})); b=$((16#${hexbg:5:2}))
            sed -i -E "/${CM_PANEL_BG_BLOCK_RE}/,/\}/ s/(background(-color)?:[[:space:]]*)#[0-9A-Fa-f]{6}/\1rgba(${r}, ${g}, ${b}, ${alpha})/gI" "$css"
            after_sum=$(md5sum "$css" 2>/dev/null | awk '{print $1}')
        fi
    fi

    cm_panel_activate_custom_theme "$base" || return 1
    cm_state_set "PANEL_OPACITY" "$pct"

    if [ "$before_sum" = "$after_sum" ]; then
        echo "ADVERTENCIA: no se encontró ningún fondo (rgba(...) ni hexadecimal plano) en el bloque del panel de este tema; la opacidad podría no haber cambiado visualmente." >&2
    fi
    echo "Opacidad del panel ajustada a ${pct}%"
}

# Alto (px) del panel principal (id 1). "org.cinnamon panels-height" es una
# lista de cadenas "idPanel:alto" (sin campo de monitor, a diferencia de
# panels-enabled). El panel de Ajustes limita a 60px por su propia interfaz;
# aquí se acepta 16-100.
cm_apply_panel_height() {
    local px="${1:-}"
    if ! [[ "$px" =~ ^[0-9]+$ ]] || [ "$px" -lt 16 ] || [ "$px" -gt 100 ]; then
        echo "ERROR: el alto del panel debe ser un número entero entre 16 y 100." >&2
        return 1
    fi

    local current entry id height found=0
    local -a new_list=()
    current=$(gsettings get org.cinnamon panels-height 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        IFS=':' read -r id height <<< "$entry"
        if [ "$id" = "1" ]; then
            new_list+=("'${id}:${px}'")
            found=1
        else
            new_list+=("'${entry}'")
        fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')

    [ "$found" -eq 0 ] && new_list+=("'1:${px}'")

    local joined="" item first=1
    for item in "${new_list[@]}"; do
        if [ "$first" -eq 1 ]; then joined="$item"; first=0; else joined="$joined, $item"; fi
    done

    cm_gset org.cinnamon panels-height "[$joined]" || return 1
    echo "Alto del panel ajustado a ${px}px"
}

# Lee el alto actual del panel con id 1 (para precargar el formulario)
cm_current_panel_height() {
    local current entry id height result="40"
    current=$(gsettings get org.cinnamon panels-height 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        IFS=':' read -r id height <<< "$entry"
        if [ "$id" = "1" ]; then result="$height"; break; fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "$result"
}

# ============================================================================
# apply_desktop — posición del panel, botones de ventana y esquinas activas
#
# Usa exclusivamente esquemas gsettings de Cinnamon verificados contra su
# .gschema.xml oficial (ver nota de mantenimiento en la cabecera del script):
#   org.cinnamon panels-enabled                      -> posición del panel
#   org.cinnamon.desktop.wm.preferences button-layout -> botones de ventana
#   org.cinnamon hotcorner-layout                     -> esquinas activas
# ============================================================================

# --- posición del panel -----------------------------------------------------
cm_apply_panel_position() {
    local position="$1"
    case "$position" in
        top|bottom) : ;;
        *) echo "ERROR: posición no válida ('$position'). Usa 'top' o 'bottom'." >&2; return 1 ;;
    esac

    local current entry id mon pos found=0
    local -a new_list=()
    current=$(gsettings get org.cinnamon panels-enabled 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        IFS=':' read -r id mon pos <<< "$entry"
        if [ "$id" = "1" ]; then
            new_list+=("'${id}:${mon}:${position}'")
            found=1
        else
            new_list+=("'${entry}'")
        fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')

    [ "$found" -eq 0 ] && new_list+=("'1:0:${position}'")

    local joined="" item first=1
    for item in "${new_list[@]}"; do
        if [ "$first" -eq 1 ]; then joined="$item"; first=0; else joined="$joined, $item"; fi
    done

    cm_gset org.cinnamon panels-enabled "[$joined]" || return 1
    echo "Panel principal movido a: ${position}"
}

# Lee la posición actual del panel con id 1 (para precargar presets)
cm_current_panel_position() {
    local current entry id mon pos result="bottom"
    current=$(gsettings get org.cinnamon panels-enabled 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        IFS=':' read -r id mon pos <<< "$entry"
        if [ "$id" = "1" ]; then result="$pos"; break; fi
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "$result"
}

# --- botones de ventana ------------------------------------------------------
# Claves cortas para usar desde la CLI o desde presets; cada una mapea a la
# cadena real de button-layout ("izquierda:derecha", nombres separados por
# comas). Un valor que no coincida con ninguna clave se usa tal cual como
# cadena personalizada (para layouts a medida, p.ej. "close,minimize:maximize").
CM_BUTTON_PRESET_ORDER=(derecha izquierda gnome mac-clasico compacto menu-izquierda solo-cerrar-izquierda)
declare -A CM_BUTTON_PRESETS=(
    [derecha]=":minimize,maximize,close"
    [izquierda]="close,maximize,minimize:"
    [gnome]=":close"
    [mac-clasico]="close:minimize,maximize"
    [compacto]=":minimize,close"
    [menu-izquierda]="menu:minimize,maximize,close"
    [solo-cerrar-izquierda]="close:"
)
declare -A CM_BUTTON_PRESET_LABELS=(
    [derecha]="Derecha: minimizar, maximizar, cerrar"
    [izquierda]="Izquierda: cerrar, maximizar, minimizar"
    [gnome]="Solo cerrar (estilo GNOME)"
    [mac-clasico]="Mac clásico (cerrar a la izquierda)"
    [compacto]="Compacto: minimizar y cerrar (sin maximizar)"
    [menu-izquierda]="Menú a la izquierda + minimizar/maximizar/cerrar"
    [solo-cerrar-izquierda]="Solo cerrar (a la izquierda)"
)

cm_list_button_presets() {
    local k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        echo "$k -> ${CM_BUTTON_PRESETS[$k]}"
    done
}

cm_button_preset_key_from_label() {
    local label="$1" k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        [ "${CM_BUTTON_PRESET_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# Busca qué preset (si alguno) corresponde a una cadena button-layout ya
# aplicada, para poder precargar la pestaña "Escritorio" con el valor real.
cm_button_preset_key_from_value() {
    local val="$1" k
    for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do
        [ "${CM_BUTTON_PRESETS[$k]}" = "$val" ] && { echo "$k"; return 0; }
    done
    return 1
}

# cm_apply_window_buttons <clave-preset|cadena-personalizada>
cm_apply_window_buttons() {
    local input="$1"
    [ -z "$input" ] && { echo "ERROR: layout de botones vacío" >&2; return 1; }
    local layout="${CM_BUTTON_PRESETS[$input]:-$input}"
    cm_gset org.cinnamon.desktop.wm.preferences button-layout "$layout" || return 1
    echo "Botones de ventana aplicados: $layout"
}

cm_current_window_buttons() {
    gsettings get org.cinnamon.desktop.wm.preferences button-layout 2>/dev/null | tr -d "'"
}

# --- esquinas activas (hot corners) -----------------------------------------
# Cuatro esquinas, en orden sup-izq, sup-der, inf-izq, inf-der. Cada valor es
# none|expo|scale|desktop. "none" desactiva la esquina (hover-enabled=false);
# el resto activa esa funcionalidad al pasar el ratón por la esquina.
CM_CORNER_ORDER=(none expo scale desktop)
declare -A CM_CORNER_LABELS=(
    [none]="Ninguna (desactivada)"
    [expo]="Vista de espacios de trabajo (Expo)"
    [scale]="Vista de ventanas (Scale)"
    [desktop]="Mostrar escritorio"
)

cm_corner_key_from_label() {
    local label="$1" k
    for k in "${CM_CORNER_ORDER[@]}"; do
        [ "${CM_CORNER_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "none"
}

# cm_apply_hotcorners <sup-izq> <sup-der> <inf-izq> <inf-der>
cm_apply_hotcorners() {
    local corner
    local -a out=()
    for corner in "$1" "$2" "$3" "$4"; do
        case "$corner" in
            expo|scale|desktop) out+=("'${corner}:true:0'") ;;
            *)                  out+=("'expo:false:0'") ;;
        esac
    done
    local joined="${out[0]}, ${out[1]}, ${out[2]}, ${out[3]}"
    cm_gset org.cinnamon hotcorner-layout "[$joined]" || return 1
    echo "Esquinas activas actualizadas"
}

# Lee el estado actual de las 4 esquinas; imprime 4 palabras separadas por
# espacio (none|expo|scale|desktop), en el mismo orden que hotcorner-layout.
cm_current_hotcorners() {
    local current entry func hover delay idx=0
    local -a codes=(none none none none)
    current=$(gsettings get org.cinnamon hotcorner-layout 2>/dev/null)
    current="${current#@as }"
    while IFS= read -r entry; do
        entry="${entry//\'/}"
        entry="$(echo "$entry" | xargs)"
        [ -z "$entry" ] && continue
        IFS=':' read -r func hover delay <<< "$entry"
        if [ "$hover" = "true" ]; then
            codes[idx]="$func"
        else
            codes[idx]="none"
        fi
        idx=$((idx+1))
        [ "$idx" -ge 4 ] && break
    done < <(echo "$current" | tr -d '[]' | tr ',' '\n')
    echo "${codes[0]} ${codes[1]} ${codes[2]} ${codes[3]}"
}

# --- efectos de escritorio, espacios de trabajo e iconos --------------------

cm_apply_desktop_effects() {
    local val="${1:-}"
    case "$val" in
        on|true|si|sí)   cm_gset org.cinnamon desktop-effects true  || return 1; echo "Efectos de ventana activados" ;;
        off|false|no)    cm_gset org.cinnamon desktop-effects false || return 1; echo "Efectos de ventana desactivados" ;;
        *) echo "ERROR: valor no válido ('$val'). Usa 'on' u 'off'." >&2; return 1 ;;
    esac
}
cm_current_desktop_effects() {
    local v; v=$(gsettings get org.cinnamon desktop-effects 2>/dev/null)
    [ "$v" = "false" ] && echo "off" || echo "on"
}

cm_apply_menu_effects() {
    local val="${1:-}"
    case "$val" in
        on|true|si|sí)   cm_gset org.cinnamon desktop-effects-on-menus true  || return 1; echo "Efectos de menús activados" ;;
        off|false|no)    cm_gset org.cinnamon desktop-effects-on-menus false || return 1; echo "Efectos de menús desactivados" ;;
        *) echo "ERROR: valor no válido ('$val'). Usa 'on' u 'off'." >&2; return 1 ;;
    esac
}
cm_current_menu_effects() {
    local v; v=$(gsettings get org.cinnamon desktop-effects-on-menus 2>/dev/null)
    [ "$v" = "false" ] && echo "off" || echo "on"
}

# Número fijo de espacios de trabajo. Nota: si en Ajustes > Espacios de
# trabajo tienes activados los "espacios de trabajo dinámicos", Cinnamon
# puede seguir creando/eliminando espacios automáticamente y este valor no
# se notará hasta desactivar esa opción; se avisa de ello en la GUI.
cm_apply_workspaces() {
    local n="${1:-}"
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt 20 ]; then
        echo "ERROR: el número de espacios de trabajo debe ser un entero entre 1 y 20." >&2
        return 1
    fi
    cm_gset org.cinnamon.desktop.wm.preferences num-workspaces "$n" || return 1
    echo "Espacios de trabajo ajustados a ${n}"
}
cm_current_workspaces() {
    gsettings get org.cinnamon.desktop.wm.preferences num-workspaces 2>/dev/null | tr -d "'" || echo "4"
}

cm_apply_desktop_icons() {
    local val="${1:-}"
    case "$val" in
        show|true|si|sí) cm_gset org.nemo.desktop show-desktop-icons true  || return 1; echo "Iconos de escritorio mostrados" ;;
        hide|false|no)   cm_gset org.nemo.desktop show-desktop-icons false || return 1; echo "Iconos de escritorio ocultos" ;;
        *) echo "ERROR: valor no válido ('$val'). Usa 'show' u 'hide'." >&2; return 1 ;;
    esac
}
cm_current_desktop_icons() {
    local v; v=$(gsettings get org.nemo.desktop show-desktop-icons 2>/dev/null)
    [ "$v" = "false" ] && echo "hide" || echo "show"
}

# Etiquetas en español para los combos Sí/No y Mostrar/Ocultar de la pestaña
# "Escritorio", reutilizables por CLI (claves on/off, show/hide) y GUI.
# --- color de fondo del escritorio (independiente de la imagen de fondo) ---
# org.cinnamon.desktop.background primary-color: color de respaldo que se ve
# tras la imagen (bordes si no la cubre del todo) o, en modo "solo color", en
# vez de ella. No se toca picture-uri: la imagen actual nunca se borra salvo
# que el usuario elija explícitamente el modo "solo color".
CM_BGMODE_ORDER=(mantener solo_color)
declare -A CM_BGMODE_LABELS=(
    [mantener]="Mantener imagen actual (color de respaldo)"
    [solo_color]="Solo color (quita la imagen de fondo)"
)
cm_bgmode_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_BGMODE_LABELS[solo_color]}" ] && { echo "solo_color"; return 0; }
    echo "mantener"
}

cm_apply_desktop_bg_color() {
    local raw="${1:-}" mode="${2:-mantener}" hex
    [ -z "$raw" ] && { echo "ERROR: indica un color en formato #RRGGBB." >&2; return 1; }
    hex=$(cm_normalize_hex "$raw")
    cm_is_valid_hex "$hex" || { echo "ERROR: '$raw' no es un color hexadecimal válido (usa #RRGGBB)." >&2; return 1; }
    [[ "$hex" =~ ^#([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])$ ]] && hex="#${BASH_REMATCH[1]}${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[3]}"

    cm_gset org.cinnamon.desktop.background primary-color "$hex" || return 1
    cm_gset org.cinnamon.desktop.background color-shading-type "solid" || return 1
    if [ "$mode" = "solo_color" ]; then
        cm_gset org.cinnamon.desktop.background picture-options "none" || return 1
    else
        # Si una aplicación anterior en modo "solo_color" había quitado la
        # imagen (picture-options=none), se restaura aquí; si no, "mantener
        # imagen actual" se quedaría solo en color pese a lo que dice su etiqueta.
        local cur_po; cur_po=$(gsettings get org.cinnamon.desktop.background picture-options 2>/dev/null | tr -d "'")
        [ "$cur_po" = "none" ] && cm_gset org.cinnamon.desktop.background picture-options "zoom" 2>/dev/null
    fi
    cm_state_set "DESKTOP_BG_COLOR" "$hex"
    if [ "$mode" = "solo_color" ]; then
        echo "Fondo de escritorio: color sólido $hex (imagen de fondo quitada)"
    else
        echo "Fondo de escritorio: color de respaldo $hex (la imagen actual se mantiene)"
    fi
}

cm_current_desktop_bg_color() {
    gsettings get org.cinnamon.desktop.background primary-color 2>/dev/null | tr -d "'" || echo "#2E3440"
}

declare -A CM_PANELPOS_LABELS=([bottom]="Abajo" [top]="Arriba")
cm_panelpos_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_PANELPOS_LABELS[top]}" ] && { echo "top"; return 0; }
    echo "bottom"
}

CM_ONOFF_ORDER=(on off)
declare -A CM_ONOFF_LABELS=([on]="Activados" [off]="Desactivados")
cm_onoff_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_ONOFF_LABELS[off]}" ] && { echo "off"; return 0; }
    echo "on"
}

CM_SHOWHIDE_ORDER=(show hide)
declare -A CM_SHOWHIDE_LABELS=([show]="Mostrar" [hide]="Ocultar")
cm_showhide_key_from_label() {
    local label="$1"
    [ "$label" = "${CM_SHOWHIDE_LABELS[hide]}" ] && { echo "hide"; return 0; }
    echo "show"
}

# ============================================================================
# apply_terminal — paletas de color para el perfil por defecto de gnome-terminal
# ============================================================================
declare -A CM_PALETTES=(
    [nord]="['#3B4252','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#88C0D0','#E5E9F0','#4C566A','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#8FBCBB','#ECEFF4']|#2E3440|#D8DEE9"
    [dracula]="['#21222C','#FF5555','#50FA7B','#F1FA8C','#BD93F9','#FF79C6','#8BE9FD','#F8F8F2','#6272A4','#FF6E6E','#69FF94','#FFFFA5','#D6ACFF','#FF92DF','#A4FFFF','#FFFFFF']|#282A36|#F8F8F2"
    [gruvbox]="['#282828','#CC241D','#98971A','#D79921','#458588','#B16286','#689D6A','#A89984','#928374','#FB4934','#B8BB26','#FABD2F','#83A598','#D3869B','#8EC07C','#EBDBB2']|#282828|#EBDBB2"
    [solarized-dark]="['#073642','#DC322F','#859900','#B58900','#268BD2','#D33682','#2AA198','#EEE8D5','#002B36','#CB4B16','#586E75','#657B83','#839496','#6C71C4','#93A1A1','#FDF6E3']|#002B36|#839496"
    [solarized-light]="['#073642','#DC322F','#859900','#B58900','#268BD2','#D33682','#2AA198','#EEE8D5','#002B36','#CB4B16','#586E75','#657B83','#839496','#6C71C4','#93A1A1','#FDF6E3']|#FDF6E3|#657B83"
    [monokai]="['#272822','#F92672','#A6E22E','#F4BF75','#66D9EF','#AE81FF','#A1EFE4','#F8F8F2','#75715E','#F92672','#A6E22E','#F4BF75','#66D9EF','#AE81FF','#A1EFE4','#F9F8F5']|#272822|#F8F8F2"
    [one-dark]="['#282C34','#E06C75','#98C379','#E5C07B','#61AFEF','#C678DD','#56B6C2','#ABB2BF','#5C6370','#E06C75','#98C379','#E5C07B','#61AFEF','#C678DD','#56B6C2','#FFFFFF']|#282C34|#ABB2BF"
    [tokyo-night]="['#15161E','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#A9B1D6','#414868','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#C0CAF5']|#1A1B26|#C0CAF5"
    [catppuccin-mocha]="['#45475A','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#BAC2DE','#585B70','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#A6ADC8']|#1E1E2E|#CDD6F4"
)

# Esquema/clave corregidos: "org.gnome.terminal.legacy.profile-manager" no
# existe. El correcto es "org.gnome.Terminal.ProfilesList" (clave "default").
cm_terminal_profile_uuid() {
    gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null | tr -d "'"
}

cm_apply_terminal_palette() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "ERROR: indica el nombre de una paleta (usa 'terminal list' para ver las disponibles)." >&2
        return 1
    fi
    local data="${CM_PALETTES[$name]:-}"
    [ -z "$data" ] && { echo "Paleta desconocida: $name" >&2; return 1; }

    local palette bg fg uuid path
    palette="${data%%|*}"
    bg=$(echo "$data" | cut -d'|' -f2)
    fg=$(echo "$data" | cut -d'|' -f3)

    uuid=$(cm_terminal_profile_uuid)
    if [ -z "$uuid" ]; then
        echo "No se encontró un perfil por defecto de gnome-terminal. Abre el Terminal una vez y vuelve a intentarlo." >&2
        return 1
    fi
    path="/org/gnome/terminal/legacy/profiles:/:${uuid}/"

    cm_dwrite "${path}palette"           "$palette"  || return 1
    cm_dwrite "${path}background-color"  "'${bg}'"   || return 1
    cm_dwrite "${path}foreground-color"  "'${fg}'"   || return 1
    cm_dwrite "${path}use-theme-colors"  "false"      || return 1

    cm_state_set "TERMINAL_PALETTE" "$name"
    echo "Paleta '$name' aplicada al perfil de terminal por defecto."
}

cm_list_terminal_palettes() {
    local k
    for k in "${!CM_PALETTES[@]}"; do echo "$k"; done | sort
}

CM_PALETTE_ORDER=(nord dracula gruvbox solarized-dark solarized-light monokai one-dark tokyo-night catppuccin-mocha)
declare -A CM_PALETTE_LABELS=(
    [nord]="Nord"
    [dracula]="Dracula"
    [gruvbox]="Gruvbox"
    [solarized-dark]="Solarized (oscuro)"
    [solarized-light]="Solarized (claro)"
    [monokai]="Monokai"
    [one-dark]="One Dark"
    [tokyo-night]="Tokyo Night"
    [catppuccin-mocha]="Catppuccin Mocha"
)
cm_palette_key_from_label() {
    local label="$1" k
    for k in "${CM_PALETTE_ORDER[@]}"; do
        [ "${CM_PALETTE_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    return 1
}

# Amplía la personalización de terminal más allá de las paletas fijas:
# fondo/texto elegidos libremente con el selector de color. Se aplican SOLO
# si se indican (vacío = no tocar), y siempre sobre el mismo perfil por
# defecto que cm_apply_terminal_palette.
cm_apply_terminal_custom_colors() {
    local bg_raw="${1:-}" fg_raw="${2:-}" uuid path bg fg
    uuid=$(cm_terminal_profile_uuid)
    if [ -z "$uuid" ]; then
        echo "No se encontró un perfil por defecto de gnome-terminal. Abre el Terminal una vez y vuelve a intentarlo." >&2
        return 1
    fi
    path="/org/gnome/terminal/legacy/profiles:/:${uuid}/"

    if [ -n "$bg_raw" ]; then
        bg=$(cm_normalize_hex "$bg_raw")
        cm_is_valid_hex "$bg" || { echo "ERROR: '$bg_raw' no es un color de fondo válido (usa #RRGGBB)." >&2; return 1; }
        cm_dwrite "${path}background-color" "'${bg}'" || return 1
    fi
    if [ -n "$fg_raw" ]; then
        fg=$(cm_normalize_hex "$fg_raw")
        cm_is_valid_hex "$fg" || { echo "ERROR: '$fg_raw' no es un color de texto válido (usa #RRGGBB)." >&2; return 1; }
        cm_dwrite "${path}foreground-color" "'${fg}'" || return 1
    fi
    if [ -z "$bg_raw" ] && [ -z "$fg_raw" ]; then
        echo "ERROR: indica al menos un color (fondo o texto)." >&2
        return 1
    fi
    cm_dwrite "${path}use-theme-colors" "false" || return 1
    echo "Colores personalizados de terminal aplicados${bg:+ — fondo: $bg}${fg:+ — texto: $fg}"
}

# ============================================================================
# apply_fonts — tipografía, antialiasing y hinting
#
# Nota: las claves gsettings de antialiasing/hinting varían según la versión
# de Cinnamon/settings-daemon, por eso este módulo aplica el ajuste de forma
# robusta vía ~/.config/fontconfig/fonts.conf (siempre soportado por
# fontconfig) e, de forma adicional y silenciosa, intenta también gsettings.
# ============================================================================
CM_ANTIALIAS_ORDER=(rgba grayscale none)
declare -A CM_ANTIALIAS_LABELS=(
    [rgba]="Subpíxel (recomendado en pantallas LCD)"
    [grayscale]="Escala de grises (compatible con cualquier pantalla)"
    [none]="Desactivado"
)
cm_antialias_key_from_label() {
    local label="$1" k
    for k in "${CM_ANTIALIAS_ORDER[@]}"; do
        [ "${CM_ANTIALIAS_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "rgba"
}

CM_HINTING_ORDER=(slight medium full none)
declare -A CM_HINTING_LABELS=(
    [slight]="Ligero (recomendado)"
    [medium]="Medio"
    [full]="Completo (más nítido, puede deformar letras)"
    [none]="Ninguno"
)
cm_hinting_key_from_label() {
    local label="$1" k
    for k in "${CM_HINTING_ORDER[@]}"; do
        [ "${CM_HINTING_LABELS[$k]}" = "$label" ] && { echo "$k"; return 0; }
    done
    echo "slight"
}

cm_apply_font_name() {
    local font="${1:-}"
    [ -z "$font" ] && { echo "ERROR: indica el nombre de una fuente (p.ej. 'Noto Sans 10')." >&2; return 1; }
    cm_gset org.cinnamon.desktop.interface font-name "$font" || return 1
    gsettings set org.cinnamon.desktop.wm.preferences titlebar-font "$font" 2>/dev/null || true
    echo "Fuente de interfaz aplicada: $font"
}

cm_apply_monospace_font() {
    local font="${1:-}"
    [ -z "$font" ] && { echo "ERROR: indica el nombre de una fuente monoespaciada." >&2; return 1; }
    cm_gset org.gnome.desktop.interface monospace-font-name "$font" || return 1
    echo "Fuente monoespaciada aplicada: $font"
}

# Lee ~/.config/fontconfig/fonts.conf (si existe) para reconstruir qué
# opciones de antialiasing/hinting están aplicadas actualmente, y así poder
# precargar la pestaña "Fuentes" en vez de partir siempre de valores fijos.
# Imprime "<antialias> <hinting>" (p.ej. "rgba slight").
cm_current_font_rendering() {
    local conf="$HOME/.config/fontconfig/fonts.conf"
    local antialias="rgba" hinting="slight"
    if [ -f "$conf" ]; then
        local aa rgba hs
        aa=$(sed -n 's/.*<edit name="antialias"[^>]*><bool>\([a-z]*\)<\/bool>.*/\1/p' "$conf" | head -n1)
        rgba=$(sed -n 's/.*<edit name="rgba"[^>]*><const>\([a-z]*\)<\/const>.*/\1/p' "$conf" | head -n1)
        hs=$(sed -n 's/.*<edit name="hintstyle"[^>]*><const>hint\([a-z]*\)<\/const>.*/\1/p' "$conf" | head -n1)
        if [ "$aa" = "false" ]; then
            antialias="none"
        elif [ "$rgba" = "rgb" ]; then
            antialias="rgba"
        else
            antialias="grayscale"
        fi
        [ -n "$hs" ] && hinting="$hs"
    fi
    echo "$antialias $hinting"
}

# cm_apply_font_rendering <antialias: rgba|grayscale|none> <hinting: none|slight|medium|full>
#
# Corrección: antes siempre se escribía <antialias>true</antialias> (nunca se
# podía desactivar) y se usaba literalmente "rgba" como valor de <rgba>, que
# no es válido en fontconfig (valores válidos: none/rgb/bgr/vrgb/vbgr). Ahora
# se traduce correctamente la opción elegida en la interfaz:
#   rgba      -> antialiasing ON,  subpíxel "rgb"
#   grayscale -> antialiasing ON,  subpíxel "none" (solo escala de grises)
#   none      -> antialiasing OFF
cm_apply_font_rendering() {
    local antialias="${1:-}" hinting="${2:-}"
    if [ -z "$antialias" ] || [ -z "$hinting" ]; then
        echo "ERROR: indica antialiasing <rgba|grayscale|none> e hinting <slight|medium|full|none>." >&2
        return 1
    fi
    local antialias_bool="true" rgba_value="none"

    case "$antialias" in
        none)      antialias_bool="false"; rgba_value="none" ;;
        grayscale) antialias_bool="true";  rgba_value="none" ;;
        rgba|rgb)  antialias_bool="true";  rgba_value="rgb"  ;;
        *)         antialias_bool="true";  rgba_value="none" ;;
    esac

    mkdir -p "$HOME/.config/fontconfig"
    if ! cat > "$HOME/.config/fontconfig/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>${antialias_bool}</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hint${hinting}</const></edit>
    <edit name="rgba" mode="assign"><const>${rgba_value}</const></edit>
  </match>
</fontconfig>
EOF
    then
        echo "ERROR: no se pudo escribir $HOME/.config/fontconfig/fonts.conf" >&2
        return 1
    fi
    gsettings set org.cinnamon.settings-daemon.plugins.xsettings hinting "$hinting"       2>/dev/null || true
    gsettings set org.cinnamon.settings-daemon.plugins.xsettings antialiasing "$antialias" 2>/dev/null || true
    echo "Renderizado de fuentes aplicado: antialiasing=${antialias}, hinting=${hinting} (algunas apps ya abiertas pueden necesitar reabrirse para verlo)"
}

# Escala global de texto (org.cinnamon.desktop.interface text-scaling-factor;
# es un factor decimal, 1.0 = 100%). Se expresa aquí como porcentaje entero
# (50-200) para que sea cómodo de mover en la GUI y de escribir desde la CLI.
#
cm_apply_text_scaling() {
    local pct="${1:-}"
    if ! [[ "$pct" =~ ^[0-9]+$ ]] || [ "$pct" -lt 50 ] || [ "$pct" -gt 200 ]; then
        echo "ERROR: la escala de texto debe ser un número entero entre 50 y 200 (%)." >&2
        return 1
    fi
    local factor
    factor=$(LC_ALL=C awk -v p="$pct" 'BEGIN{printf "%.2f", p/100}')
    cm_gset org.cinnamon.desktop.interface text-scaling-factor "$factor" || return 1
    echo "Escala de texto ajustada a ${pct}% (factor ${factor})"
}

# Lee el factor actual y lo devuelve como porcentaje entero (para precargar
# el formulario). Si el valor no es numérico o falta, asume 100%.
cm_current_text_scaling() {
    local factor pct
    factor=$(gsettings get org.cinnamon.desktop.interface text-scaling-factor 2>/dev/null)
    pct=$(LC_ALL=C awk -v f="$factor" 'BEGIN{ if (f+0 > 0) printf "%d", (f*100)+0.5; else print 100 }' 2>/dev/null)
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=100
    echo "$pct"
}

# ============================================================================
# presets — guardar, listar y cargar perfiles estéticos completos
#
# Un preset es un archivo de texto plano (clave=valor) en $CM_PRESETS_DIR.
# Se puede editar a mano o generar/cargar desde la pestaña "Perfiles".
# ============================================================================
cm_save_preset() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica un nombre para el preset." >&2; return 1; }
    case "$name" in */*|*..*) echo "ERROR: el nombre del preset no puede contener '/' ni '..'." >&2; return 1 ;; esac
    mkdir -p "$CM_PRESETS_DIR"
    local file="$CM_PRESETS_DIR/${name}.conf"

    local gtk_theme icon_theme cursor_theme cinn_theme font_name mono_font
    gtk_theme=$(gsettings get org.cinnamon.desktop.interface gtk-theme    2>/dev/null | tr -d "'")
    icon_theme=$(gsettings get org.cinnamon.desktop.interface icon-theme  2>/dev/null | tr -d "'")
    cursor_theme=$(gsettings get org.cinnamon.desktop.interface cursor-theme 2>/dev/null | tr -d "'")
    cinn_theme=$(gsettings get org.cinnamon.theme name             2>/dev/null | tr -d "'")
    font_name=$(gsettings get org.cinnamon.desktop.interface font-name    2>/dev/null | tr -d "'")
    mono_font=$(gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null | tr -d "'")

    local panel_position window_buttons hotcorners hc_tl hc_tr hc_bl hc_br
    panel_position=$(cm_current_panel_position)
    window_buttons=$(cm_current_window_buttons)
    hotcorners=$(cm_current_hotcorners)
    read -r hc_tl hc_tr hc_bl hc_br <<< "$hotcorners"

    local cursor_size panel_height text_scaling antialias hinting
    cursor_size=$(cm_current_cursor_size)
    panel_height=$(cm_current_panel_height)
    text_scaling=$(cm_current_text_scaling)
    read -r antialias hinting <<< "$(cm_current_font_rendering)"

    # Ajustes de escritorio que sí se pueden releer en vivo desde gsettings
    local workspaces effects menu_fx icons desktop_bg
    workspaces=$(cm_current_workspaces)
    effects=$(cm_current_desktop_effects)
    menu_fx=$(cm_current_menu_effects)
    icons=$(cm_current_desktop_icons)
    desktop_bg=$(cm_current_desktop_bg_color)

    cat > "$file" <<EOF
# Preset generado por Color Mint - $(date '+%Y-%m-%d %H:%M:%S')
# Puedes editar estos valores a mano y volver a cargarlo desde la pestaña "Perfiles"
GTK_THEME="$gtk_theme"
ICON_THEME="$icon_theme"
CURSOR_THEME="$cursor_theme"
CURSOR_SIZE="$cursor_size"
CINNAMON_THEME="$cinn_theme"
FONT_NAME="$font_name"
MONOSPACE_FONT="$mono_font"
FONT_ANTIALIAS="$antialias"
FONT_HINTING="$hinting"
TEXT_SCALING="$text_scaling"
ACCENT_COLOR="$(cm_state_get "ACCENT_COLOR" "#88C0D0")"
PANEL_BG_COLOR="$(cm_state_get "PANEL_BG_COLOR" "")"
PANEL_FG_COLOR="$(cm_state_get "PANEL_FG_COLOR" "")"
MENU_BG_COLOR="$(cm_state_get "MENU_BG_COLOR" "")"
MENU_FG_COLOR="$(cm_state_get "MENU_FG_COLOR" "")"
TOOLTIP_BG_COLOR="$(cm_state_get "TOOLTIP_BG_COLOR" "")"
TOOLTIP_FG_COLOR="$(cm_state_get "TOOLTIP_FG_COLOR" "")"
GTK_ACCENT_COLOR="$(cm_state_get "GTK_ACCENT_COLOR" "")"
PANEL_OPACITY="$(cm_state_get "PANEL_OPACITY" "90")"
PANEL_HEIGHT="$panel_height"
TERMINAL_PALETTE="$(cm_state_get "TERMINAL_PALETTE" "nord")"
PANEL_POSITION="$panel_position"
WINDOW_BUTTONS="$window_buttons"
HOTCORNER_TL="$hc_tl"
HOTCORNER_TR="$hc_tr"
HOTCORNER_BL="$hc_bl"
HOTCORNER_BR="$hc_br"
WORKSPACES="$workspaces"
DESKTOP_EFFECTS="$effects"
MENU_EFFECTS="$menu_fx"
DESKTOP_ICONS="$icons"
DESKTOP_BG_COLOR="$desktop_bg"
EOF
    cm_log "INFO" "Preset guardado: $file"
    echo "$file"
}

cm_list_presets() {
    mkdir -p "$CM_PRESETS_DIR"
    local f base
    for f in "$CM_PRESETS_DIR"/*.conf; do
        [ -e "$f" ] || continue
        base=$(basename "$f" .conf)
        echo "$base"
    done
}

cm_load_preset() {
    local name="${1:-}"
    [ -z "$name" ] && { echo "ERROR: indica el nombre de un preset (usa 'preset list' para verlos)." >&2; return 1; }
    case "$name" in */*|*..*) echo "ERROR: el nombre del preset no puede contener '/' ni '..'." >&2; return 1 ;; esac
    local file="$CM_PRESETS_DIR/${name}.conf"
    [ -f "$file" ] || { echo "Preset no encontrado: $name" >&2; return 1; }

    local GTK_THEME="" ICON_THEME="" CURSOR_THEME="" CURSOR_SIZE="" CINNAMON_THEME="" FONT_NAME="" \
          MONOSPACE_FONT="" FONT_ANTIALIAS="" FONT_HINTING="" TEXT_SCALING="" \
          ACCENT_COLOR="" PANEL_BG_COLOR="" PANEL_FG_COLOR="" MENU_BG_COLOR="" MENU_FG_COLOR="" \
          TOOLTIP_BG_COLOR="" TOOLTIP_FG_COLOR="" GTK_ACCENT_COLOR="" \
          PANEL_OPACITY="" PANEL_HEIGHT="" TERMINAL_PALETTE="" \
          PANEL_POSITION="" WINDOW_BUTTONS="" \
          HOTCORNER_TL="" HOTCORNER_TR="" HOTCORNER_BL="" HOTCORNER_BR="" \
          WORKSPACES="" DESKTOP_EFFECTS="" MENU_EFFECTS="" DESKTOP_ICONS="" DESKTOP_BG_COLOR=""
    # shellcheck disable=SC1090
    source "$file"

    [ -n "$GTK_THEME" ]        && cm_apply_gtk_theme "$GTK_THEME"
    [ -n "$ICON_THEME" ]       && cm_apply_icon_theme "$ICON_THEME"
    [ -n "$CURSOR_THEME" ]     && cm_apply_cursor_theme "$CURSOR_THEME" 1
    [ -n "$CURSOR_SIZE" ]      && cm_apply_cursor_size "$CURSOR_SIZE" 1
    [ -n "$CINNAMON_THEME" ]   && cm_apply_cinnamon_theme "$CINNAMON_THEME"
    [ -n "$FONT_NAME" ]        && cm_apply_font_name "$FONT_NAME"
    [ -n "$MONOSPACE_FONT" ]   && cm_apply_monospace_font "$MONOSPACE_FONT"
    [ -n "$FONT_ANTIALIAS" ] && [ -n "$FONT_HINTING" ] && cm_apply_font_rendering "$FONT_ANTIALIAS" "$FONT_HINTING"
    [ -n "$TEXT_SCALING" ]     && cm_apply_text_scaling "$TEXT_SCALING"
    [ -n "$ACCENT_COLOR" ]     && cm_apply_accent_color "$ACCENT_COLOR"
    [ -n "$PANEL_BG_COLOR" ]   && cm_apply_panel_bg_color "$PANEL_BG_COLOR"
    [ -n "$PANEL_FG_COLOR" ]   && cm_apply_panel_fg_color "$PANEL_FG_COLOR"
    [ -n "$MENU_BG_COLOR" ]    && cm_apply_menu_bg_color "$MENU_BG_COLOR"
    [ -n "$MENU_FG_COLOR" ]    && cm_apply_menu_fg_color "$MENU_FG_COLOR"
    [ -n "$TOOLTIP_BG_COLOR" ] && cm_apply_tooltip_bg_color "$TOOLTIP_BG_COLOR"
    [ -n "$TOOLTIP_FG_COLOR" ] && cm_apply_tooltip_fg_color "$TOOLTIP_FG_COLOR"
    [ -n "$GTK_ACCENT_COLOR" ] && cm_apply_gtk_accent_color "$GTK_ACCENT_COLOR"
    [ -n "$PANEL_OPACITY" ]    && cm_apply_panel_opacity "$PANEL_OPACITY"
    [ -n "$PANEL_HEIGHT" ]     && cm_apply_panel_height "$PANEL_HEIGHT"
    [ -n "$TERMINAL_PALETTE" ] && cm_apply_terminal_palette "$TERMINAL_PALETTE"
    [ -n "$PANEL_POSITION" ]   && cm_apply_panel_position "$PANEL_POSITION"
    [ -n "$WINDOW_BUTTONS" ]   && cm_apply_window_buttons "$WINDOW_BUTTONS"
    if [ -n "$HOTCORNER_TL" ] || [ -n "$HOTCORNER_TR" ] || [ -n "$HOTCORNER_BL" ] || [ -n "$HOTCORNER_BR" ]; then
        cm_apply_hotcorners "${HOTCORNER_TL:-none}" "${HOTCORNER_TR:-none}" "${HOTCORNER_BL:-none}" "${HOTCORNER_BR:-none}"
    fi
    [ -n "$WORKSPACES" ]       && cm_apply_workspaces "$WORKSPACES"
    [ -n "$DESKTOP_EFFECTS" ]  && cm_apply_desktop_effects "$DESKTOP_EFFECTS"
    [ -n "$MENU_EFFECTS" ]     && cm_apply_menu_effects "$MENU_EFFECTS"
    [ -n "$DESKTOP_ICONS" ]    && cm_apply_desktop_icons "$DESKTOP_ICONS"
    # Modo "mantener": nunca borra la imagen de fondo actual del usuario al cargar un preset
    [ -n "$DESKTOP_BG_COLOR" ] && cm_apply_desktop_bg_color "$DESKTOP_BG_COLOR" "mantener"

    cm_reload_cinnamon
    cm_log "INFO" "Preset cargado: $name"
}

# Crea los presets de ejemplo la primera vez que se ejecuta el script
cm_bootstrap_presets() {
    mkdir -p "$CM_PRESETS_DIR"

    if [ ! -f "$CM_PRESETS_DIR/default.conf" ]; then
        cat > "$CM_PRESETS_DIR/default.conf" <<'EOF'
# Preset "default" - aproximación al estilo de fábrica de Linux Mint 22.3 Cinnamon
# Puedes editar estos valores a mano y cargar el preset desde la pestaña "Perfiles"
GTK_THEME="Mint-Y"
ICON_THEME="Mint-Y"
CURSOR_THEME="Mint-Y"
CURSOR_SIZE="24"
CINNAMON_THEME="Mint-Y"
FONT_NAME="Noto Sans 10"
TEXT_SCALING="100"
ACCENT_COLOR="#56B6C2"
PANEL_OPACITY="100"
PANEL_HEIGHT="40"
TERMINAL_PALETTE="nord"
PANEL_POSITION="bottom"
WINDOW_BUTTONS="derecha"
HOTCORNER_TL="none"
HOTCORNER_TR="none"
HOTCORNER_BL="none"
HOTCORNER_BR="none"
EOF
    fi

    if [ ! -f "$CM_PRESETS_DIR/nord-dark.conf" ]; then
        cat > "$CM_PRESETS_DIR/nord-dark.conf" <<'EOF'
# Preset "nord-dark" - estética fría y minimalista inspirada en la paleta Nord
GTK_THEME="Mint-Y-Dark"
ICON_THEME="Mint-Y-Dark"
CURSOR_THEME="Mint-Y"
CURSOR_SIZE="24"
CINNAMON_THEME="Mint-Y-Dark"
FONT_NAME="Noto Sans 10"
TEXT_SCALING="100"
ACCENT_COLOR="#88C0D0"
PANEL_OPACITY="88"
PANEL_HEIGHT="36"
TERMINAL_PALETTE="nord"
PANEL_POSITION="bottom"
WINDOW_BUTTONS="izquierda"
HOTCORNER_TL="none"
HOTCORNER_TR="expo"
HOTCORNER_BL="none"
HOTCORNER_BR="desktop"
EOF
    fi
}

# ============================================================================
# GUI — hoja de estilo (GTK3 CSS para YAD)
# ============================================================================
cm_write_css() {
    mkdir -p "$CM_HOME"
    cat > "$CM_CSS_FILE" <<'CSS'
/* Estilo elegante para Color Mint (GTK3 CSS, YAD)
   Paleta inspirada en Nord: fondo oscuro, acentos fríos, bordes redondeados. */

window {
    background-color: #2b2e3b;
    color: #e5e9f0;
}

notebook > header {
    background-color: #232530;
    border: none;
    padding: 2px;
}

notebook > header > tabs > tab {
    padding: 8px 18px;
    color: #a3a9bd;
    font-weight: 600;
    transition: color 150ms ease, background-color 150ms ease;
}

notebook > header > tabs > tab:hover {
    color: #e5e9f0;
    background-color: #2b2e3b;
}

notebook > header > tabs > tab:checked {
    color: #ffffff;
    border-bottom: 3px solid #88c0d0;
    background-color: #2b2e3b;
}

notebook > stack {
    background-color: #2b2e3b;
    padding: 18px 20px;
}

button {
    background-image: none;
    background-color: #3b4252;
    color: #eceff4;
    border-radius: 8px;
    border: 1px solid #4c566a;
    padding: 6px 14px;
    transition: background-color 150ms ease, border-color 150ms ease, box-shadow 150ms ease;
}

button:hover {
    background-color: #4c566a;
    border-color: #88c0d0;
}

button:focus {
    border-color: #88c0d0;
    box-shadow: 0 0 0 1px #88c0d0;
}

button:active {
    background-color: #88c0d0;
    color: #1e222c;
}

entry, combobox, spinbutton, colorbutton, fontbutton {
    background-color: #3b4252;
    color: #eceff4;
    border-radius: 6px;
    border: 1px solid #4c566a;
    padding: 5px 9px;
    margin: 3px 0;
    transition: border-color 150ms ease, box-shadow 150ms ease;
}

entry:hover, combobox:hover, spinbutton:hover, colorbutton:hover, fontbutton:hover {
    border-color: #6c7695;
}

entry:focus, spinbutton:focus, combobox:focus, colorbutton:focus, fontbutton:focus {
    border-color: #88c0d0;
    box-shadow: 0 0 0 1px #88c0d0;
}

label {
    color: #e5e9f0;
}

frame {
    border: 1px solid #4c566a;
    border-radius: 8px;
    margin: 6px 0;
    padding: 6px;
}

frame > label {
    color: #88c0d0;
    font-weight: bold;
}

separator {
    background-color: #3b4252;
    min-width: 1px;
    min-height: 1px;
}

scale trough {
    background-color: #3b4252;
    border-radius: 6px;
    min-height: 6px;
}

scale trough highlight {
    background-color: #88c0d0;
    border-radius: 6px;
}

scale slider {
    background-color: #eceff4;
    border-radius: 50%;
    border: 2px solid #88c0d0;
    transition: background-color 150ms ease;
}

scale slider:hover {
    background-color: #88c0d0;
}

checkbutton check, radiobutton radio {
    background-color: #3b4252;
    border: 1px solid #4c566a;
    transition: border-color 150ms ease, background-color 150ms ease;
}

checkbutton check:hover, radiobutton radio:hover {
    border-color: #88c0d0;
}

checkbutton check:checked, radiobutton radio:checked {
    background-color: #88c0d0;
    border-color: #88c0d0;
}

tooltip {
    background-color: #232530;
    color: #eceff4;
    border-radius: 6px;
    padding: 6px 10px;
}

/* Desplegables de los campos :CB y menús contextuales de los campos de
   texto: sin esta regla se renderizan con el tema claro por defecto del
   sistema, un choque visual fuerte contra el resto de la interfaz, oscura.
   Se cubren "menu" (modo clásico) y "popover" (usado en GTK 3.22+ por
   algunos temas) para variar lo menos posible según versión instalada. */
menu, popover, window.popup {
    background-color: #2b2e3b;
    border: 1px solid #4c566a;
    border-radius: 8px;
    padding: 4px;
}

menuitem {
    color: #e5e9f0;
    border-radius: 6px;
    padding: 6px 10px;
}

menuitem:hover {
    background-color: #4c566a;
    color: #ffffff;
}

/* Mismo caso cuando el desplegable se dibuja como lista (GtkTreeView) en
   vez de menú/popover, según versión de GTK. */
treeview {
    background-color: #2b2e3b;
    color: #e5e9f0;
}

treeview:selected, treeview row:selected {
    background-color: #4c566a;
    color: #ffffff;
}

scrollbar {
    background-color: transparent;
}

scrollbar slider {
    background-color: #4c566a;
    border-radius: 6px;
    min-width: 8px;
    min-height: 8px;
    transition: background-color 150ms ease;
}

scrollbar slider:hover {
    background-color: #88c0d0;
}

scrollbar trough {
    background-color: transparent;
}
CSS
}

# ============================================================================
# GUI — pestañas (cada una es un bucle que se reencola tras "Aplicar")
#
# YAD no soporta leer valores de varias pestañas embebidas de forma nativa,
# así que cada pestaña corre en su propio proceso (--plug), lanzado como una
# invocación de este mismo script en modo "__tab" (ver dispatcher al final).
# ============================================================================
_join_bang() { local IFS='!'; echo "$*"; }

# Igual que "cm_reorder_current_first | _join_bang" pero seguro para
# elementos con espacios (p.ej. etiquetas como "Ninguna (desactivada)"):
# captura cada línea de cm_reorder_current_first como un elemento de array
# en vez de dejar que la sustitución de comandos sin comillas trocee por
# espacios, que es lo que rompería esas etiquetas.
_reorder_join_bang() {
    local current="$1"; shift
    local -a ordered=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && ordered+=("$line")
    done < <(cm_reorder_current_first "$current" "$@")
    _join_bang "${ordered[@]}"
}

# Igual que "_join_bang $(comando)" pero seguro para elementos con espacios
# (p.ej. un nombre de preset guardado como "mi tema oscuro"): convierte la
# salida multilínea de $1 en un array real (una entrada por línea) antes de
# unir con "!", en vez de dejar que la sustitución de comandos sin comillas
# trocee también por espacios.
_lines_to_bang() {
    local input="$1"
    local -a arr=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && arr+=("$line")
    done <<< "$input"
    _join_bang "${arr[@]}"
}

# cm_fbtn_apply <modo> [índice-de-campo ...] — valor para un campo ":FBTN"
# que aplica los cambios DIRECTAMENTE al pulsarse, sin depender de que el
# --plug se cierre ni de capturar su salida (ver nota técnica al principio
# del archivo). Construye:
#   bash -c 'bash "$0" __apply <modo> "$1" "$2" ...' "$SCRIPT_PATH" %N %N ...
# YAD sustituye cada "%N" por el valor actual del campo N ya citado como un
# solo argumento (preserva espacios); "$0" dentro del "bash -c" es
# "$SCRIPT_PATH" y "$1","$2"... son esos valores, en el mismo orden en que
# se piden aquí. Los índices no necesitan ser consecutivos ni cubrir todos
# los campos del formulario: solo se piden los que ese botón necesita.
cm_fbtn_apply() {
    local modo="$1"; shift
    local i inner="bash \"\$0\" __apply $modo" ph="" argi=0
    for i in "$@"; do
        argi=$((argi + 1))
        inner+=" \"\$$argi\""
        ph+=" %$i"
    done
    printf "bash -c '%s' \"%s\"%s" "$inner" "$SCRIPT_PATH" "$ph"
}

# ============================================================================
# GUI — acciones de aplicación (invocadas directamente por los botones FBTN
# de cada pestaña vía cm_fbtn_apply/__apply; ver dispatcher al final)
# ============================================================================
CM_MINTY_NONE_LABEL="Ninguno (uso el camino manual de abajo)"

cm_ui_apply_temas_aplicar() {
    local GTK_T="$1" ICON_T="$2" CURSOR_T="$3" CURSOR_SZ_RAW="$4" CINN_T="$5" MINTY_COLOR_LABEL="$6" MINTY_MODE_LABEL="$7"
    local CURSOR_SZ; CURSOR_SZ=$(cm_num_int "$CURSOR_SZ_RAW")

    cm_backup_current >/dev/null
    local -a applied=()

    if [ -n "$MINTY_COLOR_LABEL" ] && [ "$MINTY_COLOR_LABEL" != "$CM_MINTY_NONE_LABEL" ]; then
        local minty_mode="claro"
        [ "$MINTY_MODE_LABEL" = "Oscuro" ] && minty_mode="oscuro"
        cm_report "Color oficial Mint-Y: $MINTY_COLOR_LABEL ($MINTY_MODE_LABEL)" cm_apply_mint_y_pack "$MINTY_COLOR_LABEL" "$minty_mode"
    else
        [ -n "$GTK_T" ]  && cm_report "Tema GTK: $GTK_T"           cm_apply_gtk_theme "$GTK_T"
        [ -n "$ICON_T" ] && cm_report "Tema de iconos: $ICON_T"    cm_apply_icon_theme "$ICON_T"
        [ -n "$CINN_T" ] && cm_report "Tema de Cinnamon: $CINN_T"  cm_apply_cinnamon_theme "$CINN_T"
    fi

    [ -n "$CURSOR_T" ]  && cm_report "Tema de cursor: $CURSOR_T" cm_apply_cursor_theme "$CURSOR_T" 1
    [ -n "$CURSOR_SZ" ] && cm_report "Tamaño de cursor: ${CURSOR_SZ}px (si no se ve al momento, puede necesitar cerrar sesión — ver nota)" cm_apply_cursor_size "$CURSOR_SZ" 1

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "Temas aplicados" "${applied[@]}"
}

cm_ui_apply_temas_importar() {
    local IMPORT_FILE="$1" IMPORT_DIR="$2"
    local origen="$IMPORT_FILE"
    [ -z "$origen" ] && origen="$IMPORT_DIR"
    if [ -z "$origen" ]; then
        yad --error --text="Elige un archivo de tema o una carpeta ya descomprimida para importar." --button="Entendido:0" 2>/dev/null
        return
    fi
    local dest
    if dest=$(cm_import_theme "$origen"); then
        # Se recuerda en el archivo de estado (no en una variable local, ya
        # que este modo "__apply" corre en un proceso aparte del bucle de la
        # pestaña) para que la próxima redibujada preseleccione este tema.
        cm_state_set "LAST_IMPORTED_THEME" "$(basename "$dest")"
        cm_notify_applied "Color Mint" "Tema importado" "Ruta: $dest" "Ya aparece preseleccionado en su desplegable — pulsa «Aplicar temas» para usarlo"
    else
        yad --error --text="No se pudo importar el tema.\nRevisa que el archivo tenga un formato soportado (.zip, .tar.gz, .tar.xz, .tar.bz2) y una estructura de tema válida (gtk-3.0/, cinnamon/, cursors/ o index.theme)." --button="Entendido:0" 2>/dev/null
    fi
}

cm_tab_temas() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local cur_gtk cur_icon cur_cursor cur_cinn cur_cursor_size LAST_IMPORTED
        cur_gtk=$(gsettings get org.cinnamon.desktop.interface gtk-theme 2>/dev/null | tr -d "'")
        cur_icon=$(gsettings get org.cinnamon.desktop.interface icon-theme 2>/dev/null | tr -d "'")
        cur_cursor=$(gsettings get org.cinnamon.desktop.interface cursor-theme 2>/dev/null | tr -d "'")
        cur_cinn=$(gsettings get org.cinnamon.theme name 2>/dev/null | tr -d "'")
        cur_cursor_size=$(cm_current_cursor_size)
        LAST_IMPORTED=$(cm_state_get "LAST_IMPORTED_THEME" "")

        # Si el último tema importado aparece en la lista correspondiente
        # (según en qué carpeta se instaló: gtk/cinnamon, o iconos/cursor),
        # se antepone también ahí, aunque todavía no esté aplicado al
        # sistema: así queda "listo para usar" con solo pulsar "Aplicar".
        local gtk_themes icon_themes cursor_themes cinn_themes
        gtk_themes=$(cm_list_gtk_themes)
        icon_themes=$(cm_list_icon_themes)
        cursor_themes=$(cm_list_cursor_themes)
        cinn_themes=$(cm_list_cinnamon_themes)
        if [ -n "$LAST_IMPORTED" ]; then
            grep -qxF "$LAST_IMPORTED" <<< "$gtk_themes"    && cur_gtk="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$icon_themes"   && cur_icon="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$cursor_themes" && cur_cursor="$LAST_IMPORTED"
            grep -qxF "$LAST_IMPORTED" <<< "$cinn_themes"   && cur_cinn="$LAST_IMPORTED"
        fi

        local -a gtk_arr=() icon_arr=() cursor_arr=() cinn_arr=()
        local _line
        while IFS= read -r _line; do [ -n "$_line" ] && gtk_arr+=("$_line"); done <<< "$gtk_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && icon_arr+=("$_line"); done <<< "$icon_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && cursor_arr+=("$_line"); done <<< "$cursor_themes"
        while IFS= read -r _line; do [ -n "$_line" ] && cinn_arr+=("$_line"); done <<< "$cinn_themes"

        local GTK_LIST ICON_LIST CURSOR_LIST CINN_LIST
        GTK_LIST=$(_reorder_join_bang "$cur_gtk" "${gtk_arr[@]}")
        ICON_LIST=$(_reorder_join_bang "$cur_icon" "${icon_arr[@]}")
        CURSOR_LIST=$(_reorder_join_bang "$cur_cursor" "${cursor_arr[@]}")
        CINN_LIST=$(_reorder_join_bang "$cur_cinn" "${cinn_arr[@]}")

        local mint_y_light mint_y_dark mint_y_colors_all
        mint_y_light=$(cm_list_mint_y_colors "Mint-Y")
        mint_y_dark=$(cm_list_mint_y_colors "Mint-Y-Dark")
        mint_y_colors_all=$(printf '%s\n%s\n' "$mint_y_light" "$mint_y_dark" | grep -v '^$' | sort -u)
        local -a mint_y_arr=()
        local _line2
        while IFS= read -r _line2; do [ -n "$_line2" ] && mint_y_arr+=("$_line2"); done <<< "$mint_y_colors_all"
        local MINTY_COLOR_LIST MINTY_MODE_LIST
        MINTY_COLOR_LIST=$(_join_bang "$CM_MINTY_NONE_LABEL" "${mint_y_arr[@]}")
        MINTY_MODE_LIST=$(_join_bang "Claro" "Oscuro")

        # Orden pensado para un usuario medio: el camino fácil (paquete
        # oficial Mint-Y) va primero y con etiqueta "recomendado"; el camino
        # manual (pieza por pieza) queda claramente marcado como opcional.
        # Los índices de campo de los botones de abajo NO siguen el orden en
        # pantalla, sino el orden que espera cada función cm_ui_apply_*.
        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>🎨  Temas</b>\nDos caminos para cambiar el aspecto — usa uno u otro, no hace falta llenar los dos. El fácil manda si lo rellenas." \
            --field="<b>✅  Camino fácil — color oficial de Mint</b> (recomendado):LBL" "" \
            --field="Color oficial:CB"                "$MINTY_COLOR_LIST" \
            --field="Claro u oscuro:CB"                "$MINTY_MODE_LIST" \
            --field="<b>🔧  Camino manual</b> — elige cada pieza (opcional):LBL" "" \
            --field="Tema GTK:CB"                    "$GTK_LIST" \
            --field="Iconos:CB"                       "$ICON_LIST" \
            --field="Cinnamon (panel y menús):CB"     "$CINN_LIST" \
            --field="<b>🖱️  Cursor</b> — se aplica siempre, con cualquiera de los dos caminos:LBL" "" \
            --field="Cursor:CB"                       "$CURSOR_LIST" \
            --field="Tamaño de cursor (px):NUM"       "${cur_cursor_size}!16..96!1" \
            --field="<b>📁  Importar un tema descargado</b> (opcional):LBL" "" \
            --field="Archivo (.zip/.tar.gz/.tar.xz/.tar.bz2):FL" "" \
            --field="O carpeta ya descomprimida:DIR"  "" \
            --field="Aplicar temas!gtk-apply:FBTN"  "$(cm_fbtn_apply temas_aplicar 5 6 9 10 7 2 3)" \
            --field="Importar tema!gtk-add:FBTN"    "$(cm_fbtn_apply temas_importar 12 13)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_panel_aplicar() {
    local TARGET_LABEL="$1" PRESET_LABEL="$2" COLOR_RAW="$3" OPACITY_RAW="$4" HEIGHT_RAW="$5"
    local COLOR OPACITY HEIGHT
    COLOR=$(cm_normalize_hex "$COLOR_RAW")
    OPACITY=$(cm_num_int "$OPACITY_RAW")
    HEIGHT=$(cm_num_int "$HEIGHT_RAW")

    local target_key; target_key=$(cm_color_target_key_from_label "$TARGET_LABEL")
    local preset_key; preset_key=$(cm_accent_preset_key_from_label "$PRESET_LABEL") || preset_key="personalizado"
    if [ "$preset_key" != "personalizado" ] && [ -n "${CM_ACCENT_PRESET_HEX[$preset_key]:-}" ]; then
        COLOR="${CM_ACCENT_PRESET_HEX[$preset_key]}"
    fi

    cm_backup_current >/dev/null
    local -a applied=()
    if [ -n "$COLOR" ] && cm_is_valid_hex "$COLOR"; then
        local color_label="${CM_COLOR_TARGET_LABELS[$target_key]}: $COLOR"
        case "$target_key" in
            acento)        cm_report "$color_label" cm_apply_accent_color     "$COLOR" ;;
            fondo)         cm_report "$color_label" cm_apply_panel_bg_color   "$COLOR" ;;
            texto)         cm_report "$color_label" cm_apply_panel_fg_color   "$COLOR" ;;
            menu_fondo)    cm_report "$color_label" cm_apply_menu_bg_color    "$COLOR" ;;
            menu_texto)    cm_report "$color_label" cm_apply_menu_fg_color    "$COLOR" ;;
            tooltip_fondo) cm_report "$color_label" cm_apply_tooltip_bg_color "$COLOR" ;;
            tooltip_texto) cm_report "$color_label" cm_apply_tooltip_fg_color "$COLOR" ;;
            acento_gtk)    cm_report "$color_label" cm_apply_gtk_accent_color "$COLOR" ;;
        esac
    fi
    [ -n "$OPACITY" ] && cm_report "Opacidad: ${OPACITY}%" cm_apply_panel_opacity "$OPACITY"
    [ -n "$HEIGHT" ]  && cm_report "Alto: ${HEIGHT}px" cm_apply_panel_height "$HEIGHT"
    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "Panel actualizado" "${applied[@]}"
}

cm_ui_apply_panel_restablecer() {
    if cm_confirm "¿Restablecer el panel al tema original, quitando la personalización de color (acento/fondo/texto) aplicada hasta ahora?\nLa opacidad y el alto del panel, que son ajustes independientes, no se ven afectados."; then
        local _msg_file; _msg_file=$(mktemp "${TMPDIR:-/tmp}/cm_reset_msg.XXXXXX" 2>/dev/null) || _msg_file="/tmp/cm_reset_msg_$$"
        if cm_reset_panel_colors >"$_msg_file" 2>&1; then
            cm_reload_cinnamon
            cm_notify_applied "Color Mint" "Colores del panel restablecidos" "$(cat "$_msg_file")"
        else
            yad --info --text="Todavía no hay ninguna personalización de color que restablecer." --button="Entendido:0" 2>/dev/null
        fi
        rm -f "$_msg_file" 2>/dev/null
    fi
}

cm_ui_apply_panel_backup() {
    local LAST_BACKUP; LAST_BACKUP=$(cm_list_backups | head -n1)
    if [ -n "$LAST_BACKUP" ] && cm_confirm "¿Restaurar el último backup ($LAST_BACKUP)?\nSe sobreescribirá la configuración actual y se ELIMINARÁN los temas/ajustes de gtk-3.0 añadidos después de ese backup (no solo se revierten los cambios)."; then
        cm_restore_backup "$LAST_BACKUP"
        cm_notify_applied "Color Mint" "Backup restaurado: $LAST_BACKUP"
    fi
}

cm_tab_panel() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local cur_accent cur_opacity cur_height
        cur_accent=$(cm_state_get "ACCENT_COLOR" "#88C0D0")
        cur_opacity=$(cm_state_get "PANEL_OPACITY" "90")
        cur_height=$(cm_current_panel_height)

        # Más variedad: lista de acentos predefinidos (19, ver v2.4.0).
        # Siempre empieza en "Personalizado" para no pisar el selector de
        # color de arriba salvo que el usuario elija explícitamente uno.
        local accent_labels=() k PRESET_LIST
        for k in "${CM_ACCENT_PRESET_ORDER[@]}"; do accent_labels+=("${CM_ACCENT_PRESET_LABELS[$k]}"); done
        PRESET_LIST=$(_join_bang "${accent_labels[@]}")

        local target_labels=() TARGET_LIST
        for k in "${CM_COLOR_TARGET_ORDER[@]}"; do target_labels+=("${CM_COLOR_TARGET_LABELS[$k]}"); done
        TARGET_LIST=$(_join_bang "${target_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>🖥️  Panel</b>\n1) Elige qué parte colorear.  2) Un color rápido o el tuyo.  3) «Aplicar panel». Repite para colorear otra parte." \
            --field="¿Qué parte quieres colorear?:CB"               "$TARGET_LIST" \
            --field="Color rápido (opcional):CB"                    "$PRESET_LIST" \
            --field="O tu propio color:CLR"                        "$cur_accent" \
            --field="<b>📐  Tamaño del panel</b>:LBL" "" \
            --field="Opacidad (%):NUM"                             "${cur_opacity}!0..100!1" \
            --field="Alto (px):NUM"                                "${cur_height}!16..100!1" \
            --field="Aplicar panel!gtk-apply:FBTN"                  "$(cm_fbtn_apply panel_aplicar 1 2 3 5 6)" \
            --field="Restablecer colores!gtk-revert-to-saved:FBTN"  "$(cm_fbtn_apply panel_restablecer)" \
            --field="Restaurar último backup!gtk-undo:FBTN"        "$(cm_fbtn_apply panel_backup)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_escritorio_aplicar() {
    local POS_LABEL="$1" BTN_PRESET_LABEL="$2" EFFECTS_LABEL="$3" MENU_FX_LABEL="$4" WORKSPACES_RAW="$5" ICONS_LABEL="$6" BG_COLOR_RAW="$7" BGMODE_LABEL="$8"

    cm_backup_current >/dev/null
    local -a applied=()

    local POS; POS=$(cm_panelpos_key_from_label "$POS_LABEL")
    [ -n "$POS_LABEL" ] && cm_report "Posición del panel: ${CM_PANELPOS_LABELS[$POS]}" cm_apply_panel_position "$POS"

    # Si la etiqueta no coincide con ningún preset conocido (p.ej. el usuario
    # dejó seleccionado el aviso "mantener diseño a medida" porque su layout
    # actual es personalizado), esto devuelve vacío y sencillamente no se
    # toca el botón — el diseño a medida se sigue editando desde "Avanzado".
    local final_layout; final_layout=$(cm_button_preset_key_from_label "$BTN_PRESET_LABEL")
    [ -n "$final_layout" ] && cm_report "Botones de ventana: $final_layout" cm_apply_window_buttons "$final_layout"

    local final_effects final_menu_fx final_workspaces final_icons
    final_effects=$(cm_onoff_key_from_label "$EFFECTS_LABEL")
    final_menu_fx=$(cm_onoff_key_from_label "$MENU_FX_LABEL")
    final_icons=$(cm_showhide_key_from_label "$ICONS_LABEL")
    final_workspaces=$(cm_num_int "$WORKSPACES_RAW")
    cm_report "Efectos de ventana: $final_effects" cm_apply_desktop_effects "$final_effects"
    cm_report "Efectos en menús: $final_menu_fx" cm_apply_menu_effects "$final_menu_fx"
    [ -n "$final_workspaces" ] && cm_report "Espacios de trabajo: $final_workspaces" cm_apply_workspaces "$final_workspaces"
    cm_report "Iconos de escritorio: $final_icons" cm_apply_desktop_icons "$final_icons"

    local BG_COLOR; BG_COLOR=$(cm_normalize_hex "$BG_COLOR_RAW")
    if [ -n "$BG_COLOR" ] && cm_is_valid_hex "$BG_COLOR"; then
        local final_bgmode; final_bgmode=$(cm_bgmode_key_from_label "$BGMODE_LABEL")
        cm_report "Fondo de escritorio: $BG_COLOR (${CM_BGMODE_LABELS[$final_bgmode]})" cm_apply_desktop_bg_color "$BG_COLOR" "$final_bgmode"
    fi

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "Escritorio actualizado" "${applied[@]}"
}

cm_tab_escritorio() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local cur_pos cur_btn_val cur_btn_key
        cur_pos=$(cm_current_panel_position)
        [ "$cur_pos" = "top" ] || cur_pos="bottom"
        cur_btn_val=$(cm_current_window_buttons)
        cur_btn_key=$(cm_button_preset_key_from_value "$cur_btn_val" 2>/dev/null) || cur_btn_key=""

        # Efectos, espacios e iconos se releen en vivo (nunca un valor fijo
        # que pueda revertir algo al pulsar "Aplicar" sin tocar nada).
        local cur_effects cur_menu_fx cur_workspaces cur_icons cur_bg_color
        cur_effects=$(cm_current_desktop_effects)
        cur_menu_fx=$(cm_current_menu_effects)
        cur_workspaces=$(cm_current_workspaces)
        [[ "$cur_workspaces" =~ ^[0-9]+$ ]] || cur_workspaces=4
        cur_icons=$(cm_current_desktop_icons)
        cur_bg_color=$(cm_current_desktop_bg_color)
        cm_is_valid_hex "$cur_bg_color" || cur_bg_color="#2E3440"

        local POS_LIST BTN_LIST EFFECTS_LIST MENU_FX_LIST ICONS_LIST
        POS_LIST=$(_reorder_join_bang "${CM_PANELPOS_LABELS[$cur_pos]}" "${CM_PANELPOS_LABELS[bottom]}" "${CM_PANELPOS_LABELS[top]}")

        local k labels=()
        for k in "${CM_BUTTON_PRESET_ORDER[@]}"; do labels+=("${CM_BUTTON_PRESET_LABELS[$k]}"); done
        # Si el layout actual coincide con un preset conocido, se antepone su
        # etiqueta. Si es un diseño a medida (se edita en "Avanzado"), se
        # antepone un aviso que no coincide con ninguna etiqueta real, para
        # que "Aplicar escritorio" nunca lo sobrescriba en silencio.
        local btn_reorder_label
        if [ -n "$cur_btn_key" ]; then
            btn_reorder_label="${CM_BUTTON_PRESET_LABELS[$cur_btn_key]}"
        else
            btn_reorder_label="Mantener el diseño a medida actual (pestaña Avanzado)"
        fi
        BTN_LIST=$(_reorder_join_bang "$btn_reorder_label" "${labels[@]}")

        local onoff_labels=() showhide_labels=()
        for k in "${CM_ONOFF_ORDER[@]}"; do onoff_labels+=("${CM_ONOFF_LABELS[$k]}"); done
        for k in "${CM_SHOWHIDE_ORDER[@]}"; do showhide_labels+=("${CM_SHOWHIDE_LABELS[$k]}"); done
        EFFECTS_LIST=$(_reorder_join_bang "${CM_ONOFF_LABELS[$cur_effects]}" "${onoff_labels[@]}")
        MENU_FX_LIST=$(_reorder_join_bang "${CM_ONOFF_LABELS[$cur_menu_fx]}" "${onoff_labels[@]}")
        ICONS_LIST=$(_reorder_join_bang "${CM_SHOWHIDE_LABELS[$cur_icons]}" "${showhide_labels[@]}")

        local bgmode_labels=() BGMODE_LIST
        for k in "${CM_BGMODE_ORDER[@]}"; do bgmode_labels+=("${CM_BGMODE_LABELS[$k]}"); done
        BGMODE_LIST=$(_join_bang "${bgmode_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>🪟  Escritorio</b>\nLo más usado: panel, botones de ventana, efectos, espacios de trabajo y fondo. Esquinas activas y botones a medida están en «Avanzado»." \
            --field="<b>🪟  Panel y botones de ventana</b>:LBL" "" \
            --field="Posición del panel:CB"                         "$POS_LIST" \
            --field="Botones de ventana:CB"                          "$BTN_LIST" \
            --field="<b>✨  Efectos y espacios de trabajo</b>:LBL" "" \
            --field="Efectos de ventana:CB"                          "$EFFECTS_LIST" \
            --field="Efectos en menús:CB"                            "$MENU_FX_LIST" \
            --field="Espacios de trabajo:NUM"                        "${cur_workspaces}!1..20!1" \
            --field="⚠ Con \"espacios dinámicos\" activados, este valor no se nota hasta desactivarlos.:LBL" "" \
            --field="Iconos de escritorio:CB"                        "$ICONS_LIST" \
            --field="<b>🎨  Fondo de escritorio</b>:LBL" "" \
            --field="Color de fondo:CLR"                             "$cur_bg_color" \
            --field="Modo:CB"                                        "$BGMODE_LIST" \
            --field="Aplicar escritorio!gtk-apply:FBTN" "$(cm_fbtn_apply escritorio_aplicar 2 3 5 6 7 9 11 12)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_avanzado_aplicar() {
    local TL_LABEL="$1" TR_LABEL="$2" BL_LABEL="$3" BR_LABEL="$4" BTN_CUSTOM="$5"

    cm_backup_current >/dev/null
    local -a applied=()

    local tl tr bl br
    tl=$(cm_corner_key_from_label "$TL_LABEL")
    tr=$(cm_corner_key_from_label "$TR_LABEL")
    bl=$(cm_corner_key_from_label "$BL_LABEL")
    br=$(cm_corner_key_from_label "$BR_LABEL")
    cm_report "Esquinas activas: $tl / $tr / $bl / $br" cm_apply_hotcorners "$tl" "$tr" "$bl" "$br"

    [ -n "$BTN_CUSTOM" ] && cm_report "Botones de ventana (a medida): $BTN_CUSTOM" cm_apply_window_buttons "$BTN_CUSTOM"

    cm_reload_cinnamon
    cm_notify_applied "Color Mint" "Ajustes avanzados actualizados" "${applied[@]}"
}

# Pestaña para lo menos usado por un usuario medio (antes vivía dentro de
# "Escritorio", que llegó a tener 20 campos en una sola pantalla).
cm_tab_avanzado() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local hc_tl hc_tr hc_bl hc_br cur_btn_val
        read -r hc_tl hc_tr hc_bl hc_br <<< "$(cm_current_hotcorners)"
        cur_btn_val=$(cm_current_window_buttons)

        local k corner_labels=() CORNER_LIST_TL CORNER_LIST_TR CORNER_LIST_BL CORNER_LIST_BR
        for k in "${CM_CORNER_ORDER[@]}"; do corner_labels+=("${CM_CORNER_LABELS[$k]}"); done
        CORNER_LIST_TL=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_tl]:-}" "${corner_labels[@]}")
        CORNER_LIST_TR=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_tr]:-}" "${corner_labels[@]}")
        CORNER_LIST_BL=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_bl]:-}" "${corner_labels[@]}")
        CORNER_LIST_BR=$(_reorder_join_bang "${CM_CORNER_LABELS[$hc_br]:-}" "${corner_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>🧩  Avanzado</b>\nEsquinas activas y botones de ventana a medida. Para lo más común, usa la pestaña «Escritorio»." \
            --field="<b>🖱️  Esquinas activas</b> — mueve el ratón a una esquina para activar la acción:LBL" "" \
            --field="Sup. izquierda:CB"                             "$CORNER_LIST_TL" \
            --field="Sup. derecha:CB"                                "$CORNER_LIST_TR" \
            --field="Inf. izquierda:CB"                              "$CORNER_LIST_BL" \
            --field="Inf. derecha:CB"                                "$CORNER_LIST_BR" \
            --field="<b>🔘  Botones de ventana a medida</b> (opcional):LBL" "" \
            --field="Cadena personalizada:"                          "$cur_btn_val" \
            --field="Valores: close, minimize, maximize, spacer, menu, stick, above, lower, shade  ·  \":\" separa izquierda/derecha:LBL" "" \
            --field="Aplicar avanzado!gtk-apply:FBTN" "$(cm_fbtn_apply avanzado_aplicar 2 3 4 5 7)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_terminal_aplicar() {
    local PALETTE_LABEL="$1" CUSTOM_BG_RAW="$2" CUSTOM_FG_RAW="$3" USE_CUSTOM="$4"
    if [ -z "$PALETTE_LABEL" ] && [ "$USE_CUSTOM" != "TRUE" ]; then
        yad --error --text="Elige una paleta o marca «Usar estos colores personalizados» antes de pulsar «Aplicar terminal»." --button="Entendido:0" 2>/dev/null
        return
    fi

    local PALETTE=""
    [ -n "$PALETTE_LABEL" ] && PALETTE=$(cm_palette_key_from_label "$PALETTE_LABEL")

    cm_backup_current >/dev/null
    local -a applied=()
    [ -n "$PALETTE" ] && cm_report "Paleta de color: ${CM_PALETTE_LABELS[$PALETTE]}" cm_apply_terminal_palette "$PALETTE"

    # El selector :CLR de YAD nunca vuelve realmente vacío (siempre trae un
    # color de fábrica), así que "aplicar o no" depende de esta casilla
    # explícita y no de si el campo tiene contenido.
    if [ "$USE_CUSTOM" = "TRUE" ]; then
        local cbg="" cfg=""
        [ -n "$CUSTOM_BG_RAW" ] && cbg=$(cm_normalize_hex "$CUSTOM_BG_RAW")
        [ -n "$CUSTOM_FG_RAW" ] && cfg=$(cm_normalize_hex "$CUSTOM_FG_RAW")
        cm_report "Colores personalizados de terminal" cm_apply_terminal_custom_colors "$cbg" "$cfg"
    fi

    cm_notify_applied "Color Mint" "Terminal actualizado" "${applied[@]}"
}

cm_tab_terminal() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local cur_palette cur_palette_label="" k palette_labels=() PALETTES
        cur_palette=$(cm_state_get "TERMINAL_PALETTE" "")
        [ -n "$cur_palette" ] && cur_palette_label="${CM_PALETTE_LABELS[$cur_palette]:-}"
        for k in "${CM_PALETTE_ORDER[@]}"; do palette_labels+=("${CM_PALETTE_LABELS[$k]}"); done
        PALETTES=$(_reorder_join_bang "$cur_palette_label" "${palette_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>⌨️  Terminal</b>\nElige una paleta lista para usar, o define tus propios colores de fondo y texto." \
            --field="Paleta de colores:CB" "$PALETTES" \
            --field="<b>🎨  Personalizado</b> (opcional, anula la paleta de arriba):LBL" "" \
            --field="Fondo:CLR" "" \
            --field="Texto:CLR" "" \
            --field="Usar estos colores personalizados:CHK" "FALSE" \
            --field="💡 El selector de color siempre trae un tono de fábrica: marca la casilla de arriba solo si quieres aplicar Fondo/Texto.:LBL" "" \
            --field="Aplicar terminal!gtk-apply:FBTN" "$(cm_fbtn_apply terminal_aplicar 1 3 4 5)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_fuentes_aplicar() {
    local FONT_UI="$1" FONT_MONO="$2" ANTIALIAS_LABEL="$3" HINTING_LABEL="$4" SCALING_RAW="$5"
    local SCALING; SCALING=$(cm_num_int "$SCALING_RAW")
    local ANTIALIAS HINTING
    ANTIALIAS=$(cm_antialias_key_from_label "$ANTIALIAS_LABEL")
    HINTING=$(cm_hinting_key_from_label "$HINTING_LABEL")

    cm_backup_current >/dev/null
    local -a applied=()
    [ -n "$FONT_UI" ]   && cm_report "Fuente de interfaz: $FONT_UI"     cm_apply_font_name "$FONT_UI"
    [ -n "$FONT_MONO" ] && cm_report "Fuente monoespaciada: $FONT_MONO" cm_apply_monospace_font "$FONT_MONO"
    if [ -n "$ANTIALIAS_LABEL" ] && [ -n "$HINTING_LABEL" ]; then
        cm_report "Renderizado: ${CM_ANTIALIAS_LABELS[$ANTIALIAS]} / ${CM_HINTING_LABELS[$HINTING]}" cm_apply_font_rendering "$ANTIALIAS" "$HINTING"
    fi
    [ -n "$SCALING" ] && cm_report "Escala de texto: ${SCALING}%" cm_apply_text_scaling "$SCALING"
    cm_notify_applied "Color Mint" "Tipografía actualizada" "${applied[@]}"
}

cm_tab_fuentes() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local cur_font cur_mono cur_antialias cur_hinting cur_scaling
        cur_font=$(gsettings get org.cinnamon.desktop.interface font-name           2>/dev/null | tr -d "'")
        cur_mono=$(gsettings get org.gnome.desktop.interface monospace-font-name 2>/dev/null | tr -d "'")
        read -r cur_antialias cur_hinting <<< "$(cm_current_font_rendering)"
        cur_scaling=$(cm_current_text_scaling)
        [ -z "$cur_font" ] && cur_font="Noto Sans 10"
        [ -z "$cur_mono" ] && cur_mono="Noto Sans Mono 10"

        local k antialias_labels=() hinting_labels=() ANTIALIAS_LIST HINTING_LIST
        for k in "${CM_ANTIALIAS_ORDER[@]}"; do antialias_labels+=("${CM_ANTIALIAS_LABELS[$k]}"); done
        for k in "${CM_HINTING_ORDER[@]}"; do hinting_labels+=("${CM_HINTING_LABELS[$k]}"); done
        ANTIALIAS_LIST=$(_reorder_join_bang "${CM_ANTIALIAS_LABELS[$cur_antialias]:-${CM_ANTIALIAS_LABELS[rgba]}}" "${antialias_labels[@]}")
        HINTING_LIST=$(_reorder_join_bang "${CM_HINTING_LABELS[$cur_hinting]:-${CM_HINTING_LABELS[slight]}}" "${hinting_labels[@]}")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>🔤  Fuentes</b>\nTipografía de interfaz y monoespaciada, renderizado y escala de texto." \
            --field="<b>🔤  Tipografía</b>:LBL" "" \
            --field="Interfaz:FN"                  "$cur_font" \
            --field="Monoespaciada:FN"              "$cur_mono" \
            --field="<b>🖌️  Renderizado</b>:LBL" "" \
            --field="Antialiasing:CB"               "$ANTIALIAS_LIST" \
            --field="Hinting:CB"                    "$HINTING_LIST" \
            --field="💡 Se guarda en ~/.config/fontconfig/fonts.conf. Apps ya abiertas pueden necesitar reabrirse.:LBL" "" \
            --field="<b>🔍  Escala</b>:LBL" "" \
            --field="Escala de texto (%):NUM"       "${cur_scaling}!50..200!5" \
            --field="Aplicar fuentes!gtk-apply:FBTN" "$(cm_fbtn_apply fuentes_aplicar 2 3 5 6 9)" \
            --no-buttons >/dev/null 2>&1
    done
}

cm_ui_apply_perfiles_guardar() {
    local NEW_NAME="$1"
    if [ -n "$NEW_NAME" ]; then
        local preset_file=""
        preset_file=$(cm_save_preset "$NEW_NAME")
        cm_notify_applied "Color Mint" "Preset guardado" "Nombre: $NEW_NAME" "Archivo: ${preset_file:-$CM_PRESETS_DIR/$NEW_NAME.conf}"
    else
        yad --error --text="Escribe un nombre antes de pulsar «Guardar preset»." --button="Entendido:0" 2>/dev/null
    fi
}

cm_ui_apply_perfiles_cargar() {
    local LOAD_NAME="$1"
    if [ -n "$LOAD_NAME" ]; then
        cm_backup_current >/dev/null
        cm_load_preset "$LOAD_NAME"
        cm_notify_applied "Color Mint" "Preset cargado" "Nombre: $LOAD_NAME" "Se aplicaron temas, colores, panel, escritorio, terminal y fuentes guardados en ese preset."
    else
        yad --error --text="Elige un preset de la lista antes de pulsar «Cargar preset»." --button="Entendido:0" 2>/dev/null
    fi
}

cm_ui_apply_perfiles_restaurar() {
    local RESTORE_NAME="$1"
    if [ -z "$RESTORE_NAME" ]; then
        yad --error --text="Elige un backup de la lista antes de pulsar «Restaurar backup»." --button="Entendido:0" 2>/dev/null
    elif cm_confirm "¿Restaurar el backup '$RESTORE_NAME'?\nSe sobreescribirá la configuración actual y se ELIMINARÁN los temas/ajustes de gtk-3.0 añadidos después de ese backup (no solo se revierten los cambios)."; then
        cm_restore_backup "$RESTORE_NAME"
        cm_notify_applied "Color Mint" "Backup restaurado" "Nombre: $RESTORE_NAME"
    fi
}

cm_tab_perfiles() {
    local KEY="$1" TABNUM="$2"
    while true; do
        local PRESETS BACKUPS
        PRESETS=$(_lines_to_bang "$(cm_list_presets)")
        BACKUPS=$(_lines_to_bang "$(cm_list_backups)")

        yad --plug="$KEY" --tabnum="$TABNUM" --form \
            --css="$CM_CSS_FILE" \
            --text="<b>💾  Perfiles</b>\nGuarda el estado actual como preset, carga uno guardado, o restaura un backup automático anterior." \
            --field="<b>💾  Guardar preset</b>:LBL" "" \
            --field="Nombre nuevo:"                "mi-preset" \
            --field="Guardar!gtk-save:FBTN"            "$(cm_fbtn_apply perfiles_guardar 2)" \
            --field="<b>📂  Cargar preset</b>:LBL" "" \
            --field="Preset guardado:CB"           "$PRESETS" \
            --field="Cargar!gtk-open:FBTN"             "$(cm_fbtn_apply perfiles_cargar 5)" \
            --field="<b>♻️  Restaurar backup</b>:LBL" "" \
            --field="Backup disponible:CB"         "$BACKUPS" \
            --field="Restaurar!gtk-undo:FBTN"          "$(cm_fbtn_apply perfiles_restaurar 8)" \
            --no-buttons >/dev/null 2>&1
    done
}

# ============================================================================
# GUI — ventana principal con pestañas (notebook de YAD)
# ============================================================================
cm_main_window() {
    cm_write_css
    cm_bootstrap_presets

    # Clave numérica para el notebook de YAD (--key/--plug exige un entero;
    # usar $$ garantiza unicidad para cada ejecución del script).
    local KEY="$$"
    CM_TAB_PIDS=()

    launch_tab() {
        local name="$1" tabnum="$2"
        # Se invoca con "bash $SCRIPT_PATH" en vez de ejecutar "$SCRIPT_PATH"
        # directamente: así no depende de que el archivo tenga el bit +x
        # (p.ej. si el usuario lo lanzó con "bash script.sh" en vez de
        # "./script.sh", o si se descargó sin permisos de ejecución).
        bash "$SCRIPT_PATH" __tab "$name" "$KEY" "$tabnum" &
        CM_TAB_PIDS+=("$!")
    }

    cm_cleanup_tabs() {
        local pid
        for pid in "${CM_TAB_PIDS[@]}"; do
            kill "$pid" 2>/dev/null
        done
    }
    trap cm_cleanup_tabs EXIT

    launch_tab temas      1
    launch_tab panel      2
    launch_tab escritorio 3
    launch_tab avanzado   4
    launch_tab terminal   5
    launch_tab fuentes    6
    launch_tab perfiles   7

    yad --notebook --key="$KEY" \
        --title="Color Mint" \
        --window-icon="preferences-desktop-theme" \
        --width=950 --height=740 \
        --css="$CM_CSS_FILE" \
        --tab="🎨  Temas" \
        --tab="🖥️  Panel" \
        --tab="🪟  Escritorio" \
        --tab="🧩  Avanzado" \
        --tab="⌨️  Terminal" \
        --tab="🔤  Fuentes" \
        --tab="💾  Perfiles" \
        --button="Salir:1"
}

# ============================================================================
# Ayuda / uso
# ============================================================================
# Imprime un bloque de ayuda: título + pares comando/descripción alineados
# en columna. El ancho de columna se calcula a partir del comando más largo
# del bloque (nunca queda torcido, ni aunque cambie el largo de $p).
cm_usage_section() {
    local title="$1"; shift
    local -a rows=("$@")
    local i w=0
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        [ ${#rows[i]} -gt "$w" ] && w=${#rows[i]}
    done
    echo; echo "  $title"
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        printf '    %-*s  %s\n' "$w" "${rows[i]}" "${rows[i + 1]}"
    done
}

cm_print_usage() {
    local p; p=$(basename "$SCRIPT_PATH")
    echo "Color Mint v$CM_VERSION — personalización estética avanzada para Linux Mint 22.3 Cinnamon (por $CM_AUTHOR)"

    local wg=$((${#p} + 6))
    echo; echo "MODO GRÁFICO (recomendado)"
    printf '  %-*s%s\n' "$wg" "$p"     "Abre la interfaz gráfica"
    printf '  %-*s%s\n' "$wg" "$p gui" "Igual que sin argumentos"

    echo; echo "MODO TERMINAL — un comando por ajuste, sin abrir la interfaz gráfica"

    cm_usage_section "🎨 Temas" \
        "$p theme mint-y-color <color> <claro|oscuro>" "Forma rápida: paquete oficial Mint-Y" \
        "$p theme gtk <nombre>"                     "Tema GTK" \
        "$p theme icon <nombre>"                    "Tema de iconos" \
        "$p theme cursor <nombre>"                  "Tema de cursor" \
        "$p theme cursor-size <16-96>"               "Tamaño del cursor, en píxeles" \
        "$p theme cinnamon <nombre>"                 "Tema de Cinnamon (panel y menús)" \
        "$p theme import <archivo|carpeta>"          "Instala un tema descargado (.zip/.tar.gz/.tar.xz/.tar.bz2)" \
        "$p theme folder"                            "Abre la carpeta de temas" \
        "$p theme list-gtk"                          "Temas GTK instalados" \
        "$p theme list-icon"                         "Temas de iconos instalados" \
        "$p theme list-cursor"                       "Temas de cursor instalados" \
        "$p theme list-cinnamon"                     "Temas de Cinnamon instalados" \
        "$p theme list-mint-y-colors <claro|oscuro>" "Colores oficiales Mint-Y disponibles"

    cm_usage_section "🖥️ Panel" \
        "$p panel <parte> <#RRGGBB>" "Colorea una parte del panel — <parte> es una de:" \
        ""                           "accent (acento), bg (fondo), fg (texto)," \
        ""                           "menu-bg, menu-fg, tooltip-bg, tooltip-fg," \
        ""                           "gtk-accent (acento en todas las apps)" \
        "$p panel opacity <0-100>"   "Opacidad del panel, en %" \
        "$p panel height <16-100>"   "Alto del panel, en píxeles" \
        "$p panel reset-colors"      "Quita la personalización de color del panel"

    cm_usage_section "🪟 Escritorio" \
        "$p desktop panel-position <top|bottom>"      "Panel arriba o abajo" \
        "$p desktop window-buttons <preset|cadena>"   "Botones de la ventana" \
        "$p desktop list-button-presets"              "Lista los presets de botones" \
        "$p desktop hotcorners <sup-izq> <sup-der> <inf-izq> <inf-der>" "Esquina activa: none, expo, scale o desktop" \
        "$p desktop effects <on|off>"                 "Efectos al abrir/cerrar ventanas" \
        "$p desktop menu-effects <on|off>"            "Efectos al abrir menús" \
        "$p desktop workspaces <1-20>"                "Número de espacios de trabajo" \
        "$p desktop icons <show|hide>"                "Iconos del escritorio" \
        "$p desktop bg-color <#RRGGBB> <mantener|solo_color>" "Color de fondo (\"mantener\" lo combina con la imagen actual)"

    cm_usage_section "⌨️ Terminal" \
        "$p terminal apply_palette <nombre>"         "Aplica una paleta de color lista para usar" \
        "$p terminal list"                           "Lista las paletas disponibles" \
        "$p terminal custom-colors <#fondo> <#texto>" "Colores a medida (cualquiera puede ir vacío: \"\")"

    cm_usage_section "🔤 Fuentes" \
        "$p fonts font <nombre>"      "Fuente de la interfaz" \
        "$p fonts monospace <nombre>" "Fuente monoespaciada (terminal, editores)" \
        "$p fonts rendering <rgba|grayscale|none> <slight|medium|full|none>" "Antialiasing e hinting" \
        "$p fonts scaling <50-200>"   "Escala del texto, en %"

    cm_usage_section "💾 Backups y presets" \
        "$p backup create"           "Crea una copia de seguridad ahora" \
        "$p backup list"             "Lista las copias de seguridad" \
        "$p backup restore <nombre>" "Restaura una copia de seguridad" \
        "$p preset save <nombre>"    "Guarda el estado actual como preset" \
        "$p preset list"             "Lista los presets guardados" \
        "$p preset load <nombre>"    "Aplica un preset guardado"

    echo
    echo "Datos, backups, presets y logs viven en:"
    echo "  $CM_HOME"
}

# Mensaje de error corto para un subcomando no reconocido: en vez de repetir
# toda la sintaxis comprimida, señala el valor recibido y remite a la
# sección correspondiente de --help (ya organizada por áreas).
cm_usage_error() {
    echo "Opción de '$1' no reconocida: $3" >&2
    echo "Ver '$(basename "$SCRIPT_PATH") --help' → sección $2." >&2
    exit 1
}

# ============================================================================
# Dispatcher de línea de comandos
# ============================================================================
case "${1:-gui}" in
    __tab)
        # Modo interno: lanza una pestaña embebida (usado por cm_main_window)
        #
        shift
        _name="${1:-}"; _key="${2:-}"; _tabnum="${3:-}"
        case "$_name" in
            temas)      cm_tab_temas      "$_key" "$_tabnum" ;;
            panel)      cm_tab_panel      "$_key" "$_tabnum" ;;
            escritorio) cm_tab_escritorio "$_key" "$_tabnum" ;;
            avanzado)   cm_tab_avanzado   "$_key" "$_tabnum" ;;
            terminal)   cm_tab_terminal   "$_key" "$_tabnum" ;;
            fuentes)    cm_tab_fuentes    "$_key" "$_tabnum" ;;
            perfiles)   cm_tab_perfiles   "$_key" "$_tabnum" ;;
            *) echo "Pestaña interna desconocida: $_name" >&2; exit 1 ;;
        esac
        exit 0
        ;;

    __apply)
        # Modo interno: invocado directamente por un botón "Aplicar..." de
        # la GUI (ver cm_fbtn_apply). Recibe los valores de los campos del
        # formulario ya como argumentos (vía sustitución %N de YAD).
        shift
        _modo="${1:-}"; shift 2>/dev/null || true
        case "$_modo" in
            temas_aplicar)      cm_ui_apply_temas_aplicar "$@" ;;
            temas_importar)     cm_ui_apply_temas_importar "$@" ;;
            panel_aplicar)      cm_ui_apply_panel_aplicar "$@" ;;
            panel_restablecer)  cm_ui_apply_panel_restablecer ;;
            panel_backup)       cm_ui_apply_panel_backup ;;
            escritorio_aplicar) cm_ui_apply_escritorio_aplicar "$@" ;;
            avanzado_aplicar)   cm_ui_apply_avanzado_aplicar "$@" ;;
            terminal_aplicar)   cm_ui_apply_terminal_aplicar "$@" ;;
            fuentes_aplicar)    cm_ui_apply_fuentes_aplicar "$@" ;;
            perfiles_guardar)   cm_ui_apply_perfiles_guardar "$@" ;;
            perfiles_cargar)    cm_ui_apply_perfiles_cargar "$@" ;;
            perfiles_restaurar) cm_ui_apply_perfiles_restaurar "$@" ;;
            *) echo "Modo de aplicación interno desconocido: $_modo" >&2; exit 1 ;;
        esac
        exit 0
        ;;

    theme)
        shift
        case "${1:-}" in
            gtk)           cm_apply_gtk_theme "${2:-}" ;;
            icon)          cm_apply_icon_theme "${2:-}" ;;
            cursor)        cm_apply_cursor_theme "${2:-}" ;;
            cursor-size)   cm_apply_cursor_size "${2:-}" ;;
            cinnamon)      cm_apply_cinnamon_theme "${2:-}" ;;
            import)        cm_import_theme "${2:-}" ;;
            folder)        cm_open_themes_folder ;;
            list-gtk)      cm_list_gtk_themes ;;
            list-icon)     cm_list_icon_themes ;;
            list-cursor)   cm_list_cursor_themes ;;
            list-cinnamon) cm_list_cinnamon_themes ;;
            mint-y-color      ) cm_apply_mint_y_pack "${2:-}" "${3:-claro}" ;;
            list-mint-y-colors) cm_list_mint_y_colors "$([ "${2:-claro}" = "oscuro" ] && echo Mint-Y-Dark || echo Mint-Y)" ;;
            *) cm_usage_error theme Temas "${1:-}" ;;
        esac
        ;;

    panel)
        shift
        case "${1:-}" in
            accent)      cm_apply_accent_color "${2:-}" ;;
            bg)          cm_apply_panel_bg_color "${2:-}" ;;
            fg)          cm_apply_panel_fg_color "${2:-}" ;;
            menu-bg)     cm_apply_menu_bg_color "${2:-}" ;;
            menu-fg)     cm_apply_menu_fg_color "${2:-}" ;;
            tooltip-bg)  cm_apply_tooltip_bg_color "${2:-}" ;;
            tooltip-fg)  cm_apply_tooltip_fg_color "${2:-}" ;;
            gtk-accent)  cm_apply_gtk_accent_color "${2:-}" ;;
            opacity)     cm_apply_panel_opacity "${2:-}" ;;
            height)      cm_apply_panel_height "${2:-}" ;;
            reset-colors) cm_reset_panel_colors ;;
            *) cm_usage_error panel Panel "${1:-}" ;;
        esac
        ;;

    desktop)
        shift
        case "${1:-}" in
            panel-position)      cm_apply_panel_position "${2:-}" ;;
            window-buttons)      cm_apply_window_buttons "${2:-}" ;;
            list-button-presets) cm_list_button_presets ;;
            hotcorners)          cm_apply_hotcorners "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
            effects)              cm_apply_desktop_effects "${2:-}" ;;
            menu-effects)         cm_apply_menu_effects "${2:-}" ;;
            workspaces)           cm_apply_workspaces "${2:-}" ;;
            icons)                cm_apply_desktop_icons "${2:-}" ;;
            bg-color)             cm_apply_desktop_bg_color "${2:-}" "${3:-mantener}" ;;
            *) cm_usage_error desktop Escritorio "${1:-}" ;;
        esac
        ;;

    terminal)
        shift
        case "${1:-}" in
            apply_palette)   cm_apply_terminal_palette "${2:-}" ;;
            list)            cm_list_terminal_palettes ;;
            custom-colors)   cm_apply_terminal_custom_colors "${2:-}" "${3:-}" ;;
            *) cm_usage_error terminal Terminal "${1:-}" ;;
        esac
        ;;

    fonts)
        shift
        case "${1:-}" in
            font)      cm_apply_font_name "${2:-}" ;;
            monospace) cm_apply_monospace_font "${2:-}" ;;
            rendering) cm_apply_font_rendering "${2:-}" "${3:-}" ;;
            scaling)   cm_apply_text_scaling "${2:-}" ;;
            *) cm_usage_error fonts Fuentes "${1:-}" ;;
        esac
        ;;

    backup)
        shift
        case "${1:-}" in
            create)  cm_backup_current ;;
            list)    cm_list_backups ;;
            restore) cm_restore_backup "${2:-}" ;;
            *) cm_usage_error backup "Backups y presets" "${1:-}" ;;
        esac
        ;;

    preset)
        shift
        cm_bootstrap_presets
        case "${1:-}" in
            save) cm_save_preset "${2:-}" ;;
            list) cm_list_presets ;;
            load) cm_load_preset "${2:-}" ;;
            *) cm_usage_error preset "Backups y presets" "${1:-}" ;;
        esac
        ;;

    gui)
        # Comprobación de entorno: esto está pensado para Cinnamon
        if [ -z "${XDG_CURRENT_DESKTOP:-}" ]; then
            echo "Aviso: no se detecta variable XDG_CURRENT_DESKTOP. Si no estás en una sesión Cinnamon algunas opciones no tendrán efecto." >&2
        fi

        cm_check_dependencies yad dconf gsettings gdbus

        cm_log "INFO" "Iniciando Color Mint"
        cm_main_window
        cm_log "INFO" "Color Mint cerrado"
        ;;

    -h|--help)
        cm_print_usage
        ;;

    *)
        echo "Comando desconocido: ${1:-}" >&2
        cm_print_usage
        exit 1
        ;;
esac
