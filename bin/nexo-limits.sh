#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Control de multi-login
#
# Lo llama el timer nexo-limits.timer cada minuto. Por cada cuenta con
# limite definido, mata las sesiones SOBRANTES empezando por las mas
# nuevas, para no echar al que lleva conectado desde el principio.
#
# El limite vive en users.json (campo "limit"), no en un fichero aparte:
# asi renovar o editar la cuenta no deja limites huerfanos.
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"

[[ $EUID -ne 0 ]] && exit 1

LOG="$NEXO_LOG/limits.log"
mkdir -p "$NEXO_LOG"

command -v jq >/dev/null 2>&1 || exit 0
db_init

# Una sola foto de las sesiones para todo el recorrido: este script se
# ejecuta cada minuto y antes lanzaba dos `ps` por cada cuenta existente.
declare -A SES
load_sessions SES

while IFS='|' read -r user exp limite uuid; do
  [[ -z "$user" ]] && continue
  [[ "$limite" =~ ^[0-9]+$ ]] || continue
  (( limite < 1 )) && continue

  actual=${SES[$user]:-0}
  (( actual <= limite )) && continue

  sobran=$(( actual - limite ))
  echo "$(date '+%F %T') $user: $actual sesiones, limite $limite, cortando $sobran" >> "$LOG"

  # session_pids devuelve las mas nuevas primero
  while read -r pid; do
    (( sobran <= 0 )) && break
    [[ -z "$pid" ]] && continue
    kill -9 "$pid" 2>/dev/null && sobran=$(( sobran - 1 ))
  done < <(session_pids "$user")
done < <(db_table)

# Rotacion simple: el log no debe crecer sin control en un VPS pequeño
if [[ -f "$LOG" ]] && (( $(stat -c %s "$LOG" 2>/dev/null || echo 0) > 1048576 )); then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

exit 0
