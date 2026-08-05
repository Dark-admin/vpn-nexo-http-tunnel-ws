#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Ver / reenviar la configuracion de una cuenta
#
# Regenera la ficha en el momento, no la lee de disco: si desde que se
# creo la cuenta cambio el dominio, el SNI, el bug host o la ruta WS, la
# ficha vieja ya no sirve y el cliente se queda sin conectar sin saber
# por que.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
source "$NEXO_INSTALL/lib/gen.sh"
need_root
db_init

cls; header "Cuentas" "Configuracion"

pick_user USUARIO "ELEGIR CUENTA" || { pause; exit 0; }

DIR=$(gen_files "$USUARIO")

while true; do
  cls
  echo ""
  gen_card "$USUARIO"
  echo ""
  ui_field "Regenerado en" "$DIR"
  echo ""
  ui_top "QR"
  ui_item       "1" "VMess"
  ui_item       "2" "VLESS"
  ui_item       "3" "Trojan"
  ui_item       "4" "VLESS gRPC"
  ui_item_quiet "0" "Volver"
  ui_bottom

  ui_prompt; read -r op; op="${op//[[:space:]]/}"
  case "$op" in
    1|2|3|4)
      LINK=$(sed -n "${op}p" "$DIR/enlaces.txt")
      cls
      header "QR"
      gen_qr_term "$LINK"
      echo ""
      printf "%s\n" "$LINK"
      pause ;;
    0) exit 0 ;;
    *) printf " %b✗ Opcion invalida%b\n" "$C_ERR" "$C_RESET"; sleep 0.7 ;;
  esac
done
