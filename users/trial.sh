#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Cuenta de prueba
#
# Cuenta desechable con nombre y clave aleatorios. Se le pone limite 1 a
# proposito: la prueba es para que el cliente compruebe que su operador
# deja pasar el tunel, no para que la reparta.
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
source "$NEXO_INSTALL/lib/gen.sh"
need_root
db_init

cls; header "Cuentas" "Prueba"

read -rp "Duracion en horas [6]: " HORAS
HORAS="${HORAS:-6}"
valid_number "$HORAS" || { err "Numero invalido"; pause; exit 1; }
if (( HORAS < 1 || HORAS > 168 )); then err "Rango: 1-168 horas"; pause; exit 1; fi

# useradd -e trabaja con dias enteros, asi que la expiracion "real" en
# horas la aplica autokill; -e es solo la red de seguridad.
DIAS=$(( (HORAS + 23) / 24 ))
EXP_DATE=$(date -d "+$DIAS days" +%Y-%m-%d)

for _ in $(seq 1 10); do
  USUARIO="prueba$(shuf -i 100-999 -n1)"
  id "$USUARIO" &>/dev/null || break
done
PASS=$(tr -dc 'a-z0-9' </dev/urandom | head -c8)
UUID=$(gen_uuid)

if ! useradd -e "$EXP_DATE" -s /bin/false -M "$USUARIO"; then
  err "No se pudo crear el usuario"; pause; exit 1
fi
if ! echo "$USUARIO:$PASS" | chpasswd; then
  err "No se pudo asignar la contraseña"; userdel -f "$USUARIO" 2>/dev/null; pause; exit 1
fi

db_add "$USUARIO" "$PASS" "$UUID" "$EXP_DATE" "1" "prueba ${HORAS}h"
bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1

# Borrado a la hora exacta con un timer transitorio: no ensucia el crontab
# ni deja unidades sueltas si el VPS se reinicia antes. 'purge' la quita
# del sistema, de la base de datos Y de Xray; un simple userdel dejaria el
# UUID vivo y la prueba seria infinita por V2Ray.
systemd-run --on-active="${HORAS}h" --unit="nexo-trial-$USUARIO" \
  --description="NexoTunnel: borrar cuenta de prueba $USUARIO" \
  "$NEXO_INSTALL/bin/nexo-expire.sh" purge "$USUARIO" \
  >/dev/null 2>&1 \
  && ok "Se borrara sola en $HORAS h" \
  || warn "No se pudo programar el borrado; caducara el $EXP_DATE"

DIR=$(gen_files "$USUARIO")

cls
echo ""
gen_card "$USUARIO"
echo ""
ok "Cuenta de prueba creada ($HORAS horas, 1 conexion)"
ui_field "Guardado en" "$DIR"
pause
