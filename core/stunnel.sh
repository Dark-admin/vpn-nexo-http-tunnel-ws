#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Stunnel (TLS crudo -> Dropbear)
#
# Es el modo "SSH + SSL/TLS" de HTTP Custom: el cliente abre TLS y dentro
# habla SSH directamente, sin HTTP de por medio. No se puede montar en el
# 443 porque ahi manda nginx (que necesita ver HTTP para repartir rutas),
# asi que vive en $STUNNEL_PORT (444 por defecto).
#
# El SNI que mande el cliente da igual: stunnel presenta su certificado
# sea cual sea. Eso es justo lo que hace falta para el modo bug/SNI.
#
# Comparte certificado con nginx ($NEXO_CONF/tls), asi que al renovar
# Let's Encrypt se actualizan los dos a la vez.
#
# Uso: stunnel.sh [apply|status]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
if [[ -f "$NEXO_INSTALL/lib/common.sh" ]]; then
  source "$NEXO_INSTALL/lib/common.sh"
else
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi
need_root

TLS_DIR="$NEXO_CONF/tls"
PEM="/etc/stunnel/nexotunnel.pem"

build_pem() {
  # stunnel quiere cert+clave en un solo fichero
  if [[ -s "$TLS_DIR/fullchain.pem" && -s "$TLS_DIR/privkey.pem" ]]; then
    mkdir -p /etc/stunnel
    cat "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem" > "$PEM"
    chmod 600 "$PEM"
  else
    err "No hay certificado en $TLS_DIR (ejecuta antes: nexo-nginx apply)"
    return 1
  fi
}

apply_stunnel() {
  load_ports
  build_pem || return 1

  # OJO: el paquete de Debian se llama stunnel4 y SOLO lee /etc/stunnel/*.conf.
  # Escribir en /etc/stunnel5/ (como hacen muchos scripts copiados por ahi)
  # deja el servicio arrancado pero sin ningun puerto a la escucha.
  cat > /etc/stunnel/nexotunnel.conf <<EOF
cert = $PEM
pid = /var/run/stunnel4/nexotunnel.pid
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

# OJO con los nombres: son constantes SSL_OP_ de OpenSSL, no versiones con
# punto. "NO_TLSv1.1" NO existe (seria NO_TLSv1_1) y hace que stunnel se
# niegue a arrancar con "specified option name is not valid".
# Se deja TLS 1.0/1.1 disponible a proposito: muchos moviles Android
# viejos que usan estos clientes no negocian 1.2.
sslVersion = all
options = NO_SSLv2
options = NO_SSLv3

[ssh-tls]
accept  = $STUNNEL_PORT
connect = 127.0.0.1:$DROPBEAR_PORT1
EOF

  mkdir -p /var/run/stunnel4
  chown stunnel4:stunnel4 /var/run/stunnel4 2>/dev/null || true
  sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
  svc enable stunnel4
  svc restart stunnel4
  ok "Stunnel escuchando en $STUNNEL_PORT -> dropbear $DROPBEAR_PORT1"
}

show_status() {
  load_ports
  header "Stunnel (SSH + SSL)"
  if is_active stunnel4; then ok "stunnel4 activo"; else err "stunnel4 detenido"; fi
  ui_field "Puerto" "$STUNNEL_PORT"
  ui_field "Backend" "127.0.0.1:$DROPBEAR_PORT1"
  [[ -s "$PEM" ]] && ui_field "Vence" "$(openssl x509 -noout -enddate -in "$PEM" 2>/dev/null | cut -d= -f2)"
}

case "${1:-apply}" in
  apply)  apply_stunnel ;;
  status) show_status ;;
  *)      echo "Uso: $(basename "$0") [apply|status]"; exit 1 ;;
esac
