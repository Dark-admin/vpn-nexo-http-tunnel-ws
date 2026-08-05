#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Borrado de cuentas vencidas
#
# Lo llama nexo-expire.timer cada hora, y tambien el timer transitorio de
# las cuentas de prueba (con 'purge <usuario>').
#
# Una cuenta hay que quitarla de CUATRO sitios, no solo del sistema:
#   1. sesiones abiertas   (si no, el que ya esta dentro sigue navegando)
#   2. /etc/passwd         (userdel)
#   3. users.json          (base de datos del panel)
#   4. config.json de Xray (clients de vmess/vless/trojan)
# Si se olvida el 4, el UUID sigue funcionando aunque la cuenta SSH ya no
# exista, y el cliente sigue conectado por V2Ray sin pagar.
#
# Uso: nexo-expire.sh [vencidas|purge <usuario>]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"

[[ $EUID -ne 0 ]] && exit 1

LOG="$NEXO_LOG/expire.log"
mkdir -p "$NEXO_LOG"

command -v jq >/dev/null 2>&1 || exit 0
db_init

# borrar_cuenta <usuario> <motivo>  (no toca Xray: eso se hace al final,
# una sola vez, porque cada sync reinicia el servicio)
borrar_cuenta() {
  local user="$1" motivo="$2"

  while read -r pid; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  done < <(session_pids "$user")

  pkill -u "$user" 2>/dev/null
  userdel -f "$user" 2>/dev/null
  db_del "$user"
  rm -rf "${NEXO_OUT:?}/$user"
  systemctl stop "nexo-trial-$user.timer" >/dev/null 2>&1

  echo "$(date '+%F %T') $motivo: $user" >> "$LOG"
}

rotar_log() {
  if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 524288 )); then
    tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

case "${1:-vencidas}" in
  purge)
    USUARIO="${2:-}"
    [[ -z "$USUARIO" ]] && { echo "Uso: $(basename "$0") purge <usuario>"; exit 1; }
    borrar_cuenta "$USUARIO" "prueba caducada"
    bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1
    ;;

  vencidas)
    BORRADAS=0
    while read -r user; do
      [[ -z "$user" ]] && continue
      borrar_cuenta "$user" "vencida y eliminada"
      BORRADAS=$(( BORRADAS + 1 ))
    done < <(db_expired)

    # Un solo sync al final: cada uno reinicia Xray y corta a todos un instante
    if (( BORRADAS > 0 )); then
      bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1
      echo "$BORRADAS cuenta(s) vencida(s) eliminada(s)"
    fi
    ;;

  *)
    echo "Uso: $(basename "$0") [vencidas|purge <usuario>]"
    exit 1
    ;;
esac

rotar_log
exit 0
