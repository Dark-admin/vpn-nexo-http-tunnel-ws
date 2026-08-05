#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Crear cuenta
#
# UNA cuenta = todos los transportes. El mismo usuario/clave vale para
# SSH directo, payload, WebSocket, TLS y SlowDNS; el mismo UUID vale para
# VMess, VLESS y Trojan. Asi el cliente recibe una sola ficha y el
# revendedor no tiene que llevar tres listas distintas.
#
# El orden importa: primero el usuario del sistema, luego la base de
# datos, luego Xray. Si algo falla por el camino se deshace lo anterior,
# para no dejar cuentas a medias (el fallo clasico: existe en Xray pero no
# en el sistema, o al reves, y nadie entiende por que "no conecta").
#==========================================

set -uo pipefail
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
source "$NEXO_INSTALL/lib/db.sh"
source "$NEXO_INSTALL/lib/gen.sh"
need_root
db_init

cls; header "Cuentas" "Crear"

while true; do
  read -rp "Usuario: " USUARIO
  if ! valid_username "$USUARIO"; then
    err "Solo minusculas, digitos, guion y guion bajo (max 32)."
    continue
  fi
  if id "$USUARIO" &>/dev/null || db_exists "$USUARIO"; then
    err "La cuenta '$USUARIO' ya existe."
    continue
  fi
  break
done

ask_password PASS
ask_valid DIAS  "Dias de validez     : " valid_number
ask_valid LIMIT "Limite de conexiones: " valid_number

if (( DIAS < 1 || DIAS > 3650 ));  then err "Dias fuera de rango (1-3650)";   pause; exit 1; fi
if (( LIMIT < 1 || LIMIT > 100 )); then err "Limite fuera de rango (1-100)"; pause; exit 1; fi

EXP_DATE=$(date -d "+$DIAS days" +%Y-%m-%d)
UUID=$(gen_uuid)

# --- 1. Usuario del sistema (SSH / Dropbear / SlowDNS) ----------------
if ! useradd -e "$EXP_DATE" -s /bin/false -M "$USUARIO"; then
  err "No se pudo crear el usuario del sistema"
  pause; exit 1
fi

if ! echo "$USUARIO:$PASS" | chpasswd; then
  err "No se pudo asignar la contraseña, revirtiendo"
  userdel -f "$USUARIO" 2>/dev/null
  pause; exit 1
fi

# --- 2. Base de datos del panel ---------------------------------------
if ! db_add "$USUARIO" "$PASS" "$UUID" "$EXP_DATE" "$LIMIT"; then
  err "No se pudo guardar en la base de datos, revirtiendo"
  userdel -f "$USUARIO" 2>/dev/null
  pause; exit 1
fi

# --- 3. Xray ----------------------------------------------------------
# Si Xray no esta instalado o falla, la cuenta SSH sigue siendo valida:
# se avisa pero no se revierte.
if ! bash "$NEXO_INSTALL/core/xray.sh" sync >/dev/null 2>&1; then
  warn "Xray no se pudo sincronizar: VMess/VLESS/Trojan no funcionaran"
  warn "Revisa con: nexo-xray status"
fi

# --- 4. Ficha y ficheros ----------------------------------------------
DIR=$(gen_files "$USUARIO")

cls
echo ""
gen_card "$USUARIO"
echo ""
ok "Cuenta creada"
ui_field "Guardado en" "$DIR"
echo ""
ui_field "Ficha"    "$DIR/$USUARIO.txt"
ui_field "Enlaces"  "$DIR/enlaces.txt"
command -v qrencode >/dev/null 2>&1 && ui_field "QR" "$DIR/qr-*.png"
echo ""

if ask_yes "¿Mostrar el QR de VMess aqui? (s/n):" n; then
  echo ""
  gen_qr_term "$(head -1 "$DIR/enlaces.txt")"
fi

pause
