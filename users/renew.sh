#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Renovar cuenta
#
# Los dias se suman a la fecha de expiracion ACTUAL si aun no ha pasado, y
# a hoy si ya vencio. Sumar siempre a hoy regalaria dias al que renueva
# antes de tiempo; sumar siempre a la fecha vieja dejaria vencida una
# cuenta que se acaba de pagar.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
source "$NEXO_INSTALL/lib/gen.sh"
need_root
db_init

cls; header "Cuentas" "Renovar"

pick_user USUARIO "ELEGIR CUENTA" || { pause; exit 0; }

EXP_ACTUAL=$(db_get "$USUARIO" exp)
echo ""
ui_field "Usuario" "$USUARIO"
ui_field "Expira"  "$EXP_ACTUAL ($(days_left "$EXP_ACTUAL") dias)"
echo ""

ask_valid DIAS "Dias a añadir: " valid_number
if (( DIAS < 1 || DIAS > 3650 )); then err "Rango: 1-3650"; pause; exit 1; fi

HOY=$(date +%Y-%m-%d)
BASE="$EXP_ACTUAL"
if [[ -z "$BASE" || "$BASE" < "$HOY" ]]; then
  BASE="$HOY"
  info "La cuenta estaba vencida: se cuenta desde hoy."
fi

NUEVA=$(date -d "$BASE +$DIAS days" +%Y-%m-%d 2>/dev/null) \
  || { err "No se pudo calcular la fecha"; pause; exit 1; }

# El usuario del sistema puede haber sido borrado por el timer de vencidas
if id "$USUARIO" &>/dev/null; then
  usermod -e "$NUEVA" "$USUARIO" 2>/dev/null \
    || warn "No se pudo actualizar la expiracion en el sistema"
else
  warn "El usuario del sistema ya no existia: se recrea"
  PASS=$(db_get "$USUARIO" pass)
  useradd -e "$NUEVA" -s /bin/false -M "$USUARIO" 2>/dev/null \
    && echo "$USUARIO:$PASS" | chpasswd \
    && ok "Usuario SSH restaurado"
fi

db_set "$USUARIO" exp "$NUEVA"
bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1
gen_files "$USUARIO" >/dev/null

echo ""
ok "Renovada hasta $NUEVA ($(days_left "$NUEVA") dias)"
pause
