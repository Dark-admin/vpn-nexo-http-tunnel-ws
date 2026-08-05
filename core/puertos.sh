#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Gestor de puertos y proxies
#
# Cada proxy es un proceso python que escucha en un puerto, se come el
# payload del inyector, contesta la cabecera HTTP que espera y entrega el
# trafico limpio a donde le digas.
#
#     [movil] --payload--> ESCUCHA --limpio--> DESTINO (SSH real)
#
# Todo se guarda en proxies.conf y se aplica regenerando las unidades de
# systemd y el firewall. Nada esta quemado en el instalador.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
need_root
px_init
load_ports

# --- Ayudas de presentacion -------------------------------------------
# Traduce un puerto a lo que realmente es, para que nadie tenga que
# acordarse de que "109" era dropbear.
que_es() {
  local p="$1"
  case "$p" in
    "$SSH_PORT")        echo "OpenSSH" ;;
    "$DROPBEAR_PORT1"|"$DROPBEAR_PORT2") echo "Dropbear" ;;
    "$TLS_PORT")        echo "nginx TLS" ;;
    "$STUNNEL_PORT")    echo "stunnel" ;;
    "$NGINX_LOCAL")     echo "nginx local" ;;
    "$XRAY_VMESS")      echo "Xray VMess" ;;
    "$XRAY_VLESS")      echo "Xray VLESS" ;;
    "$XRAY_TROJAN")     echo "Xray Trojan" ;;
    "$XRAY_GRPC")       echo "Xray gRPC" ;;
    *)                  echo "" ;;
  esac
}

tabla() {
  cls
  header "Puertos y proxies"

  printf " %b%-8s %-16s %-18s %-6s%b\n" "$C_MUTED$C_BOLD" \
    "NOMBRE" "ESCUCHA" "ENTREGA A" "ESTADO" "$C_RESET"
  ui_hr

  local n eh ep dh dp resp acme desc etiqueta estado col
  while IFS='|' read -r n eh ep dh dp resp acme desc; do
    [[ -z "$n" ]] && continue
    etiqueta=$(que_es "$dp")
    [[ -n "$etiqueta" ]] && etiqueta=" ($etiqueta)"

    if systemctl is-active "$PX_PREFIJO-$n" >/dev/null 2>&1; then
      estado="activo"; col="$C_OK"
    else
      estado="PARADO"; col="$C_ERR"
    fi

    local visible="$eh:$ep"
    [[ "$eh" == "127.0.0.1" ]] && visible="local:$ep"

    printf " %b%-8s%b %-16s %b%-18s%b %b%-6s%b\n" \
      "$C_TEXT" "$n" "$C_RESET" \
      "$visible" \
      "$C_ACCENT2" "$dh:$dp$etiqueta" "$C_RESET" \
      "$col" "$estado" "$C_RESET"
    printf "   %b%s%b\n" "$C_DIM" "$desc" "$C_RESET"
  done < <(px_list)

  ui_hr
  printf " %bLos 'local:' no se abren al exterior: son de uso interno.%b\n" \
    "$C_DIM" "$C_RESET"
}

# --- Pedir datos con contexto -----------------------------------------
mostrar_ocupados() {
  echo ""
  ui_thead "PUERTOS YA EN USO EN ESTE SERVIDOR"
  local p q
  for p in $(ss -tlnH 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -un); do
    q=$(que_es "$p")
    printf "   %-6s %s\n" "$p" "${q:-(otro)}"
  done
  echo ""
}

pedir_destino() {
  local __var="$1" actual="${2:-}"
  echo ""
  ui_thead "¿A DONDE ENTREGA EL TRAFICO?"
  printf "   %b1%b  Dropbear  (127.0.0.1:%s)   %brecomendado para tuneles%b\n" \
    "$C_KEY" "$C_RESET" "$DROPBEAR_PORT1" "$C_DIM" "$C_RESET"
  printf "   %b2%b  Dropbear  (127.0.0.1:%s)\n" "$C_KEY" "$C_RESET" "$DROPBEAR_PORT2"
  printf "   %b3%b  OpenSSH   (127.0.0.1:%s)\n" "$C_KEY" "$C_RESET" "$SSH_PORT"
  printf "   %b4%b  Otro puerto (lo escribo)\n" "$C_KEY" "$C_RESET"
  [[ -n "$actual" ]] && printf "   %b0%b  Dejarlo como esta (%s)\n" "$C_KEY" "$C_RESET" "$actual"
  ui_prompt; local s; read -r s

  case "$s" in
    1) printf -v "$__var" '%s' "$DROPBEAR_PORT1" ;;
    2) printf -v "$__var" '%s' "$DROPBEAR_PORT2" ;;
    3) printf -v "$__var" '%s' "$SSH_PORT" ;;
    4) local v
       ask_valid v "   Puerto de destino: " valid_port
       # Avisar de destinos que no van a funcionar como SSH
       local q; q=$(que_es "$v")
       if [[ "$q" == "nginx TLS" || "$q" == "stunnel" ]]; then
         echo ""
         warn "El puerto $v lo tiene $q, que habla TLS."
         warn "Este proxy entrega TCP en crudo: el cliente mandaria SSH y"
         warn "$q esperaria un handshake TLS. La conexion no llegaria a abrirse."
         ask_yes "   ¿Aun asi quieres apuntarlo ahi? (s/N):" n || return 1
       elif [[ "$q" == Xray* ]]; then
         echo ""
         warn "El puerto $v es un inbound de Xray, no un servidor SSH."
         ask_yes "   ¿Continuar igualmente? (s/N):" n || return 1
       fi
       printf -v "$__var" '%s' "$v" ;;
    0) [[ -n "$actual" ]] && printf -v "$__var" '%s' "$actual" || return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

pedir_escucha() {
  local __var_host="$1" __var_puerto="$2" propio="${3:-}"
  local p dueno choque

  while true; do
    echo ""
    ask_valid p "   Puerto de escucha: " valid_port

    choque=$(px_choque_interno "$p" "$propio")
    if [[ -n "$choque" ]]; then
      err "El proxy '$choque' ya escucha en el $p. Elige otro."
      continue
    fi

    dueno=$(px_quien_usa "$p" "python3")
    if [[ -n "$dueno" ]]; then
      echo ""
      warn "El puerto $p lo tiene ocupado: $dueno"
      warn "Dos procesos no pueden escuchar el mismo puerto: el proxy"
      warn "arrancaria y moriria con 'Address already in use'."
      if [[ "$dueno" == "nginx" ]]; then
        info "Para liberar el $p tendrias que mover nginx antes."
      fi
      ask_yes "   ¿Usarlo igualmente? (s/N):" n || continue
    fi
    break
  done

  echo ""
  ui_thead "¿QUIEN DEBE PODER CONECTARSE?"
  printf "   %b1%b  Cualquiera desde internet   (0.0.0.0)  %blo normal%b\n" \
    "$C_KEY" "$C_RESET" "$C_DIM" "$C_RESET"
  printf "   %b2%b  Solo este servidor          (127.0.0.1)\n" "$C_KEY" "$C_RESET"
  ui_prompt; local s; read -r s
  [[ "$s" == "2" ]] && printf -v "$__var_host" '%s' "127.0.0.1" \
                    || printf -v "$__var_host" '%s' "0.0.0.0"

  printf -v "$__var_puerto" '%s' "$p"
  return 0
}

pedir_respuesta() {
  local __var="$1"
  echo ""
  ui_thead "¿QUE CABECERA LE CONTESTA AL INYECTOR?"
  printf "   %b1%b  La que elijas en Payload/Bug/SNI  %brecomendado%b\n" \
    "$C_KEY" "$C_RESET" "$C_DIM" "$C_RESET"
  printf "   %b2%b  HTTP/1.1 101 Switching Protocols  (fija)\n" "$C_KEY" "$C_RESET"
  printf "   %b3%b  HTTP/1.1 200 OK                   (fija)\n" "$C_KEY" "$C_RESET"
  ui_prompt; local s; read -r s
  case "$s" in
    2) printf -v "$__var" '%s' "HTTP/1.1 101 Switching Protocols" ;;
    3) printf -v "$__var" '%s' "HTTP/1.1 200 OK" ;;
    *) printf -v "$__var" '%s' "panel" ;;
  esac
}

aplicar() {
  echo ""
  info "Regenerando unidades de systemd..."
  px_apply
  local r=$?
  info "Reaplicando firewall con los puertos nuevos..."
  bash "$NEXO_INSTALL/config/firewall.sh" apply >/dev/null 2>&1
  ok "Puertos abiertos: $(tcp_ports | tr '\n' ' ')"
  if (( r > 0 )); then
    echo ""
    warn "$r proxy(s) no arrancaron. Suele ser el puerto ocupado."
  fi
  echo ""
  warn "Recuerda: si tu VPS esta en AWS, Google Cloud o similar, ademas"
  warn "tienes que abrir el puerto en el panel del proveedor."
}

# --- Acciones ----------------------------------------------------------
accion_nuevo() {
  cls; header "Puertos" "Nuevo proxy"
  mostrar_ocupados

  local nombre
  while true; do
    read -rp "   Nombre corto (ej: ws2087): " nombre
    if [[ ! "$nombre" =~ ^[a-z0-9_-]{1,16}$ ]]; then
      err "Solo minusculas, digitos, guion y guion bajo (max 16)."
    elif px_existe "$nombre"; then
      err "Ya existe un proxy '$nombre'."
    else
      break
    fi
  done

  local eh ep dh dp resp
  pedir_escucha eh ep "$nombre" || { info "Cancelado"; pause; return; }
  dh="127.0.0.1"
  pedir_destino dp || { info "Cancelado"; pause; return; }
  pedir_respuesta resp

  echo ""
  read -rp "   Descripcion (para acordarte de para que es): " desc
  desc="${desc:-Proxy $nombre}"
  desc="${desc//|/ }"

  echo ""
  ui_top "SE VA A CREAR"
  ui_row "Nombre"   "$nombre"
  ui_row "Escucha"  "$eh:$ep"
  ui_row "Entrega"  "$dh:$dp $(que_es "$dp")"
  ui_row "Respuesta" "$( [[ "$resp" == panel ]] && echo "la del panel" || echo "$resp" )"
  ui_bottom
  echo ""
  ask_yes "   ¿Crear? (S/n):" s || { info "Cancelado"; pause; return; }

  px_add "$nombre" "$eh" "$ep" "$dh" "$dp" "$resp" "0" "$desc"
  aplicar
  pause
}

accion_editar() {
  cls; header "Puertos" "Editar"

  local -a lista=()
  mapfile -t lista < <(px_nombres)
  (( ${#lista[@]} == 0 )) && { warn "No hay proxies."; pause; return; }

  ui_top "ELEGIR"
  local i=1 n
  for n in "${lista[@]}"; do
    ui_item "$i" "$(printf '%-8s %s -> %s' "$n" \
      "$(px_campo "$n" 2):$(px_campo "$n" 3)" "$(px_campo "$n" 5)")"
    ((i++))
  done
  ui_item_quiet "0" "Volver"
  ui_bottom
  ui_prompt; local s; read -r s
  [[ "$s" == "0" || -z "$s" ]] && return
  valid_number "$s" && (( s >= 1 && s <= ${#lista[@]} )) || { err "Invalido"; sleep 1; return; }

  local nom="${lista[$((s-1))]}"

  while true; do
    cls; header "Editando: $nom"
    ui_top "AHORA MISMO"
    ui_row "Escucha"   "$(px_campo "$nom" 2):$(px_campo "$nom" 3)"
    ui_row "Entrega a" "$(px_campo "$nom" 4):$(px_campo "$nom" 5) $(que_es "$(px_campo "$nom" 5)")"
    ui_row "Respuesta" "$(px_campo "$nom" 6)"
    ui_row "ACME"      "$(px_campo "$nom" 7)"
    ui_bottom
    echo ""
    ui_top "CAMBIAR"
    ui_item       "1" "Puerto de escucha"
    ui_item       "2" "Puerto de destino"
    ui_item       "3" "Cabecera de respuesta"
    ui_item       "4" "Descripcion"
    ui_item_quiet "0" "Volver y aplicar"
    ui_bottom
    ui_prompt; read -r s

    case "$s" in
      1) local eh ep
         pedir_escucha eh ep "$nom" && { px_set "$nom" 2 "$eh"; px_set "$nom" 3 "$ep"; ok "Escucha: $eh:$ep"; }
         sleep 1 ;;
      2) local dp
         if pedir_destino dp "$(px_campo "$nom" 5)"; then
           px_set "$nom" 5 "$dp"; ok "Entrega a 127.0.0.1:$dp $(que_es "$dp")"
         fi
         sleep 1 ;;
      3) local r; pedir_respuesta r; px_set "$nom" 6 "$r"; ok "Respuesta: $r"; sleep 1 ;;
      4) echo ""; read -rp "   Descripcion: " d; d="${d//|/ }"
         [[ -n "$d" ]] && { px_set "$nom" 8 "$d"; ok "Guardada"; }; sleep 1 ;;
      0) aplicar; pause; return ;;
      *) err "Invalido"; sleep 1 ;;
    esac
  done
}

accion_borrar() {
  cls; header "Puertos" "Eliminar"

  local -a lista=()
  mapfile -t lista < <(px_nombres)
  (( ${#lista[@]} == 0 )) && { warn "No hay proxies."; pause; return; }

  ui_top "ELEGIR"
  local i=1 n
  for n in "${lista[@]}"; do
    ui_item "$i" "$(printf '%-8s %s' "$n" "$(px_campo "$n" 8)")" "$C_WARN"
    ((i++))
  done
  ui_item_quiet "0" "Volver"
  ui_bottom
  ui_prompt; local s; read -r s
  [[ "$s" == "0" || -z "$s" ]] && return
  valid_number "$s" && (( s >= 1 && s <= ${#lista[@]} )) || { err "Invalido"; sleep 1; return; }

  local nom="${lista[$((s-1))]}"
  echo ""
  warn "Los clientes que usen el puerto $(px_campo "$nom" 3) dejaran de conectar."
  ask_yes "   ¿Eliminar '$nom'? (s/N):" n || { info "Cancelado"; pause; return; }

  px_del "$nom"
  aplicar
  pause
}

# --- Puertos de los servicios -----------------------------------------
# Los proxies son solo la mitad: SSH, Dropbear, stunnel, nginx, BadVPN y
# SlowDNS tambien tienen puerto, y cambiarlos a mano en ports.conf es como
# se acaba con el panel diciendo una cosa y el servidor haciendo otra.
tabla_servicios() {
  load_ports
  cls
  header "Puertos" "Servicios"

  printf " %b%-14s %-16s %s%b\n" "$C_MUTED$C_BOLD" "SERVICIO" "PUERTO(S)" "PARA QUE" "$C_RESET"
  ui_hr
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_TEXT" "OpenSSH"  "$C_RESET" "$SSH_PORT" \
    "$C_DIM" "SSH directo" "$C_RESET"
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_TEXT" "Dropbear"  "$C_RESET" "$DROPBEAR_PORT1, $DROPBEAR_PORT2" \
    "$C_DIM" "destino de los proxies" "$C_RESET"
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_TEXT" "nginx TLS" "$C_RESET" "$TLS_PORT" \
    "$C_DIM" "WSS + VMess/VLESS/Trojan" "$C_RESET"
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_TEXT" "stunnel"   "$C_RESET" "$STUNNEL_PORT" \
    "$C_DIM" "modo SSH + SSL crudo" "$C_RESET"
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_TEXT" "SlowDNS"   "$C_RESET" "53 udp -> $SLOWDNS_PORT" \
    "$C_DIM" "tunel por DNS" "$C_RESET"
  printf " %b%-14s%b %-16s %b%s%b\n" "$C_ACCENT2" "BadVPN UDPGW" "$C_RESET" "$BADVPN_PORTS" \
    "$C_DIM" "UDP dentro del tunel" "$C_RESET"
  ui_hr
  printf " %bBadVPN escucha en 127.0.0.1: no se abre al exterior, se alcanza%b\n" "$C_DIM" "$C_RESET"
  printf " %bDENTRO del tunel. En el cliente va como 127.0.0.1:<puerto>.%b\n" "$C_DIM" "$C_RESET"
}

cambiar_badvpn() {
  cls; header "Puertos" "BadVPN"
  info "Son los que el cliente escribe en su campo UDPGW."
  info "Varios puertos = varias instancias; con una suele bastar."
  echo ""
  ui_field "Ahora" "$BADVPN_PORTS"
  echo ""
  info "Escribe los puertos separados por espacios (ej: 7100 7200 7300)"
  read -rp "   Puertos: " nuevos
  [[ -z "$nuevos" ]] && { info "Cancelado"; pause; return; }

  local p limpios=""
  for p in $nuevos; do
    if ! valid_port "$p"; then
      err "'$p' no es un puerto valido"; pause; return
    fi
    local q; q=$(px_quien_usa "$p")
    if [[ -n "$q" && "$q" != "badvpn-udpgw" ]]; then
      warn "El puerto $p lo usa '$q'"
      ask_yes "   ¿Usarlo igualmente? (s/N):" n || { info "Cancelado"; pause; return; }
    fi
    limpios+="$p "
  done

  BADVPN_PORTS="${limpios% }"
  save_ports
  echo ""
  badvpn_apply
  echo ""
  ok "BadVPN ahora en: $BADVPN_PORTS"
  warn "Las fichas ya repartidas llevan el puerto viejo: reenvialas con"
  warn "  menu -> Cuentas -> Ver configuracion"
  pause
}

cambiar_dropbear() {
  cls; header "Puertos" "Dropbear"
  info "Es el destino al que entregan los proxies de payload."
  echo ""
  ui_field "Ahora" "$DROPBEAR_PORT1, $DROPBEAR_PORT2"
  echo ""

  local p1 p2
  ask_valid p1 "   Puerto principal [$DROPBEAR_PORT1]: " valid_port
  ask_valid p2 "   Puerto secundario [$DROPBEAR_PORT2]: " valid_port
  [[ "$p1" == "$p2" ]] && { err "Tienen que ser distintos"; pause; return; }

  local viejo="$DROPBEAR_PORT1"
  DROPBEAR_PORT1="$p1"; DROPBEAR_PORT2="$p2"
  save_ports

  cat > /etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=$p1
DROPBEAR_EXTRA_ARGS="-p $p2"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
  systemctl restart dropbear >/dev/null 2>&1 \
    && ok "Dropbear escuchando en $p1 y $p2" \
    || err "Dropbear no arranco (journalctl -u dropbear -n 20)"

  # Los proxies que apuntaban al puerto viejo quedarian entregando a un
  # puerto muerto: el panel diria "activo" y no conectaria nadie.
  local afectados
  afectados=$(px_list | awk -F'|' -v v="$viejo" '$5==v {print $1}' | tr '\n' ' ')
  if [[ -n "$afectados" ]]; then
    echo ""
    warn "Estos proxies seguian apuntando al $viejo: $afectados"
    if ask_yes "   ¿Reapuntarlos al $p1? (S/n):" s; then
      local n
      for n in $afectados; do px_set "$n" 5 "$p1"; done
      px_apply
    fi
  fi

  bash "$NEXO_INSTALL/config/firewall.sh" apply >/dev/null 2>&1
  ok "Firewall reaplicado"
  pause
}

cambiar_simple() {
  local etiqueta="$1" var="$2" aplicar_cmd="$3" aviso="${4:-}"
  cls; header "Puerto de $etiqueta"
  [[ -n "$aviso" ]] && { warn "$aviso"; echo ""; }
  ui_field "Ahora" "${!var}"
  echo ""

  local p
  ask_valid p "   Nuevo puerto: " valid_port
  local q; q=$(px_quien_usa "$p")
  if [[ -n "$q" ]]; then
    warn "El puerto $p lo tiene ocupado: $q"
    ask_yes "   ¿Usarlo igualmente? (s/N):" n || { info "Cancelado"; pause; return; }
  fi

  printf -v "$var" '%s' "$p"
  save_ports
  echo ""
  info "Aplicando..."
  eval "$aplicar_cmd"
  bash "$NEXO_INSTALL/config/firewall.sh" apply >/dev/null 2>&1
  ok "$etiqueta en el puerto $p, firewall reaplicado"
  warn "Si tu VPS esta en AWS o similar, abre tambien el $p en el proveedor."
  pause
}

menu_servicios() {
  while true; do
    tabla_servicios
    echo ""
    ui_top "CAMBIAR"
    ui_item       "1" "BadVPN UDPGW"        "$C_ACCENT2"
    ui_item       "2" "Dropbear"
    ui_item       "3" "nginx TLS (443)"
    ui_item       "4" "stunnel (SSL crudo)"
    ui_item       "5" "SlowDNS (interno)"
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_prompt; local s; read -r s
    case "$s" in
      1) cambiar_badvpn ;;
      2) cambiar_dropbear ;;
      3) cambiar_simple "nginx TLS" TLS_PORT \
           "bash \"$NEXO_INSTALL/core/nginx.sh\" apply" \
           "Aqui viven el WSS y todo Xray: al cambiarlo hay que rehacer las fichas." ;;
      4) cambiar_simple "stunnel" STUNNEL_PORT \
           "bash \"$NEXO_INSTALL/core/stunnel.sh\" apply" ;;
      5) cambiar_simple "SlowDNS" SLOWDNS_PORT \
           "bash \"$NEXO_INSTALL/core/slowdns.sh\" apply" \
           "Es el puerto interno; de cara a fuera SlowDNS siempre es el 53 udp." ;;
      0) return ;;
      *) err "Invalido"; sleep 1 ;;
    esac
  done
}

# --- Menu --------------------------------------------------------------
while true; do
  tabla
  echo ""
  ui_top "ACCIONES"
  ui_item       "1" "Nuevo proxy"
  ui_item       "2" "Editar uno"
  ui_item       "3" "Eliminar uno"          "$C_WARN"
  ui_blank
  ui_item       "4" "Puertos de servicios (BadVPN, Dropbear...)" "$C_ACCENT2"
  ui_item       "5" "Reaplicar todo"
  ui_item       "6" "Ver el fichero de configuracion"
  ui_item_quiet "0" "Volver"
  ui_bottom

  ui_prompt; read -r op; op="${op//[[:space:]]/}"
  case "$op" in
    1) accion_nuevo ;;
    2) accion_editar ;;
    3) accion_borrar ;;
    4) menu_servicios ;;
    5) cls; header "Reaplicando"; aplicar; badvpn_apply; pause ;;
    6) cls; header "proxies.conf"
       echo "  $PROXIES_CONF"; echo ""
       sed 's/^/  /' "$PROXIES_CONF"; pause ;;
    0) exit 0 ;;
    *) printf " %b✗ Opcion invalida%b\n" "$C_ERR" "$C_RESET"; sleep 0.7 ;;
  esac
done
