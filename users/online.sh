#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Quien esta conectado
#
# Dos fuentes distintas, porque los transportes son distintos:
#   - SSH/Dropbear: se ven como procesos, uno por sesion
#   - Xray (VMess/VLESS/Trojan): no hay proceso por usuario; se cuenta a
#     partir del access.log, que registra el 'email' (= nombre de cuenta)
#     de cada conexion aceptada.
# Si el log de Xray esta desactivado, esa columna sale vacia: es
# informacion que simplemente no existe, no un error.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
need_root
db_init

XLOG="/var/log/xray/access.log"
VENTANA=300   # segundos que se considera "reciente" en el log de Xray

cls; header "Cuentas" "Conectados"

# --- SSH / Dropbear ----------------------------------------------------
ui_thead "POR SSH  (payload, WebSocket, TLS, SlowDNS)"
declare -A SES
load_sessions SES

HAY=0
while IFS='|' read -r u exp lim uuid; do
  [[ -z "$u" ]] && continue
  n=${SES[$u]:-0}
  (( n == 0 )) && continue
  HAY=1
  if (( n > lim )); then
    printf " %s %b%-15s%b %b%s de %s%b  %bpasado de limite%b\n" \
      "$(ui_dot_err)" "$C_TEXT" "$(ui_fit "$u" 15)" "$C_RESET" \
      "$C_ERR" "$n" "$lim" "$C_RESET" "$C_DIM" "$C_RESET"
  else
    printf " %s %b%-15s%b %b%s de %s%b\n" \
      "$(ui_dot_ok)" "$C_TEXT" "$(ui_fit "$u" 15)" "$C_RESET" \
      "$C_OK" "$n" "$lim" "$C_RESET"
  fi
done < <(db_table)
(( HAY == 0 )) && ui_vacio "Nadie conectado por SSH ahora mismo."

# --- Xray --------------------------------------------------------------
echo ""
ui_thead "POR V2RAY  (VMess / VLESS / Trojan, ultimos $((VENTANA/60)) min)"
if [[ -r "$XLOG" ]]; then
  DESDE=$(date -d "-$VENTANA seconds" '+%Y/%m/%d %H:%M:%S')
  # El access.log de Xray empieza por "AAAA/MM/DD HH:MM:SS", asi que una
  # comparacion de cadenas basta para filtrar por tiempo.
  RES=$(awk -v desde="$DESDE" '
      { ts = $1 " " $2 }
      ts >= desde {
        for (i = 1; i <= NF; i++)
          if ($i == "email:") { print $(i+1); break }
      }' "$XLOG" 2>/dev/null | sort | uniq -c | sort -rn)
  if [[ -n "$RES" ]]; then
    echo "$RES" | while read -r n u; do
      printf " %s %b%-15s%b %b%s conexiones%b\n" \
        "$(ui_dot_ok)" "$C_TEXT" "$(ui_fit "$u" 15)" "$C_RESET" \
        "$C_OK" "$n" "$C_RESET"
    done
  else
    ui_vacio "Nadie por V2Ray en la ultima ventana."
  fi
else
  ui_vacio "Xray no esta guardando access.log." \
           "Sin ese registro no se puede saber quien esta por V2Ray."
fi

# --- Resumen del sistema ----------------------------------------------
echo ""
ui_thead "CARGA"
printf " %bcarga  %s%b\n" "$C_MUTED" "$(cut -d' ' -f1-3 /proc/loadavg)" "$C_RESET"
printf " %bconex. TCP establecidas: %s%b\n" "$C_MUTED" \
  "$(ss -tn state established 2>/dev/null | tail -n +2 | wc -l)" "$C_RESET"

pause
