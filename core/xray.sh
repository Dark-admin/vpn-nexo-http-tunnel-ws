#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Xray (VMess / VLESS / Trojan)
#
# Los cuatro inbounds escuchan SOLO en 127.0.0.1 y sin TLS: el cifrado y
# el puerto 443 los pone nginx. Ventajas:
#   - un unico certificado y un unico puerto publico
#   - el SNI lo elige el cliente (modo bug) sin tocar nada del servidor
#   - si Xray se cae, el 443 sigue sirviendo la web y no canta
#
# La lista de clientes NO se edita de forma incremental: se REGENERA
# entera desde users.json en cada cambio ('sync'). Editar con jq clave a
# clave es como se corrompen estos ficheros; regenerar es idempotente y
# deja Xray y el panel siempre de acuerdo.
#
# Uso: xray.sh [install|sync|adduser <u>|deluser <u>|status]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
if [[ -f "$NEXO_INSTALL/lib/common.sh" ]]; then
  source "$NEXO_INSTALL/lib/common.sh"
  source "$NEXO_INSTALL/lib/db.sh"
else
  _D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$_D/lib/common.sh"; source "$_D/lib/db.sh"
fi
need_root

GRPC_SERVICE="nexo-grpc"

# ---------------------------------------------------------------------
install_xray() {
  if command -v xray >/dev/null 2>&1; then
    ok "Xray ya instalado ($(xray version 2>/dev/null | head -1))"
    return 0
  fi
  info "Instalando Xray (instalador oficial de XTLS)..."
  if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
       @ install >/dev/null 2>&1; then
    ok "Xray instalado"
  else
    err "No se pudo instalar Xray"
    warn "El resto del panel (SSH, payload, WS, TLS, SlowDNS) funciona igual."
    return 1
  fi
}

# El instalador oficial deja el servicio corriendo como 'nobody'. Si la
# config queda en 600 root:root, Xray no puede leerla; si /var/log/xray es
# root:root, no puede escribir el access.log. En los dos casos el servicio
# arranca y se muere en el acto, y el journal solo dice "permission
# denied" sin decir de que fichero.
xray_user() {
  local u
  u=$(systemctl show xray -p User --value 2>/dev/null)
  # Vacio = la unidad no fija User, o sea corre como root
  echo "${u:-root}"
}

# ---------------------------------------------------------------------
sync_config() {
  command -v jq >/dev/null 2>&1 || { err "Falta jq"; return 1; }
  command -v xray >/dev/null 2>&1 || { warn "Xray no instalado, nada que sincronizar"; return 0; }
  load_ports
  db_init

  local xuser; xuser=$(xray_user)
  mkdir -p "$(dirname "$XRAY_CONF")" /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  if [[ "$xuser" != "root" ]] && id "$xuser" &>/dev/null; then
    chown "$xuser" /var/log/xray /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null
  fi
  chmod 750 /var/log/xray

  # Tres formas distintas de la misma lista de cuentas
  local c_vmess c_vless c_trojan
  c_vmess=$(db_read  '[.users[]|{id:.uuid, email:.user, alterId:0}]')
  c_vless=$(db_read  '[.users[]|{id:.uuid, email:.user}]')
  c_trojan=$(db_read '[.users[]|{password:.uuid, email:.user}]')

  [[ -z "$c_vmess"  ]] && c_vmess='[]'
  [[ -z "$c_vless"  ]] && c_vless='[]'
  [[ -z "$c_trojan" ]] && c_trojan='[]'

  # El temporal DEBE acabar en .json: Xray deduce el formato del fichero por
  # la extension y con un nombre suelto de mktemp falla con
  # "core: Failed to get format of /tmp/tmp.XXXX", se queda con la config
  # anterior y el servicio arranca sin ningun inbound. Es decir: Xray
  # aparece "activo" en el panel y todo da 502.
  local tmp
  tmp=$(mktemp --suffix=.json 2>/dev/null) || tmp="$(mktemp).json"
  jq -n \
    --argjson vmess  "$c_vmess" \
    --argjson vless  "$c_vless" \
    --argjson trojan "$c_trojan" \
    --argjson p_vmess  "$XRAY_VMESS" \
    --argjson p_vless  "$XRAY_VLESS" \
    --argjson p_trojan "$XRAY_TROJAN" \
    --argjson p_grpc   "$XRAY_GRPC" \
    --arg grpcsvc "$GRPC_SERVICE" \
  '{
    log: {
      loglevel: "warning",
      access:   "/var/log/xray/access.log",
      error:    "/var/log/xray/error.log"
    },
    inbounds: [
      { tag: "vmess-ws", listen: "127.0.0.1", port: $p_vmess, protocol: "vmess",
        settings: { clients: $vmess },
        streamSettings: { network: "ws", security: "none",
                          wsSettings: { path: "/vmess" } } },

      { tag: "vless-ws", listen: "127.0.0.1", port: $p_vless, protocol: "vless",
        settings: { clients: $vless, decryption: "none" },
        streamSettings: { network: "ws", security: "none",
                          wsSettings: { path: "/vless" } } },

      { tag: "trojan-ws", listen: "127.0.0.1", port: $p_trojan, protocol: "trojan",
        settings: { clients: $trojan },
        streamSettings: { network: "ws", security: "none",
                          wsSettings: { path: "/trojan" } } },

      { tag: "vless-grpc", listen: "127.0.0.1", port: $p_grpc, protocol: "vless",
        settings: { clients: $vless, decryption: "none" },
        streamSettings: { network: "grpc", security: "none",
                          grpcSettings: { serviceName: $grpcsvc } } }
    ],
    outbounds: [
      { tag: "directo",  protocol: "freedom",  settings: {} },
      { tag: "bloqueado", protocol: "blackhole", settings: {} }
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        { type: "field", ip: ["geoip:private"], outboundTag: "bloqueado" },
        { type: "field", protocol: ["bittorrent"], outboundTag: "bloqueado" }
      ]
    }
  }' > "$tmp" 2>/dev/null

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    err "No se pudo generar la configuracion de Xray"
    return 1
  fi

  # Validar ANTES de pisar la config buena
  if xray run -test -config "$tmp" >/dev/null 2>&1; then
    # 600 pero propiedad del usuario del servicio: los UUID no quedan
    # legibles para el resto del sistema y Xray puede leerlos.
    if [[ "$xuser" != "root" ]] && id "$xuser" &>/dev/null; then
      install -m 600 -o "$xuser" "$tmp" "$XRAY_CONF"
    else
      install -m 600 "$tmp" "$XRAY_CONF"
    fi
    rm -f "$tmp"
    systemctl restart xray >/dev/null 2>&1
    ok "Xray sincronizado ($(db_count) cuentas)"
  else
    err "Config de Xray invalida, se conserva la anterior:"
    xray run -test -config "$tmp" 2>&1 | tail -5
    rm -f "$tmp"
    return 1
  fi
}

# ---------------------------------------------------------------------
show_status() {
  load_ports
  header "Xray"
  if ! command -v xray >/dev/null 2>&1; then
    warn "Xray no instalado"
    return
  fi
  if is_active xray; then ok "xray activo"; else err "xray detenido"; fi
  ui_field "Version" "$(xray version 2>/dev/null | head -1)"
  echo ""
  ui_field "VMess WS"  "127.0.0.1:$XRAY_VMESS   ruta /vmess"
  ui_field "VLESS WS"  "127.0.0.1:$XRAY_VLESS   ruta /vless"
  ui_field "Trojan WS" "127.0.0.1:$XRAY_TROJAN  ruta /trojan"
  ui_field "VLESS gRPC" "127.0.0.1:$XRAY_GRPC   servicio $GRPC_SERVICE"
  echo ""
  ui_field "Cuentas" "$(db_count)"
  if [[ -s /var/log/xray/error.log ]]; then
    echo ""
    ui_thead "ULTIMOS ERRORES"
    tail -5 /var/log/xray/error.log | sed 's/^/ /'
  fi
}

case "${1:-status}" in
  install) install_xray && sync_config ;;
  sync)    sync_config ;;
  adduser) sync_config ;;   # la cuenta ya esta en users.json
  deluser) sync_config ;;   # idem: regenerar basta
  status)  show_status ;;
  *)       echo "Uso: $(basename "$0") [install|sync|adduser|deluser|status]"; exit 1 ;;
esac
