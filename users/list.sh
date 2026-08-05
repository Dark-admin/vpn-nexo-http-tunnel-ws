#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Listado de cuentas
#
# La tabla se imprime FUERA de las cajas de ui.sh: los UUID y las fechas
# no caben en 44 columnas y quedarian cortados. Aqui el ancho lo manda el
# terminal.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
need_root
db_init

cls; header "Cuentas" "Listado"

TOTAL=$(db_count)
if [[ "$TOTAL" == "0" || -z "$TOTAL" ]]; then
  ui_vacio "Todavia no hay ninguna cuenta." \
           "Crea la primera desde:  Cuentas › Crear cuenta"
  pause; exit 0
fi

# Un punto de color por fila: verde = en linea, ambar = le quedan pocos
# dias, rojo = vencida, gris = todo normal y sin nadie dentro. Se lee de
# un vistazo sin tener que interpretar numeros.
printf " %b   %-15s %-11s %5s %4s %3s%b\n" "$C_MUTED$C_BOLD" \
  "USUARIO" "EXPIRA" "DIAS" "LIM" "ON" "$C_RESET"
ui_hr

declare -A SES
load_sessions SES

VENCIDAS=0; ACTIVAS=0; ONLINE=0; PRONTO=0
while IFS='|' read -r u exp lim uuid; do
  [[ -z "$u" ]] && continue
  d=$(days_left "$exp")
  n=${SES[$u]:-0}
  (( n > 0 )) && ONLINE=$(( ONLINE + 1 ))

  if [[ "$d" =~ ^-?[0-9]+$ ]] && (( d < 0 )); then
    col="$C_ERR"; punto=$(ui_dot_err); VENCIDAS=$(( VENCIDAS + 1 ))
  elif [[ "$d" =~ ^-?[0-9]+$ ]] && (( d <= 3 )); then
    col="$C_WARN"; punto=$(ui_dot_warn); PRONTO=$(( PRONTO + 1 )); ACTIVAS=$(( ACTIVAS + 1 ))
  elif (( n > 0 )); then
    col="$C_TEXT"; punto=$(ui_dot_ok); ACTIVAS=$(( ACTIVAS + 1 ))
  else
    col="$C_TEXT"; punto=$(ui_dot_off); ACTIVAS=$(( ACTIVAS + 1 ))
  fi

  if (( n > 0 )); then oncol="$C_OK"; onmark="$n"; else oncol="$C_DIM"; onmark="·"; fi

  printf " %s %b%-15s%b %b%-11s %5s%b %4s %b%3s%b\n" \
    "$punto" \
    "$C_TEXT" "$(ui_fit "$u" 15)" "$C_RESET" \
    "$col" "$exp" "$d" "$C_RESET" \
    "$lim" \
    "$oncol" "$onmark" "$C_RESET"
done < <(db_table)

ui_hr
printf " %b%s%b   %s   %s   %s\n" \
  "$C_TEXT" "$TOTAL cuentas" "$C_RESET" \
  "$(ui_badge ok "$ONLINE en linea")" \
  "$(ui_badge warn "$PRONTO por vencer")" \
  "$(ui_badge err "$VENCIDAS vencidas")"

if (( VENCIDAS > 0 )); then
  echo ""
  info "Las vencidas se borran solas cada hora."
  info "Para hacerlo ya:  Cuentas › Limpiar vencidas"
fi

pause
