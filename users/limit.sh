#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Limite de conexiones simultaneas
#
# El limite solo se puede aplicar de verdad a SSH/Dropbear, donde cada
# sesion es un proceso identificable. En VMess/VLESS/Trojan no hay un
# proceso por usuario: Xray multiplexa, y limitar ahi requeriria contar
# conexiones en el access.log y cortar por IP, que da mas falsos positivos
# que otra cosa (una casa con wifi compartido dispara el contador).
# Por eso este limite se documenta como lo que es: control de multi-login
# del lado SSH.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
need_root
db_init

cls; header "Cuentas" "Limite"

pick_user USUARIO "ELEGIR CUENTA" || { pause; exit 0; }

ACTUAL=$(db_get "$USUARIO" limit)
AHORA=$(count_sessions "$USUARIO")

echo ""
ui_field "Usuario"  "$USUARIO"
ui_field "Limite"   "$ACTUAL"
ui_field "Sesiones" "$AHORA"
echo ""

ask_valid NUEVO "Nuevo limite (1-100): " valid_number
if (( NUEVO < 1 || NUEVO > 100 )); then err "Fuera de rango"; pause; exit 1; fi

db_set "$USUARIO" limit "$NUEVO"
ok "Limite de '$USUARIO': $ACTUAL -> $NUEVO"

if (( AHORA > NUEVO )); then
  echo ""
  warn "Ahora mismo tiene $AHORA sesiones abiertas."
  if ask_yes "¿Cortar las sobrantes ya? (s/n):" s; then
    bash "$NEXO_INSTALL/bin/nexo-limits.sh"
    ok "Aplicado"
  else
    info "El timer nexo-limits lo hara en menos de un minuto."
  fi
fi

pause
