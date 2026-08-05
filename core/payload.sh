#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Payload, bug host, SNI y ruta WS
#
# Estos cuatro datos son los que cambian de un operador a otro y los que
# el revendedor toca a diario. No estan quemados en el codigo: se guardan
# en $PAYLOAD_CONF y de ahi los leen el generador de configuraciones, el
# proxy del 80 y el vhost de nginx.
#
#   BUG_HOST      host que va en la cabecera del payload (texto plano, :80)
#   SNI_HOST      servername del handshake TLS (texto cifrado, :443)
#   WS_PATH       ruta WebSocket del tunel SSH detras de nginx
#   HTTP_RESPONSE primera linea con la que nexo-hproxy contesta al inyector
#
# Cambiar BUG_HOST o SNI_HOST NO toca el servidor: son datos que viajan en
# la peticion del cliente. Solo se guardan aqui para que las configuraciones
# generadas salgan ya rellenas.
# Cambiar WS_PATH o HTTP_RESPONSE SI toca el servidor (nginx / hproxy) y
# por eso este script los reaplica.
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
need_root
load_ports
load_payload

# Rutas que ya usa el vhost de nginx. Si el revendedor pone la ruta del
# tunel SSH en una de estas, nginx se queda con dos bloques para el mismo
# path: el 'location = /vmess' de Xray gana al '^~' del tunel y el WSS
# empieza a entregar trafico SSH a Xray. No falla nada, no avisa nadie, y
# el cliente solo ve "conectando..." para siempre.
RESERVADAS="/vmess /vless /trojan /nexo-grpc /.well-known"

ruta_libre() {
  local r="$1" x
  for x in $RESERVADAS; do
    [[ "$r" == "$x" || "$r" == "$x/"* ]] && return 1
  done
  return 0
}

RESPUESTAS=(
  "HTTP/1.1 101 Switching Protocols"
  "HTTP/1.1 200 OK"
  "HTTP/1.1 200 Connection established"
  "HTTP/1.1 101 Switching Protocols|HTTP/1.1 200 OK"
)

pantalla() {
  cls
  header "Payload / Bug / SNI"
  ui_top "ACTUAL"
  ui_row "BUG HOST"  "${BUG_HOST:-(sin definir)}"  "$( [[ -n "$BUG_HOST" ]] && echo "$C_OK" || echo "$C_DIM" )"
  ui_row "SNI"       "${SNI_HOST:-(sin definir)}"  "$( [[ -n "$SNI_HOST" ]] && echo "$C_OK" || echo "$C_DIM" )"
  ui_row "RUTA WS"   "$WS_PATH"                     "$C_ACCENT2"
  ui_row "RESPUESTA" "${HTTP_RESPONSE%%|*}"
  ui_bottom
  echo ""
  ui_top "EDITAR"
  ui_item       "1" "Bug host (payload, puerto 80)"
  ui_item       "2" "SNI (TLS, puerto 443)"
  ui_item       "3" "Ruta WebSocket"
  ui_item       "4" "Respuesta HTTP del proxy"
  ui_blank
  ui_item       "5" "Ver payload de ejemplo"
  ui_item_quiet "0" "Volver"
  ui_bottom
}

reaplicar() {
  info "Reaplicando servicios afectados..."
  write_hproxy_env
  bash "$NEXO_INSTALL/core/nginx.sh" apply
  restart_hproxy
  ok "Listo"
}

ejemplo_payload() {
  cls
  header "Payload" "Ejemplos"
  local host="${BUG_HOST:-bug.tudominio.com}"
  local real; real=$(conn_host)

  ui_thead "DIRECTO (el mas simple, funciona casi siempre)"
  cat <<EOF

GET / HTTP/1.1[crlf]Host: $host[crlf]Upgrade: websocket[crlf][crlf]

EOF
  ui_thead "CON CONNECT (para proxys del operador)"
  cat <<EOF

CONNECT $real:$HTTP_PORT HTTP/1.1[crlf]Host: $host[crlf][crlf]

EOF
  ui_thead "PARTIDO (cuando el operador inspecciona la primera linea)"
  cat <<EOF

GET / HTTP/1.1[crlf]Host: $host[crlf][crlf][split]CONNECT $real:$HTTP_PORT HTTP/1.1[crlf][crlf]

EOF
  ui_hr
  echo ""
  info "El proxy contesta a cualquiera de los tres: acepta metodo y ruta"
  info "arbitrarios y aguanta hasta 4 rondas de payload antes de pasar a SSH."
  echo ""
  warn "El bug host correcto depende de tu operador; el panel no lo adivina."
  pause
}

while true; do
  pantalla
  ui_prompt; read -r op; op="${op//[[:space:]]/}"
  case "$op" in
    1) echo ""
       read -rp "Bug host (vacio para borrar): " v
       if [[ -z "$v" ]] || valid_domain "$v"; then
         BUG_HOST="$v"; save_payload; ok "Guardado"
       else
         err "Formato de dominio invalido"
       fi
       sleep 1 ;;
    2) echo ""
       read -rp "SNI (vacio para borrar): " v
       if [[ -z "$v" ]] || valid_domain "$v"; then
         SNI_HOST="$v"; save_payload; ok "Guardado"
       else
         err "Formato de dominio invalido"
       fi
       sleep 1 ;;
    3) echo ""
       warn "Cambiar la ruta invalida las configuraciones ya repartidas."
       info "Reservadas por Xray: $RESERVADAS"
       read -rp "Ruta WebSocket (ej: /nexo): " v
       if ! valid_wspath "$v"; then
         err "Debe empezar por /, tener al menos un caracter y no llevar espacios"
       elif ! ruta_libre "$v"; then
         err "'$v' ya la usa Xray. Elige otra o el WSS dejaria de funcionar."
       else
         WS_PATH="$v"; save_payload; reaplicar
       fi
       pause ;;
    4) cls; header "Payload" "Respuesta HTTP"
       info "Es la primera linea que ve el inyector. Si tu operador filtra"
       info "por ella, prueba otra."
       echo ""
       i=1
       for r in "${RESPUESTAS[@]}"; do
         ui_item "$i" "${r//|/  +  }"
         ((i++))
       done
       ui_item_quiet "0" "Cancelar"
       ui_prompt; read -r sel
       if valid_number "${sel:-}" && (( sel >= 1 && sel <= ${#RESPUESTAS[@]} )); then
         HTTP_RESPONSE="${RESPUESTAS[$((sel-1))]}"
         save_payload
         write_hproxy_env
         restart_hproxy
         ok "Respuesta: $HTTP_RESPONSE"
       else
         info "Cancelado"
       fi
       pause ;;
    5) ejemplo_payload ;;
    0) exit 0 ;;
    *) printf " %b✗ Opcion invalida%b\n" "$C_ERR" "$C_RESET"; sleep 0.7 ;;
  esac
done
