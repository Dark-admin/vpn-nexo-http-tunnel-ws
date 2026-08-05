#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Capa de interfaz
#
# Misma filosofia que NexoServer: paleta, cajas y barras centralizadas
# para que todas las pantallas se vean igual, con adaptacion a 256/16/0
# colores y al ancho del terminal (el panel se usa mucho desde Termux).
#
# Tema: $NEXO_CONF/theme   (ver ui_themes: catppuccin, gruvbox, imperial...)
#==========================================

# Bash cuenta BYTES en ${#var} si el locale no es UTF-8, asi que un
# caracter como '·' mediria 2 y descuadraria la caja.
if [[ "${LC_ALL:-${LANG:-}}" != *[Uu][Tt][Ff]* ]]; then
  # Sin tuberia a proposito: bajo `set -o pipefail`, un `locale -a | grep -q`
  # devuelve 141 cuando grep encuentra la coincidencia y cierra la tuberia
  # antes de que locale acabe de escribir (SIGPIPE). El resultado es que la
  # comprobacion falla justo cuando deberia acertar. Ver lib/common.sh.
  _locs=$(locale -a 2>/dev/null)
  _locs=$'\n'"${_locs,,}"
  for _loc in C.UTF-8 en_US.UTF-8 es_ES.UTF-8; do
    _a="${_loc,,}"
    if [[ "$_locs" == *$'\n'"$_a"* || "$_locs" == *$'\n'"${_a//-/}"* ]]; then
      export LC_ALL="$_loc"; break
    fi
  done
  unset _locs _loc _a
fi

# --- Deteccion de capacidades ----------------------------------------
UI_COLORS=0
if [[ -t 1 ]]; then
  UI_COLORS=$(tput colors 2>/dev/null || echo 0)
fi
[[ "${NO_COLOR:-}" != "" ]] && UI_COLORS=0

# --- Caracteres del marco ---------------------------------------------
# Trazo GRUESO (Box Drawing "heavy"): se ve bastante mas solido que el
# fino de antes, que quedaba desvaido en pantallas de movil.
# El grueso no tiene esquinas redondeadas en Unicode, asi que se usan
# rectas; mezclar ╭ (fina redondeada) con ━ (gruesa) deja escalones en
# las uniones.
# Todos ocupan UNA columna, asi que las cajas siguen cuadrando.
# Cambiar el grosor de todo el panel es cambiar estas ocho lineas.
# El grosor va SOLO en el contorno. Los separadores de dentro y las
# rayas sueltas van finos: si todo es grueso la pantalla se satura y no
# se distingue el marco de las divisiones.
#
# ┠ y ┨ son las uniones mixtas (vertical grueso + horizontal fino): sin
# ellas, un separador fino dentro de una caja gruesa deja un escalon
# visible donde se junta con los laterales.
UI_TL="┏"; UI_TR="┓"     # esquinas de arriba   (contorno, grueso)
UI_BL="┗"; UI_BR="┛"     # esquinas de abajo    (contorno, grueso)
UI_ML="┠"; UI_MR="┨"     # union del separador  (mixta)
UI_H="━";  UI_V="┃"      # contorno horizontal y vertical (grueso)
UI_HS="─"                # separadores y rayas sueltas    (fino)

UI_TERM_COLS=$(tput cols 2>/dev/null || echo 80)
UI_W=46
(( UI_TERM_COLS < UI_W )) && UI_W=$UI_TERM_COLS
(( UI_W < 34 )) && UI_W=34
UI_INNER=$(( UI_W - 2 ))

# --- Paleta ------------------------------------------------------------
#
# Los temas se definen con colores EXACTOS en hexadecimal, no con indices
# de la paleta de 256 elegidos a ojo. Cada color se escribe "hex:indice":
# si el terminal admite color verdadero (24 bits) se usa el hex; si solo
# admite 256, el indice, que esta escogido a mano como la aproximacion mas
# cercana. Asi el tema se ve igual en una terminal moderna y sigue siendo
# correcto en Termux viejo o en una consola serie.
#
# Nota importante: el panel solo pinta el PRIMER PLANO. El fondo lo pone
# tu terminal, asi que las cifras de contraste que publican estos temas
# (que son fondo contra texto) no se heredan tal cual. Lo que se ha
# cuidado aqui es que los colores se lean sobre fondo oscuro, que es lo
# que usa practicamente todo el mundo por SSH.

UI_TRUECOLOR=0
if (( UI_COLORS >= 256 )) && [[ "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then
  UI_TRUECOLOR=1
fi

c256() { [[ $UI_COLORS -ge 256 ]] && printf '\033[38;5;%sm' "$1"; }
c16()  { [[ $UI_COLORS -ge 8 ]]   && printf '\033[%sm' "$1"; }

# _c "cba6f7:183" -> secuencia de color segun lo que soporte el terminal
_c() {
  local h="${1%%:*}" i="${1##*:}"
  if (( UI_TRUECOLOR )); then
    printf '\033[38;2;%d;%d;%dm' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))"
  else
    c256 "$i"
  fi
}

ui_load_theme() {
  local theme_file="${NEXO_CONF:-/etc/nexotunnel}/theme"
  UI_THEME="${NEXO_THEME:-$(cat "$theme_file" 2>/dev/null || echo catppuccin)}"

  # Cada tema define su paleta completa. Que OK/WARN/ERR sean por tema (y
  # no fijos) es lo que permite el tema accesible: ahi el verde y el rojo
  # se sustituyen por azul y naranja, que si distinguen las personas con
  # daltonismo rojo-verde (el ~8% de los hombres).
  local A A2 BD TX MU DI OK WN ER IN F16 GRAD

  # El nombre se valida ANTES del case de la paleta. Si el comodin '*'
  # estuviera dentro de ese case tendria que ir el ultimo, y basta que
  # alguien añada un tema debajo para que deje de aplicarse nunca.
  case "$UI_THEME" in
    naranja|catppuccin|gruvbox|nord|tokyonight|imperial|accesible|verde|cyan|mono) ;;
    *) UI_THEME=catppuccin ;;
  esac

  case "$UI_THEME" in
    # --- Catppuccin Mocha ---------------------------------------------
    # El de mayor contraste entre los que ademas tienen version para
    # terminal, editor y movil, asi que puedes dejarlo todo a juego.
    catppuccin)
      A="cba6f7:183"; A2="f9e2af:223"; BD="9399b2:146"
      TX="cdd6f4:189"; MU="a6adc8:146"; DI="7f849c:103"
      OK="a6e3a1:151"; WN="fab387:216"; ER="f38ba8:211"; IN="89b4fa:111"
      F16=35
      GRAD="b4befe:147 cba6f7:183 cba6f7:183 f5c2e7:218 f5c2e7:218 eba0ac:217 f9e2af:223 f9e2af:223 fab387:216 fab387:216"
      ;;

    # --- Naranja y morado -----------------------------------------------
    # El color se concentra en el CONTORNO: marco morado y titulos en
    # naranja. Dentro todo va en grises neutros, para que la vista se vaya
    # al dato y no al adorno.
    # Los avisos van en amarillo y no en naranja: con el acento ya naranja,
    # un aviso naranja no se distinguiria de un titulo.
    naranja)
      A="ff9e3d:215"; A2="c084fc:183"; BD="005f87:24"
      TX="e6e4ea:254"; MU="9c99a6:246"; DI="6b6875:242"
      OK="6ee7a0:84";  WN="ffd93d:220"; ER="ff5f5f:203"; IN="8ab4ff:111"
      F16=35
      GRAD="b4befe:147 cba6f7:183 cba6f7:183 f5c2e7:218 f5c2e7:218 eba0ac:217 f9e2af:223 f9e2af:223 fab387:216 fab387:216"
      ;;

    # --- Gruvbox Dark --------------------------------------------------
    # Tonos calidos y poco brillo: es el que menos cansa en sesiones largas.
    gruvbox)
      A="fabd2f:214"; A2="fe8019:208"; BD="a89984:246"
      TX="ebdbb2:187"; MU="bdae93:250"; DI="928374:245"
      OK="b8bb26:142"; WN="fe8019:208"; ER="fb4934:203"; IN="83a598:109"
      F16=33
      GRAD="fabd2f:214 fabd2f:214 fe8019:208 fe8019:208 d79921:172 d79921:172 b57614:136 b57614:136 af3a03:130 af3a03:130"
      ;;

    # --- Nord -----------------------------------------------------------
    # Frio y sobrio. El de menor contraste de los recomendados: comodo de
    # noche, flojo a pleno sol.
    nord)
      A="88c0d0:110"; A2="b48ead:139"; BD="7b88a8:103"
      TX="eceff4:255"; MU="d8dee9:188"; DI="616e88:60"
      OK="a3be8c:108"; WN="ebcb8b:222"; ER="bf616a:131"; IN="81a1c1:110"
      F16=36
      GRAD="8fbcbb:116 88c0d0:110 88c0d0:110 81a1c1:110 81a1c1:110 5e81ac:67 5e81ac:67 b48ead:139 b48ead:139 a3be8c:108"
      ;;

    # --- Tokyo Night ----------------------------------------------------
    # El mas vistoso, pero sus colores apagados desaparecen con el brillo
    # bajo: mal compañero para mirar el movil en la calle.
    tokyonight)
      A="7aa2f7:111"; A2="bb9af7:141"; BD="7982a9:103"
      TX="c0caf5:189"; MU="a9b1d6:146"; DI="565f89:60"
      OK="9ece6a:149"; WN="e0af68:179"; ER="f7768e:210"; IN="7dcfff:117"
      F16=36
      GRAD="7dcfff:117 7aa2f7:111 7aa2f7:111 bb9af7:141 bb9af7:141 9d7cd8:98 9d7cd8:98 f7768e:210 f7768e:210 ff9e64:215"
      ;;

    # --- Imperial (purpura + oro) --------------------------------------
    imperial)
      A="ffd700:220"; A2="af87ff:141"; BD="a24ce8:134"
      TX="e8e3f0:253"; MU="a89bb5:246"; DI="6e6478:242"
      OK="5fff87:84"; WN="ff8700:208"; ER="ff5f5f:203"; IN="87afff:111"
      F16=33
      GRAD="6a0dad:55 8700d7:92 9a30d9:98 af87ff:141 c9a0ff:183 e0c060:179 f0cf40:221 ffd700:220 ffc400:214 ffb000:214"
      ;;

    # --- Accesible (daltonismo) -----------------------------------------
    # Azul y naranja en vez de verde y rojo: es la unica pareja que
    # distinguen todos los tipos comunes de daltonismo. Los simbolos (● ○)
    # y los textos siguen ahi, que es lo que recomiendan las guias: el
    # color nunca debe ser el unico portador de la informacion.
    accesible)
      A="f0e442:227"; A2="56b4e9:74"; BD="3399dd:74"
      TX="ffffff:255"; MU="cccccc:252"; DI="888888:245"
      OK="56b4e9:74"; WN="e69f00:172"; ER="ee7733:166"; IN="0077bb:33"
      F16=33
      GRAD="0077bb:31 0088cc:32 56b4e9:74 56b4e9:74 88ccee:117 f0e442:227 f0e442:227 e69f00:172 ee7733:166 ee7733:166"
      ;;

    # --- Los de siempre --------------------------------------------------
    verde)
      A="00ff87:48"; A2="00d75f:41"; BD="00af5f:35"
      TX="dadada:253"; MU="8a8a8a:245"; DI="585858:240"
      OK="5fff87:84"; WN="ffd75f:221"; ER="ff5f5f:203"; IN="87afff:111"
      F16=32
      GRAD="00ff87:48 00ff87:48 00d787:42 00d787:42 00d75f:41 00d75f:41 00af5f:35 00af5f:35 008700:29 008700:29"
      ;;
    cyan)
      A="00ffff:51"; A2="00d7d7:44"; BD="0087af:31"
      TX="dadada:253"; MU="8a8a8a:245"; DI="585858:240"
      OK="5fff87:84"; WN="ffd75f:221"; ER="ff5f5f:203"; IN="87afff:111"
      F16=36
      GRAD="5fffff:87 00ffff:51 00ffff:51 00d7ff:45 00d7ff:45 00d7d7:44 00d7d7:44 00afd7:38 00afd7:38 0087af:31"
      ;;
    mono)
      A="d0d0d0:252"; A2="8a8a8a:245"; BD="8a8a8a:245"
      TX="e4e4e4:254"; MU="9e9e9e:247"; DI="6c6c6c:242"
      OK="d0d0d0:252"; WN="ffffff:255"; ER="ffffff:255"; IN="bcbcbc:250"
      F16=37
      GRAD="ffffff:255 eeeeee:255 e4e4e4:254 dadada:253 d0d0d0:252 c6c6c6:251 bcbcbc:250 b2b2b2:249 a8a8a8:248 9e9e9e:247"
      ;;
  esac

  if (( UI_COLORS >= 256 )); then
    local _NEG; _NEG=$(printf '[1m')
    C_ACCENT="$(_c "$A")";  C_ACCENT2="$(_c "$A2")"
    # El borde va en NEGRITA: en casi todos los terminales eso engorda
    # el trazo ademas de aclararlo, y es lo que hace que el marco deje
    # de verse desvaido en la pantalla del movil.
    C_BORDER="$(_c "$BD")$_NEG"
    C_TEXT="$(_c "$TX")";   C_MUTED="$(_c "$MU")";   C_DIM="$(_c "$DI")"
    C_OK="$(_c "$OK")";     C_WARN="$(_c "$WN")";    C_ERR="$(_c "$ER")"
    C_INFO="$(_c "$IN")";   C_KEY="$C_ACCENT"
    # Degradado del logo, precalculado: sin esto serian diez subshells
    # cada vez que se dibuja la pantalla principal.
    UI_GRAD=(); local g
    for g in $GRAD; do UI_GRAD+=("$(_c "$g")"); done
  elif (( UI_COLORS >= 8 )); then
    C_ACCENT="$(c16 "1;$F16")"; C_ACCENT2="$(c16 "0;$F16")"
    C_BORDER="$(c16 "0;$F16")"
    C_TEXT="$(c16 '1;37')";   C_MUTED="$(c16 '0;37')"; C_DIM="$(c16 '1;30')"
    C_OK="$(c16 '0;32')";     C_WARN="$(c16 '1;33')";  C_ERR="$(c16 '0;31')"
    C_INFO="$(c16 '0;34')";   C_KEY="$C_ACCENT"
    UI_GRAD=()
  else
    C_ACCENT=""; C_ACCENT2=""; C_BORDER=""; C_TEXT=""; C_MUTED=""
    C_DIM="";    C_OK="";      C_WARN="";   C_ERR="";  C_INFO=""; C_KEY=""
    UI_GRAD=()
  fi

  if (( UI_COLORS >= 8 )); then
    C_RESET='\033[0m'; C_BOLD='\033[1m'
  else
    C_RESET=''; C_BOLD=''
  fi
}

ui_save_theme() {
  mkdir -p "${NEXO_CONF:-/etc/nexotunnel}"
  echo "$1" > "${NEXO_CONF:-/etc/nexotunnel}/theme"
  NEXO_THEME="$1"
  ui_load_theme
}

# Orden a proposito: primero los recomendados por contraste y legibilidad
ui_themes() { echo "naranja catppuccin gruvbox imperial accesible nord tokyonight cyan verde mono"; }

# Una linea de contexto por tema, para que elegir no sea a ciegas
ui_theme_desc() {
  case "$1" in
    naranja)    echo "naranja y morado · color solo al marco" ;;
    catppuccin) echo "malva y oro · el de mas contraste" ;;
    gruvbox)    echo "calido · el que menos cansa" ;;
    imperial)   echo "purpura oscuro y oro" ;;
    accesible)  echo "azul/naranja · apto daltonismo" ;;
    nord)       echo "frio y sobrio · flojo a pleno sol" ;;
    tokyonight) echo "vistoso · se apaga con poco brillo" ;;
    cyan)       echo "el clasico de estos paneles" ;;
    verde)      echo "verde terminal" ;;
    mono)       echo "sin color · maxima compatibilidad" ;;
    *)          echo "" ;;
  esac
}

ui_load_theme

# --- Utilidades --------------------------------------------------------
ui_len() {
  local s="$1"
  s=$(printf '%b' "$s" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
  echo "${#s}"
}

ui_repeat() { local n=$1 ch="${2:- }" out=""; while (( n-- > 0 )); do out+="$ch"; done; printf '%s' "$out"; }

ui_clear() { clear 2>/dev/null || printf '\033[2J\033[H'; }

ui_fit() {
  local s="$1" n="$2"
  (( n < 1 )) && { printf ''; return; }
  if (( ${#s} > n )); then
    if (( n > 2 )); then printf '%s..' "${s:0:$((n-2))}"; else printf '%s' "${s:0:$n}"; fi
  else
    printf '%s' "$s"
  fi
}

# --- Cajas -------------------------------------------------------------
ui_top() {
  local title="${1:-}"
  title=$(ui_fit "$title" $(( UI_INNER - 4 )))
  if [[ -z "$title" ]]; then
    printf "%b${UI_TL}%s${UI_TR}%b\n" "$C_BORDER" "$(ui_repeat $UI_INNER "$UI_H")" "$C_RESET"
  else
    local fill=$(( UI_INNER - ${#title} - 3 ))
    (( fill < 0 )) && fill=0
    printf "%b${UI_TL}${UI_H} %b%b%s%b %b%s${UI_TR}%b\n" \
      "$C_BORDER" "$C_RESET" "$C_ACCENT$C_BOLD" "$title" "$C_RESET" \
      "$C_BORDER" "$(ui_repeat $fill "$UI_H")" "$C_RESET"
  fi
}

ui_sep()    { printf "%b${UI_ML}%s${UI_MR}%b\n" "$C_BORDER" "$(ui_repeat $UI_INNER "$UI_HS")" "$C_RESET"; }
ui_bottom() { printf "%b${UI_BL}%s${UI_BR}%b\n" "$C_BORDER" "$(ui_repeat $UI_INNER "$UI_H")" "$C_RESET"; }
ui_blank()  { printf "%b${UI_V}%s${UI_V}%b\n" "$C_BORDER" "$(ui_repeat $UI_INNER ' ')" "$C_RESET"; }

ui_line() {
  local content="$1" vis="${2:-}"
  [[ -z "$vis" ]] && vis=$(ui_len "$content")
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0
  printf "%b${UI_V}%b %b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "" "$(printf '%b' "$content")" "$C_RESET" \
    "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

ui_row() {
  local label="$1" value="$2" vc="${3:-$C_TEXT}"
  local lw=10
  (( UI_INNER < 30 )) && lw=8
  label=$(ui_fit "$label" $lw)
  value=$(ui_fit "$value" $(( UI_INNER - lw - 3 )))
  local vis=$(( lw + 1 + ${#value} ))
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0
  printf "%b${UI_V}%b %b%-${lw}s%b %b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$C_MUTED" "$label" "$C_RESET" \
    "$vc" "$value" "$C_RESET" "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

ui_item() {
  local key="$1" text="$2" kc="${3:-$C_KEY}"
  text=$(ui_fit "$text" $(( UI_INNER - ${#key} - 7 )))
  local vis=$(( 2 + ${#key} + 3 + ${#text} ))
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0
  printf "%b${UI_V}%b %b▸%b %b%s%b   %b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$C_BORDER" "$C_RESET" \
    "$kc$C_BOLD" "$key" "$C_RESET" "$C_TEXT" "$text" "$C_RESET" \
    "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

# ui_opt "1" "Cuentas" "12 · 3 en linea"   [color_tecla]
#
# Igual que ui_item pero con una pista a la derecha, en gris. Es lo que
# convierte el menu en un panel: se ve el estado de cada seccion sin tener
# que entrar en ella.
#
# Nada de emojis aqui: bash cuenta 1 caracter y el terminal dibuja 2
# columnas, asi que cualquier emoji descuadra la caja entera. Solo
# simbolos de ancho simple (▸ · ● ○ ✓ ✗ ›).
ui_opt() {
  local key="$1" text="$2" hint="${3:-}" kc="${4:-$C_KEY}"
  local libre=$(( UI_INNER - ${#key} - 7 ))
  (( libre < 4 )) && { ui_item "$key" "$text" "$kc"; return; }

  # El texto tiene prioridad: dice QUE hace la opcion, y recortarlo a la
  # vez que la pista deja cosas como "Payload / Bug /.. cdn.zerorated.ex..",
  # donde no se entiende ni una ni otra. Primero se recorta la pista; solo
  # si aun asi no cabe se toca el texto.
  if (( ${#text} + ${#hint} + 1 > libre )); then
    local max_hint=$(( libre - ${#text} - 1 ))
    if (( max_hint >= 6 )); then
      hint=$(ui_fit "$hint" "$max_hint")
    else
      hint=$(ui_fit "$hint" 10)
      text=$(ui_fit "$text" $(( libre - ${#hint} - 1 )))
    fi
  fi

  local pad=$(( libre - ${#text} - ${#hint} ))
  (( pad < 1 )) && pad=1

  printf "%b${UI_V}%b %b▸%b %b%s%b   %b%s%b%s%b%s%b %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$C_BORDER" "$C_RESET" \
    "$kc$C_BOLD" "$key" "$C_RESET" \
    "$C_TEXT" "$text" "$C_RESET" \
    "$(ui_repeat $pad ' ')" \
    "$C_DIM" "$hint" "$C_RESET" \
    "$C_BORDER" "$C_RESET"
}

# Etiqueta de seccion dentro de una caja: separa "lo del dia a dia" de
# "lo que se toca una vez".
ui_group() {
  ui_line "$C_DIM$1$C_RESET" "${#1}"
}

ui_item_quiet() {
  local key="$1" text="$2"
  text=$(ui_fit "$text" $(( UI_INNER - ${#key} - 7 )))
  local vis=$(( 2 + ${#key} + 3 + ${#text} ))
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0
  printf "%b${UI_V}%b %b·%b %b%s%b   %b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$C_DIM" "$C_RESET" \
    "$C_MUTED$C_BOLD" "$key" "$C_RESET" "$C_MUTED" "$text" "$C_RESET" \
    "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

# --- Barras ------------------------------------------------------------
ui_bar() {
  local pct="${1:-0}" width="${2:-12}"
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local col="$C_OK"
  (( pct >= 70 )) && col="$C_WARN"
  (( pct >= 90 )) && col="$C_ERR"
  printf "%b%s%b%s%b" "$col" "$(ui_repeat $filled '█')" "$C_DIM" "$(ui_repeat $empty '░')" "$C_RESET"
}

ui_row_bar() {
  local label="$1" pct="$2" detail="$3"
  local lw=10
  (( UI_INNER < 30 )) && lw=7
  label=$(ui_fit "$label" $lw)

  local libre=$(( UI_INNER - lw - 2 - 5 - 2 ))
  local bw=10
  (( libre - bw < ${#detail} )) && bw=$(( libre - ${#detail} ))
  (( bw > 10 )) && bw=10
  (( bw < 4 ))  && bw=4
  detail=$(ui_fit "$detail" $(( libre - bw )))

  local vis=$(( lw + 1 + bw + 1 + 4 + 1 + ${#detail} ))
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0

  local pcol="$C_OK"
  (( pct >= 70 )) && pcol="$C_WARN"
  (( pct >= 90 )) && pcol="$C_ERR"

  printf "%b${UI_V}%b %b%-${lw}s%b %s %b%3s%%%b %b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$C_MUTED" "$label" "$C_RESET" \
    "$(ui_bar "$pct" $bw)" \
    "$pcol" "$pct" "$C_RESET" \
    "$C_MUTED" "$detail" "$C_RESET" \
    "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

# --- Insignias ---------------------------------------------------------
ui_dot_ok()   { printf "%b●%b" "$C_OK" "$C_RESET"; }
ui_dot_err()  { printf "%b●%b" "$C_ERR" "$C_RESET"; }
ui_dot_warn() { printf "%b●%b" "$C_WARN" "$C_RESET"; }
ui_dot_off()  { printf "%b○%b" "$C_DIM" "$C_RESET"; }

ui_status_row() {
  local name="$1" state="$2" text="$3"
  local dot col
  case "$state" in
    ok)   dot=$(ui_dot_ok);   col="$C_OK" ;;
    err)  dot=$(ui_dot_err);  col="$C_ERR" ;;
    warn) dot=$(ui_dot_warn); col="$C_WARN" ;;
    *)    dot=$(ui_dot_off);  col="$C_DIM" ;;
  esac
  local nw=16
  (( UI_INNER < 34 )) && nw=13
  name=$(ui_fit "$name" $(( nw - 1 )))
  text=$(ui_fit "$text" $(( UI_INNER - nw - 5 )))
  local vis=$(( 2 + nw + ${#text} ))
  local pad=$(( UI_INNER - vis - 2 ))
  (( pad < 0 )) && pad=0
  printf "%b${UI_V}%b %s %b%-${nw}s%b%b%s%b%s %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$dot" \
    "$C_TEXT" "$name" "$C_RESET" "$col" "$text" "$C_RESET" \
    "$(ui_repeat $pad ' ')" "$C_BORDER" "$C_RESET"
}

# --- Cabecera ----------------------------------------------------------
ui_logo() {
  local sub="${1:-netfree · free to the world  v1.0}"
  local word="NEXOTUNNEL"

  # "N E X O T U N N E L" = 19 caracteres visibles.
  # El degradado viene de UI_GRAD, que ui_load_theme ya dejo convertido a
  # secuencias de escape: aqui no se lanza ningun proceso al dibujar.
  local spaced="" i ch
  for (( i=0; i<${#word}; i++ )); do
    ch="${word:$i:1}"
    if (( ${#UI_GRAD[@]} > i )); then
      spaced+="${UI_GRAD[$i]}$C_BOLD$ch"
    else
      spaced+="$C_ACCENT$C_BOLD$ch"
    fi
    (( i < ${#word}-1 )) && spaced+=" "
  done
  spaced+="$C_RESET"

  ui_top
  ui_line "$spaced" 19
  ui_line "$C_DIM$sub$C_RESET" "${#sub}"
  ui_bottom
}

# --- Mensajes ----------------------------------------------------------
ui_ok()   { printf " %b✓%b %s\n" "$C_OK"   "$C_RESET" "$*"; }
ui_err()  { printf " %b✗%b %s\n" "$C_ERR"  "$C_RESET" "$*" >&2; }
ui_warn() { printf " %b!%b %s\n" "$C_WARN" "$C_RESET" "$*"; }
ui_info() { printf " %b·%b %s\n" "$C_INFO" "$C_RESET" "$*"; }

ui_prompt() { printf "\n %b❯%b " "$C_ACCENT" "$C_RESET"; }

# Pista de teclas al pie. Estar tres niveles dentro y no saber como salir
# es la queja numero uno de cualquier menu de terminal.
ui_keys() {
  printf " %b%s%b\n" "$C_DIM" "$*" "$C_RESET"
}

# --- Migas de pan ------------------------------------------------------
# ui_crumbs "Cuentas" "Crear"  ->   NEXOTUNNEL › Cuentas › Crear
#
# Sustituye a la cabecera en caja de antes: ocupa una linea en vez de
# tres (que en Termux es media pantalla) y ademas dice DONDE estas, no
# solo que pantalla es.
ui_crumbs() {
  local salida="$C_ACCENT$C_BOLD NEXOTUNNEL$C_RESET"
  local vis=11 x
  for x in "$@"; do
    [[ -z "$x" ]] && continue
    salida+="$C_DIM › $C_RESET$C_TEXT$x$C_RESET"
    vis=$(( vis + 3 + ${#x} ))
  done
  printf "%b\n" "$salida"
  printf " %b%s%b\n" "$C_DIM" "$(ui_repeat $(( UI_W - 2 )) "$UI_HS")" "$C_RESET"
}

# --- Insignias ---------------------------------------------------------
# ui_badge ok|warn|err|off "texto"  -> "● texto" con su color
ui_badge() {
  local estado="$1" texto="$2" col
  case "$estado" in
    ok)   col="$C_OK" ;;
    warn) col="$C_WARN" ;;
    err)  col="$C_ERR" ;;
    *)    col="$C_DIM" ;;
  esac
  printf "%b●%b %b%s%b" "$col" "$C_RESET" "$col" "$texto" "$C_RESET"
}

# Fila de resumen destacada: "● Todo operativo    9 de 9 servicios"
ui_estado() {
  local estado="$1" titulo="$2" detalle="${3:-}"
  local col
  case "$estado" in
    ok)   col="$C_OK" ;;
    warn) col="$C_WARN" ;;
    err)  col="$C_ERR" ;;
    *)    col="$C_DIM" ;;
  esac
  local libre=$(( UI_INNER - 4 ))
  detalle=$(ui_fit "$detalle" $(( libre / 2 )))
  titulo=$(ui_fit "$titulo" $(( libre - ${#detalle} - 1 )))
  local pad=$(( libre - ${#titulo} - ${#detalle} ))
  (( pad < 1 )) && pad=1
  printf "%b${UI_V}%b %b●%b %b%s%b%s%b%s%b %b${UI_V}%b\n" \
    "$C_BORDER" "$C_RESET" "$col" "$C_RESET" \
    "$col$C_BOLD" "$titulo" "$C_RESET" \
    "$(ui_repeat $pad ' ')" \
    "$C_MUTED" "$detalle" "$C_RESET" \
    "$C_BORDER" "$C_RESET"
}

# Pantalla vacia con salida sugerida: mejor que un "no hay nada" a secas
ui_vacio() {
  local que="$1" sugerencia="${2:-}"
  echo ""
  printf "   %b%s%b\n" "$C_MUTED" "$que" "$C_RESET"
  [[ -n "$sugerencia" ]] && printf "   %b%s%b\n" "$C_DIM" "$sugerencia" "$C_RESET"
  echo ""
}

ui_pause() {
  printf "\n %b%s%b\n" "$C_DIM" "$(ui_repeat $(( UI_W - 2 )) "$UI_HS")" "$C_RESET"
  read -rsn1 -p "$(printf " %bPulsa una tecla para continuar%b" "$C_DIM" "$C_RESET")" _
  echo ""
}

# --- Tablas ------------------------------------------------------------
ui_thead() {
  printf " %b%b%s%b\n" "$C_MUTED" "$C_BOLD" "$1" "$C_RESET"
  printf " %b%s%b\n" "$C_DIM" "$(ui_repeat $(( UI_W - 2 )) "$UI_HS")" "$C_RESET"
}

ui_hr() { printf " %b%s%b\n" "$C_DIM" "$(ui_repeat $(( UI_W - 2 )) "$UI_HS")" "$C_RESET"; }

# --- Bloques copiables -------------------------------------------------
# Los enlaces (vmess://, vless://...) NO deben ir dentro de una caja: si
# se cortan o se rellenan con espacios, el usuario copia basura. Se
# imprimen en crudo, con una etiqueta encima.
ui_field() {
  printf " %b%-13s%b %b%s%b\n" "$C_MUTED" "$1" "$C_RESET" "$C_TEXT" "$2" "$C_RESET"
}

ui_raw() {
  printf " %b%s%b\n" "$C_MUTED" "$1" "$C_RESET"
  printf "%s\n" "$2"
}
