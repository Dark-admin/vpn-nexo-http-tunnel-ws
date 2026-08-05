#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Panel
#
# Navegacion con bucles anidados, no con recursion: llamar a `menu` al
# final de cada opcion (como hacen muchos paneles) apila un proceso bash
# nuevo por cada pantalla y acaba comiendose la RAM del VPS.
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
if [[ -f "$NEXO_INSTALL/lib/common.sh" ]]; then
  source "$NEXO_INSTALL/lib/common.sh"
  source "$NEXO_INSTALL/lib/db.sh"
else
  _D="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  source "$_D/lib/common.sh"; source "$_D/lib/db.sh"
fi

need_root
db_init

run_user() { bash "$NEXO_INSTALL/users/$1.sh" "${@:2}"; }
run_core() { bash "$NEXO_INSTALL/core/$1.sh"  "${@:2}"; }

leer_opcion() {
  ui_prompt
  read -r opcion
  opcion="${opcion//[[:space:]]/}"
  # Atajos: nadie recuerda que "volver" es el 0, pero todo el mundo prueba
  # con q o con b. Se aceptan y se traducen al 0 de siempre.
  case "${opcion,,}" in
    q|b|v|atras|volver|salir) opcion="0" ;;
  esac
}

# --- Resumenes para las pistas del menu --------------------------------
# Lista de unidades que componen "el servicio" del panel
unidades_panel() {
  echo ssh dropbear nginx stunnel4 xray nexo-slowdns fail2ban $(px_unidades)
}

# Servicios vivos frente a los instalados: "9/9" o "7/9".
# Una sola llamada a systemd para todas (ver estado_unidades en common.sh).
resumen_servicios() {
  local activos=0 total=0 id existe activa
  while IFS='|' read -r id existe activa; do
    [[ "$existe" == "si" ]] || continue
    total=$(( total + 1 ))
    [[ "$activa" == "si" ]] && activos=$(( activos + 1 ))
  done < <(estado_unidades $(unidades_panel))
  echo "$activos/$total"
}

# Cuentas: total, en linea y las que vencen pronto
resumen_cuentas() {
  local total online pronto=0 u exp limite
  total=$(db_count); total="${total:-0}"
  (( total == 0 )) && { echo "sin cuentas|0|0"; return; }

  # La fecha limite se calcula UNA vez y luego se comparan cadenas: las
  # fechas son YYYY-MM-DD, que ordenan igual como texto que como fecha.
  # Antes se llamaba a days_left por cuenta, y eso era un `date` por
  # cabeza en cada redibujado del menu.
  limite=$(date -d "+3 days" +%Y-%m-%d 2>/dev/null)

  local -A ses
  load_sessions ses
  online=0
  while IFS='|' read -r u exp _l _uuid; do
    [[ -z "$u" ]] && continue
    (( ${ses[$u]:-0} > 0 )) && online=$(( online + 1 ))
    [[ -n "$limite" && "$exp" < "$limite" ]] && pronto=$(( pronto + 1 ))
  done < <(db_table)
  echo "$total|$online|$pronto"
}

opcion_invalida() {
  printf " %b✗ Opcion invalida%b\n" "$C_ERR" "$C_RESET"
  sleep 0.7
}

# --- Panel de sistema --------------------------------------------------
panel_sistema() {
  local ip ram_t ram_u ram_pct dsk_pct dsk_det up dom srv act tot est

  ip=$(get_ip)
  dom=$(get_domain)
  ram_t=$(free -m | awk '/^Mem:/ {print $2}')
  ram_u=$(free -m | awk '/^Mem:/ {print $3}')
  ram_pct=$(awk -v u="$ram_u" -v t="$ram_t" 'BEGIN{printf "%d", (t>0? u/t*100 : 0)}')
  dsk_pct=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  dsk_det=$(df -h / | awk 'NR==2 {print $3"/"$2}')
  up=$(uptime -p 2>/dev/null | sed 's/^up //; s/ hours\?/h/; s/ minutes\?/m/; s/ days\?/d/; s/,//g')

  srv=$(resumen_servicios); act="${srv%/*}"; tot="${srv#*/}"

  ui_top "ESTADO"
  # Lo primero que se ve: ¿esta todo en pie o no? Antes habia que entrar
  # en tres pantallas distintas para saberlo.
  if [[ "$act" == "$tot" ]]; then
    ui_estado ok   "Todo operativo"        "$act de $tot servicios"
  elif (( act == 0 )); then
    ui_estado err  "Nada esta corriendo"   "$act de $tot servicios"
  else
    ui_estado warn "Hay servicios caidos"  "$act de $tot servicios"
  fi
  ui_sep
  ui_row "HOST"   "${dom:-$ip}" "$C_ACCENT2"
  ui_row_bar "RAM"   "$ram_pct" "${ram_u}/${ram_t}M"
  ui_row_bar "DISCO" "$dsk_pct" "$dsk_det"
  ui_row "ACTIVO" "${up:-n/d}"
  ui_bottom
}

# --- Menu principal ----------------------------------------------------
main_menu() {
  local rc total online pronto hint_cuentas hint_payload srv
  while true; do
    ui_clear
    echo ""
    ui_logo
    echo ""
    panel_sistema
    echo ""

    rc=$(resumen_cuentas)
    if [[ "$rc" == sin* ]]; then
      hint_cuentas="ninguna aun"
    else
      total="${rc%%|*}"; online=$(echo "$rc" | cut -d'|' -f2); pronto="${rc##*|}"
      hint_cuentas="$total · $online en linea"
      (( pronto > 0 )) && hint_cuentas="$total · $pronto vencen ya"
    fi

    load_payload
    if [[ -n "$BUG_HOST" ]]; then
      hint_payload="$BUG_HOST"
    elif [[ -n "$SNI_HOST" ]]; then
      hint_payload="$SNI_HOST"
    else
      hint_payload="sin definir"
    fi

    srv=$(resumen_servicios)

    ui_top "MENU"
    ui_group "DIA A DIA"
    ui_opt        "1" "Cuentas"            "$hint_cuentas"
    ui_opt        "2" "Payload / Bug / SNI" "$hint_payload" "$C_ACCENT2"
    ui_opt        "3" "Puertos y proxies"  "$(px_list | wc -l) proxies"
    ui_sep
    ui_group "SISTEMA"
    ui_opt        "4" "Servicios"          "$srv"
    ui_opt        "5" "Configuracion"      ""
    ui_opt        "6" "Apagar / Reiniciar" "" "$C_ERR"
    ui_item_quiet "0" "Salir"
    ui_bottom
    ui_keys " 0 o q  salir"

    leer_opcion
    case "$opcion" in
      1) menu_cuentas ;;
      2) run_core payload ;;
      3) run_core puertos ;;
      4) menu_transportes ;;
      5) menu_config ;;
      6) menu_peligro ;;
      0) ui_clear; exit 0 ;;
      *) opcion_invalida ;;
    esac
  done
}

# --- Cuentas -----------------------------------------------------------
menu_cuentas() {
  local rc total online pronto
  while true; do
    ui_clear; echo ""
    ui_crumbs "Cuentas"
    echo ""

    rc=$(resumen_cuentas)
    if [[ "$rc" == sin* ]]; then
      total=0; online=0; pronto=0
    else
      total="${rc%%|*}"; online=$(echo "$rc" | cut -d'|' -f2); pronto="${rc##*|}"
    fi

    ui_top "CUENTAS"
    if (( total == 0 )); then
      ui_estado off "Aun no hay cuentas" "empieza por la 1"
    elif (( pronto > 0 )); then
      ui_estado warn "$pronto vencen en 3 dias o menos" "$total en total"
    else
      ui_estado ok "$total cuentas al dia" "$online en linea"
    fi
    ui_sep
    ui_group "CREAR Y RENOVAR"
    ui_opt        "1" "Crear cuenta"          "completa"
    ui_opt        "2" "Cuenta de prueba"      "por horas"
    ui_opt        "3" "Renovar"               ""
    ui_sep
    ui_group "CONSULTAR"
    ui_opt        "4" "Configuracion / QR"    "reenviar" "$C_ACCENT2"
    ui_opt        "5" "Listar todas"          "$total"
    ui_opt        "6" "Quien esta conectado"  "$online"
    ui_sep
    ui_group "MANTENIMIENTO"
    ui_opt        "7" "Cambiar limite"        ""
    ui_opt        "8" "Eliminar cuenta"       "" "$C_WARN"
    ui_opt        "9" "Limpiar vencidas"      "" "$C_WARN"
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " 0 o q  volver"

    leer_opcion
    case "$opcion" in
      1) run_user add ;;    2) run_user trial ;;  3) run_user renew ;;
      4) run_user show ;;   5) run_user list ;;   6) run_user online ;;
      7) run_user limit ;;  8) run_user del ;;
      9) ui_clear; echo ""; ui_crumbs "Cuentas" "Limpiar vencidas"; echo ""
         info "Buscando cuentas caducadas..."
         bash "$NEXO_INSTALL/bin/nexo-expire.sh"
         ok "Hecho"; pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

# --- Transportes -------------------------------------------------------
menu_transportes() {
  while true; do
    load_ports; load_payload
    ui_clear; echo ""
    ui_top "PUERTOS"
    ui_row "OpenSSH"   "$SSH_PORT"
    ui_row "Dropbear"  "$DROPBEAR_PORT1, $DROPBEAR_PORT2"
    local pl; pl=$(px_puertos_publicos | tr '\n' ' ')
    ui_row "Payload"   "${pl:-(ninguno)}"                   "$C_ACCENT2"
    ui_row "TLS/nginx" "$TLS_PORT  wss$WS_PATH + xray"      "$C_ACCENT2"
    ui_row "SSL crudo" "$STUNNEL_PORT"
    ui_row "SlowDNS"   "53 udp -> $SLOWDNS_PORT"
    ui_row "BadVPN"    "interno (en el tunel)" "$C_DIM"
    ui_bottom
    echo ""
    ui_top "SERVICIOS"
    ui_group "GENERAL"
    ui_opt        "1" "Puertos y proxies"   "editar" "$C_ACCENT2"
    ui_opt        "2" "Estado de todo"      "$(resumen_servicios)"
    ui_opt        "3" "Reiniciar servicios" ""
    ui_sep
    ui_group "POR TRANSPORTE"
    ui_opt        "4" "Nginx / TLS"   "$(is_active nginx        && echo activo || echo parado)"
    ui_opt        "5" "Xray"          "$(is_active xray         && echo activo || echo parado)"
    ui_opt        "6" "SlowDNS"       "$(is_active nexo-slowdns && echo activo || echo apagado)"
    ui_opt        "7" "Stunnel"       "$(is_active stunnel4     && echo activo || echo parado)"
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " 0 o q  volver"

    leer_opcion
    case "$opcion" in
      1) run_core puertos ;;
      2) estado_servicios ;;
      3) reiniciar_servicios ;;
      4) menu_simple "Nginx" nginx ;;
      5) menu_xray ;;
      6) menu_slowdns ;;
      7) menu_simple "Stunnel" stunnel ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

# Pantalla generica estado/reaplicar para modulos con esas dos acciones
menu_simple() {
  local titulo="$1" script="$2"
  while true; do
    ui_clear; echo ""
    ui_crumbs "Servicios" "$titulo"
    echo ""
    ui_top "${titulo^^}"
    ui_opt        "1" "Ver estado"             ""
    ui_opt        "2" "Reaplicar configuracion" ""
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " 0 o q  volver"
    leer_opcion
    case "$opcion" in
      1) ui_clear; run_core "$script" status; pause ;;
      2) ui_clear; run_core "$script" apply;  pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

menu_xray() {
  while true; do
    ui_clear; echo ""
    ui_top "XRAY"
    ui_item       "1" "Ver estado"
    ui_item       "2" "Sincronizar cuentas"
    ui_item       "3" "Instalar / actualizar"
    ui_item_quiet "0" "Volver"
    ui_bottom
    leer_opcion
    case "$opcion" in
      1) ui_clear; run_core xray status;  pause ;;
      2) ui_clear; run_core xray sync;    pause ;;
      3) ui_clear; run_core xray install; pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

menu_slowdns() {
  while true; do
    ui_clear; echo ""
    ui_top "SLOWDNS"
    ui_item       "1" "Ver estado y claves"
    ui_item       "2" "Configurar / reconfigurar"
    ui_item       "3" "Desactivar"            "$C_WARN"
    ui_item_quiet "0" "Volver"
    ui_bottom
    leer_opcion
    case "$opcion" in
      1) ui_clear; run_core slowdns status; pause ;;
      2) ui_clear; run_core slowdns apply;  pause ;;
      3) ui_clear; run_core slowdns remove; pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

estado_servicios() {
  ui_clear; echo ""
  ui_top "SERVICIOS"
  local units=()
  # shellcheck disable=SC2206
  units+=($(unidades_panel))
  for p in $BADVPN_PORTS; do units+=("badvpn-$p"); done

  # Todas de una vez: antes eran dos llamadas a systemctl por unidad y con
  # una decena de servicios la pantalla tardaba segundos en aparecer.
  local id existe activa
  while IFS='|' read -r id existe activa; do
    if [[ "$existe" != "si" ]]; then
      ui_status_row "$id" off "no instalado"
    elif [[ "$activa" == "si" ]]; then
      ui_status_row "$id" ok "activo"
    else
      ui_status_row "$id" err "detenido"
    fi
  done < <(estado_unidades "${units[@]}")
  ui_sep
  for t in nexo-expire nexo-limits; do
    if systemctl is-active "$t.timer" >/dev/null 2>&1; then
      ui_status_row "$t" ok "programado"
    else
      ui_status_row "$t" warn "inactivo"
    fi
  done
  ui_bottom

  echo ""
  ui_thead "PUERTOS A LA ESCUCHA"
  ss -tlnH 2>/dev/null | awk '{split($4,a,":"); print a[length(a)]}' \
    | sort -un | tr '\n' ' ' | fold -s -w $(( UI_W - 3 )) | sed 's/^/ /'
  echo ""
  ss -ulnH 2>/dev/null | awk '{split($4,a,":"); print "udp/"a[length(a)]}' \
    | sort -u | tr '\n' ' ' | fold -s -w $(( UI_W - 3 )) | sed 's/^/ /'
  pause
}

reiniciar_servicios() {
  ui_clear; echo ""
  header "Reiniciando servicios"
  for u in ssh dropbear $(px_unidades) nginx stunnel4 xray nexo-slowdns fail2ban; do
    hay_unidad "$u" || continue
    if systemctl restart "$u" >/dev/null 2>&1; then
      ok "$u"
    else
      err "$u no arranco (revisa: journalctl -u $u -n 30)"
    fi
  done
  for p in $BADVPN_PORTS; do systemctl restart "badvpn-$p" >/dev/null 2>&1; done
  pause
}

# --- Configuracion -----------------------------------------------------
menu_config() {
  while true; do
    ui_clear; echo ""
    ui_crumbs "Configuracion"
    echo ""
    local dom; dom=$(get_domain)
    ui_top "CONFIGURACION"
    ui_opt        "1" "Info del sistema"      ""
    ui_opt        "2" "Dominio + certificado" "${dom:-sin dominio}"
    ui_opt        "3" "Firewall"              ""
    ui_opt        "4" "Backup / Restore"      ""
    ui_opt        "5" "Tema de colores"       "$UI_THEME" "$C_ACCENT2"
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " 0 o q  volver"

    leer_opcion
    case "$opcion" in
      1) info_sistema ;;
      2) run_core domain ;;
      3) menu_firewall ;;
      4) menu_backup ;;
      5) menu_tema ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

info_sistema() {
  ui_clear; echo ""
  header "Informacion"
  load_ports; load_payload
  ui_field "SO"        "$(source /etc/os-release; echo "$PRETTY_NAME")"
  ui_field "Kernel"    "$(uname -r)"
  ui_field "Arquit."   "$(uname -m)"
  ui_field "CPU"       "$(nproc) nucleo(s)"
  ui_field "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo ""
  ui_field "IP"        "$(get_ip)"
  ui_field "Dominio"   "$(get_domain || echo '(ninguno)')"
  ui_field "Bug host"  "${BUG_HOST:-(sin definir)}"
  ui_field "SNI"       "${SNI_HOST:-(sin definir)}"
  ui_field "Ruta WS"   "$WS_PATH"
  ui_field "Respuesta" "${HTTP_RESPONSE%%|*}"
  echo ""
  ui_field "Cuentas"   "$(db_count)"
  ui_field "Configs"   "$NEXO_OUT"
  ui_field "Logs"      "$NEXO_LOG"
  pause
}

menu_firewall() {
  while true; do
    ui_clear; echo ""
    ui_top "FIREWALL"
    ui_item       "1" "Ver estado"
    ui_item       "2" "Reaplicar reglas"
    ui_item       "3" "Abrir todo (rescate)" "$C_ERR"
    ui_item_quiet "0" "Volver"
    ui_bottom

    leer_opcion
    case "$opcion" in
      1) ui_clear; bash "$NEXO_INSTALL/config/firewall.sh" status; pause ;;
      2) ui_clear; bash "$NEXO_INSTALL/config/firewall.sh" apply;  pause ;;
      3) echo ""
         warn "Esto deja el VPS SIN firewall."
         read -rp " Escribe RESCATE para confirmar: " cf
         if [[ "$cf" == "RESCATE" ]]; then
           bash "$NEXO_INSTALL/config/firewall.sh" reset
         else
           info "Cancelado"
         fi
         pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

menu_backup() {
  while true; do
    ui_clear; echo ""
    ui_top "BACKUP / RESTORE"
    ui_item       "1" "Crear backup"
    ui_item       "2" "Restaurar backup"
    ui_item       "3" "Listar backups"
    ui_item_quiet "0" "Volver"
    ui_bottom

    leer_opcion
    case "$opcion" in
      1) ui_clear; run_core backup crear;    pause ;;
      2) ui_clear; run_core backup restaurar ;;
      3) ui_clear; run_core backup listar;   pause ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

menu_tema() {
  while true; do
    ui_clear; echo ""
    ui_logo "vista previa del tema: $UI_THEME"
    echo ""
    ui_top "MUESTRA"
    ui_row_bar "BARRA OK"   35 "ejemplo"
    ui_row_bar "BARRA MED"  78 "ejemplo"
    ui_row_bar "BARRA ALTA" 95 "ejemplo"
    ui_sep
    ui_status_row "servicio-ok"  ok   "activo"
    ui_status_row "servicio-err" err  "detenido"
    ui_status_row "servicio-off" off  "no instalado"
    ui_bottom
    echo ""
    ui_top "TEMAS"
    local i=1
    for t in $(ui_themes); do
      if [[ "$t" == "$UI_THEME" ]]; then
        ui_opt "$i" "$t" "<- actual" "$C_OK"
      else
        ui_opt "$i" "$t" "$(ui_theme_desc "$t")"
      fi
      ((i++))
    done
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " el numero aplica el tema al momento · 0 volver"

    leer_opcion
    [[ "$opcion" == "0" ]] && return
    if valid_number "${opcion:-}" && (( opcion >= 1 )); then
      local elegido
      elegido=$(ui_themes | tr ' ' '\n' | sed -n "${opcion}p")
      if [[ -n "$elegido" ]]; then
        ui_save_theme "$elegido"
        continue
      fi
    fi
    opcion_invalida
  done
}

# --- Apagar / reiniciar ------------------------------------------------
menu_peligro() {
  while true; do
    ui_clear; echo ""
    ui_crumbs "Apagar / Reiniciar"
    echo ""
    local rc en_linea; rc=$(resumen_cuentas)
    en_linea=$( [[ "$rc" == sin* ]] && echo 0 || echo "$rc" | cut -d'|' -f2 )
    ui_top "ZONA PELIGROSA"
    if (( en_linea > 0 )); then
      ui_estado err "$en_linea cliente(s) conectados ahora" "se les cortara"
    else
      ui_estado warn "No hay nadie conectado" "buen momento"
    fi
    ui_sep
    ui_opt        "1" "Reiniciar VPS" "" "$C_ERR"
    ui_opt        "2" "Apagar VPS"    "" "$C_ERR"
    ui_item_quiet "0" "Volver"
    ui_bottom
    ui_keys " 0 o q  volver"

    leer_opcion
    case "$opcion" in
      1) echo ""; read -rp " Escribe REINICIAR para confirmar: " c
         if [[ "$c" == "REINICIAR" ]]; then info "Reiniciando..."; reboot; else info "Cancelado"; fi
         sleep 1 ;;
      2) echo ""; read -rp " Escribe APAGAR para confirmar: " c
         if [[ "$c" == "APAGAR" ]]; then info "Apagando..."; poweroff; else info "Cancelado"; fi
         sleep 1 ;;
      0) return ;;
      *) opcion_invalida ;;
    esac
  done
}

main_menu
