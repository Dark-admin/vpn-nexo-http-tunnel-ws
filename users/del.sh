#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Eliminar cuenta
#
# Hay que borrarla de los cuatro sitios o la cuenta "medio vive":
#   sesiones abiertas -> /etc/passwd -> users.json -> Xray
# Si se olvida Xray, el UUID sigue navegando aunque el SSH ya no exista.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
need_root
db_init

cls; header "Cuentas" "Eliminar"

pick_user USUARIO "ELEGIR CUENTA" || { pause; exit 0; }

echo ""
ui_field "Usuario" "$USUARIO"
ui_field "Expira"  "$(db_get "$USUARIO" exp)"
ui_field "Sesiones" "$(count_sessions "$USUARIO")"
echo ""
warn "Se cortaran sus conexiones y se borrara de SSH y de Xray."
ask_yes "¿Confirmar borrado? (s/n):" n || { info "Cancelado"; pause; exit 0; }

# 1. Cortar sesiones
while read -r pid; do
  [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
done < <(session_pids "$USUARIO")
pkill -u "$USUARIO" 2>/dev/null

# 2. Sistema
userdel -f "$USUARIO" 2>/dev/null

# 3. Panel
db_del "$USUARIO"

# 4. Xray
bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1

# 5. Ficheros generados
rm -rf "${NEXO_OUT:?}/$USUARIO"

# Timer de prueba, si lo tenia
systemctl stop "nexo-trial-$USUARIO.timer" >/dev/null 2>&1

echo ""
ok "Cuenta '$USUARIO' eliminada"
pause
