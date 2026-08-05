#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Nginx: la puerta TLS del 443
#
# TODO lo que va cifrado entra por aqui. Nginx termina el TLS y reparte
# por RUTA:
#
#   wss://host:443$WS_PATH   -> nexo-hproxy -> SSH   (HTTP Custom "WS+SSL")
#   wss://host:443/vmess     -> Xray VMess
#   wss://host:443/vless     -> Xray VLESS
#   wss://host:443/trojan    -> Xray Trojan
#   grpc  host:443 nexo-grpc -> Xray VLESS gRPC
#   resto                    -> pagina estatica (parece un web normal)
#
# Por que asi y no con sslh/stunnel en el 443:
#   - Un solo dueño del puerto. El fallo clasico de estos paneles es poner
#     sshd, stunnel y sslh a la vez en el 443 y que solo arranque uno.
#   - El certificado se sirve con CUALQUIER SNI (server_name _ +
#     default_server), que es justo lo que necesita el modo SNI/bug.
#   - Un escaneo del 443 ve una web con TLS valido, no un tunel.
#
# El reto HTTP-01 de Let's Encrypt NO puede vivir aqui, porque el 80 es
# del proxy de payload. Por eso hay un servidor local en $NGINX_LOCAL
# (127.0.0.1) al que nexo-hproxy reenvia las peticiones /.well-known/.
#
# Uso: nginx.sh [apply|status]
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
WEBROOT="/var/www/nexotunnel"

# ---------------------------------------------------------------------
# Certificado: el de Let's Encrypt si existe, si no uno autofirmado.
# El autofirmado funciona perfectamente para tunelar (los clientes de
# inyector no validan la cadena), pero conviene sacar uno real: algunos
# firewalls tiran los TLS con certificado invalido.
ensure_cert() {
  mkdir -p "$TLS_DIR"
  local dom; dom=$(get_domain)

  if [[ -n "$dom" && -s "/etc/letsencrypt/live/$dom/fullchain.pem" ]]; then
    ln -sf "/etc/letsencrypt/live/$dom/fullchain.pem" "$TLS_DIR/fullchain.pem"
    ln -sf "/etc/letsencrypt/live/$dom/privkey.pem"   "$TLS_DIR/privkey.pem"
    info "Certificado: Let's Encrypt ($dom)"
    return
  fi

  if [[ ! -s "$TLS_DIR/privkey.pem" || -L "$TLS_DIR/privkey.pem" ]]; then
    rm -f "$TLS_DIR/fullchain.pem" "$TLS_DIR/privkey.pem"
    openssl req -newkey rsa:2048 -nodes -x509 -days 3650 \
      -keyout "$TLS_DIR/privkey.pem" -out "$TLS_DIR/fullchain.pem" \
      -subj "/C=HN/ST=FM/L=Tegucigalpa/O=NexoTunnel/CN=${dom:-nexotunnel}" \
      >/dev/null 2>&1
    chmod 600 "$TLS_DIR/privkey.pem"
    warn "Certificado autofirmado (marca 'permitir inseguro' en el cliente)"
  fi
}

# nginx <1.25 quiere "listen 443 ssl http2;"; >=1.25 quiere "http2 on;".
# Emitir el que no toca deja nginx sin arrancar o sin HTTP/2 (y sin HTTP/2
# el transporte gRPC no funciona).
#
# NO se emite "listen [::]:443": el instalador desactiva IPv6 por sysctl,
# asi que esa direccion no existe y nginx muere al arrancar con
# "Cannot assign requested address" (nginx -t si pasa, que es lo que hace
# el fallo tan dificil de encontrar).
http2_lines() {
  local ver major minor
  ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  major=${ver%%.*}; minor=$(echo "$ver" | cut -d. -f2)
  if [[ -z "$ver" ]]; then
    echo "listen ${TLS_PORT} ssl;|"
  elif (( major > 1 )) || { (( major == 1 )) && (( minor >= 25 )); }; then
    echo "listen ${TLS_PORT} ssl;|http2 on;"
  else
    echo "listen ${TLS_PORT} ssl http2;|"
  fi
}

# ---------------------------------------------------------------------
apply_nginx() {
  load_ports
  load_payload
  ensure_cert

  mkdir -p "$WEBROOT/.well-known/acme-challenge"
  if [[ ! -f "$WEBROOT/index.html" ]]; then
    cat > "$WEBROOT/index.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Welcome</title>
<style>body{font-family:system-ui,sans-serif;margin:4rem auto;max-width:34rem;color:#333}</style>
<h1>It works</h1>
<p>This server is up and running.</p>
HTML
  fi

  local l1 l2 h2
  h2=$(http2_lines)
  l1=$(echo "$h2" | cut -d'|' -f1)
  l2=$(echo "$h2" | cut -d'|' -f2)

  # El 'map' tiene que ir en contexto http, no dentro del server
  cat > /etc/nginx/conf.d/nexotunnel-map.conf <<'EOF'
# NexoTunnel: cabecera Connection correcta para WebSocket
map $http_upgrade $nexo_connection {
    default upgrade;
    ''      close;
}
EOF

  cat > /etc/nginx/sites-available/nexotunnel <<EOF
# Generado por NexoTunnel. No editar a mano: se reescribe con 'nexo-nginx apply'.

# --- Servidor local: retos ACME (se lo pasa nexo-hproxy desde el 80) ---
server {
    listen 127.0.0.1:${NGINX_LOCAL};
    server_name _;
    root ${WEBROOT};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
        allow all;
    }
    location / { try_files \$uri \$uri/ =404; }
}

# --- 443: TLS para todos los transportes -------------------------------
server {
    ${l1}
    ${l2}
    server_name _;
    root ${WEBROOT};
    index index.html;

    ssl_certificate     ${TLS_DIR}/fullchain.pem;
    ssl_certificate_key ${TLS_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:NexoSSL:10m;
    ssl_session_timeout 10m;

    # Un tunel puede estar horas sin transferir nada
    proxy_read_timeout  7d;
    proxy_send_timeout  7d;
    client_max_body_size 0;

    server_tokens off;

    # --- SSH sobre WebSocket seguro (modo "WS + SSL" del cliente) -------
    # Apunta a la instancia INTERNA del proxy, no a la del puerto 80. La
    # del 80 tiene la respuesta HTTP que el revendedor elija en el panel,
    # y si la cambia a "200 OK" nginx deja de ver el 101 y no hace el
    # upgrade: el WSS se rompe en silencio mientras el 80 sigue bien.
    # La interna responde 101 siempre.
    #
    # ^~ y no =: hay clientes que añaden una barra final o un subpath.
    location ^~ ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_INTERNAL};
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$nexo_connection;
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
    }

    # --- Xray -----------------------------------------------------------
    location = /vmess {
        proxy_pass http://127.0.0.1:${XRAY_VMESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$nexo_connection;
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
    }

    location = /vless {
        proxy_pass http://127.0.0.1:${XRAY_VLESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$nexo_connection;
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
    }

    location = /trojan {
        proxy_pass http://127.0.0.1:${XRAY_TROJAN};
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$nexo_connection;
        proxy_set_header Host       \$host;
        proxy_set_header X-Real-IP  \$remote_addr;
    }

    # gRPC necesita HTTP/2 y grpc_pass (proxy_pass no vale)
    location ^~ /nexo-grpc {
        grpc_pass grpc://127.0.0.1:${XRAY_GRPC};
        grpc_read_timeout  7d;
        grpc_send_timeout  7d;
        grpc_set_header Host \$host;
    }

    # --- Todo lo demas: web normal --------------------------------------
    location / { try_files \$uri \$uri/ =404; }
}
EOF

  ln -sf /etc/nginx/sites-available/nexotunnel /etc/nginx/sites-enabled/nexotunnel
  # El default de Debian tambien escucha en el 80 y chocaria con hproxy
  rm -f /etc/nginx/sites-enabled/default

  if nginx -t >/dev/null 2>&1; then
    systemctl restart nginx >/dev/null 2>&1
    ok "Nginx aplicado (443 TLS, ruta WS: $WS_PATH)"
  else
    err "La configuracion de nginx no valida:"
    nginx -t
    return 1
  fi
}

# ---------------------------------------------------------------------
show_status() {
  load_ports; load_payload
  header "Nginx / TLS"
  if is_active nginx; then ok "nginx activo"; else err "nginx detenido"; fi
  echo ""
  ui_field "Puerto TLS" "$TLS_PORT"
  ui_field "Ruta SSH-WS" "$WS_PATH"
  ui_field "Rutas Xray" "/vmess  /vless  /trojan  /nexo-grpc"
  echo ""
  if [[ -s "$TLS_DIR/fullchain.pem" ]]; then
    ui_field "Certificado" "$(openssl x509 -noout -subject -in "$TLS_DIR/fullchain.pem" 2>/dev/null | sed 's/^subject=//')"
    ui_field "Vence" "$(openssl x509 -noout -enddate -in "$TLS_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
  else
    warn "Sin certificado"
  fi
}

case "${1:-apply}" in
  apply)  apply_nginx ;;
  status) show_status ;;
  *)      echo "Uso: $(basename "$0") [apply|status]"; exit 1 ;;
esac
