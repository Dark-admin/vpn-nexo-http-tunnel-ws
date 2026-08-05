#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Backup y restauracion
#
# El backup NO copia /etc/shadow: copia $NEXO_CONF, y de ahi users.json,
# que ya guarda usuario y clave. Al restaurar se RECREAN las cuentas del
# sistema con useradd + chpasswd. Ventaja: el mismo fichero sirve para
# recuperar el servidor y para MIGRAR a otro VPS, aunque cambie la
# distribucion o el UID de los usuarios.
#
# El .tar.gz queda en modo 600 porque lleva las claves en claro. Trata ese
# fichero como tratarias la lista de clientes: no lo subas a sitios
# publicos.
#
# Uso: backup.sh [crear|restaurar|listar]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
need_root
db_init

BK_DIR="/root/nexotunnel-backups"

crear() {
  mkdir -p "$BK_DIR"; chmod 700 "$BK_DIR"
  local nombre="nexotunnel-$(date +%Y%m%d-%H%M%S).tar.gz"
  local destino="$BK_DIR/$nombre"

  header "Configuracion" "Backup" "Crear"
  info "Empaquetando configuracion y cuentas..."

  # -C / con rutas relativas: asi se puede restaurar en otro servidor
  if tar -czf "$destino" \
        -C / "etc/nexotunnel" \
        $( [[ -f /usr/local/etc/xray/config.json ]] && echo "usr/local/etc/xray/config.json" ) \
        2>/dev/null; then
    chmod 600 "$destino"
    ok "Backup creado"
    echo ""
    ui_field "Fichero" "$destino"
    ui_field "Tamaño"  "$(du -h "$destino" | cut -f1)"
    ui_field "Cuentas" "$(db_count)"
    echo ""
    warn "Contiene las claves en claro. Guardalo en sitio seguro."
    echo ""
    info "Descargalo desde tu PC con:"
    echo "   scp root@$(get_ip):$destino ."
  else
    err "No se pudo crear el backup"
    return 1
  fi
}

listar() {
  header "Configuracion" "Backup" "Listado"
  if [[ ! -d "$BK_DIR" ]] || ! ls "$BK_DIR"/*.tar.gz >/dev/null 2>&1; then
    warn "No hay backups en $BK_DIR"
    return 0
  fi
  printf " %b%-34s %8s%b\n" "$C_MUTED$C_BOLD" "FICHERO" "TAMAÑO" "$C_RESET"
  ui_hr
  local f
  for f in "$BK_DIR"/*.tar.gz; do
    printf " %-34s %8s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  ui_hr
}

restaurar() {
  header "Configuracion" "Backup" "Restaurar"

  local -a lista=()
  mapfile -t lista < <(ls -1t "$BK_DIR"/*.tar.gz 2>/dev/null)
  if (( ${#lista[@]} == 0 )); then
    warn "No hay backups en $BK_DIR"
    info "Sube uno con: scp nexotunnel-*.tar.gz root@$(get_ip):$BK_DIR/"
    pause; return 0
  fi

  ui_top "ELEGIR BACKUP"
  local i=1 f
  for f in "${lista[@]}"; do
    ui_item "$i" "$(basename "$f")"
    ((i++))
  done
  ui_item_quiet "0" "Cancelar"
  ui_bottom

  ui_prompt; local sel; read -r sel; sel="${sel//[[:space:]]/}"
  [[ "$sel" == "0" || -z "$sel" ]] && { info "Cancelado"; pause; return 0; }
  valid_number "$sel" && (( sel >= 1 && sel <= ${#lista[@]} )) \
    || { err "Seleccion invalida"; pause; return 1; }

  local archivo="${lista[$((sel-1))]}"
  echo ""
  warn "Se sobrescribira la configuracion actual y se recrearan las cuentas."
  ask_yes "¿Continuar? (s/n):" n || { info "Cancelado"; pause; return 0; }

  # Red de seguridad: un backup de lo que hay ahora, antes de pisarlo
  info "Guardando el estado actual antes de restaurar..."
  tar -czf "$BK_DIR/antes-de-restaurar-$(date +%s).tar.gz" -C / "etc/nexotunnel" 2>/dev/null
  chmod 600 "$BK_DIR"/antes-de-restaurar-*.tar.gz 2>/dev/null

  info "Extrayendo..."
  tar -xzf "$archivo" -C / || { err "No se pudo extraer"; pause; return 1; }

  load_ports; load_payload
  db_init

  # --- Recrear las cuentas del sistema ---------------------------------
  info "Recreando cuentas..."
  local creadas=0 saltadas=0 u p e
  while IFS='|' read -r u e lim uuid; do
    [[ -z "$u" ]] && continue
    p=$(db_get "$u" pass)
    if id "$u" &>/dev/null; then
      usermod -e "$e" "$u" 2>/dev/null
      echo "$u:$p" | chpasswd 2>/dev/null
      saltadas=$(( saltadas + 1 ))
      continue
    fi
    if useradd -e "$e" -s /bin/false -M "$u" 2>/dev/null \
       && echo "$u:$p" | chpasswd 2>/dev/null; then
      creadas=$(( creadas + 1 ))
    else
      warn "No se pudo recrear '$u'"
    fi
  done < <(db_table)

  ok "$creadas cuenta(s) creada(s), $saltadas actualizada(s)"

  # --- Reaplicar todo lo que depende de la configuracion ---------------
  info "Reaplicando servicios..."
  write_hproxy_env
  bash "$NEXO_INSTALL/core/xray.sh"   sync  >/dev/null 2>&1
  bash "$NEXO_INSTALL/core/nginx.sh"  apply >/dev/null 2>&1
  bash "$NEXO_INSTALL/core/stunnel.sh" apply >/dev/null 2>&1
  restart_hproxy
  bash "$NEXO_INSTALL/config/firewall.sh" apply >/dev/null 2>&1

  echo ""
  ok "Restauracion completada ($(db_count) cuentas)"
  warn "Si vienes de otro VPS, revisa el dominio y vuelve a emitir el"
  warn "certificado: sudo nexo-domain"
  pause
}

case "${1:-listar}" in
  crear)     crear ;;
  listar)    listar ;;
  restaurar) restaurar ;;
  *)         echo "Uso: $(basename "$0") [crear|restaurar|listar]"; exit 1 ;;
esac
