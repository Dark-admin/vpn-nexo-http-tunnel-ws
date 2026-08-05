#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Dominio + certificado
#
# El reto HTTP-01 de Let's Encrypt necesita el puerto 80. Aqui el 80 es
# del proxy de payload, no de nginx. La solucion NO es parar el tunel
# cada 60 dias: nexo-hproxy detecta las peticiones a /.well-known/ y las
# reenvia al nginx local ($NGINX_LOCAL), asi que certbot funciona con el
# tunel en marcha y sin abrir ningun puerto extra.
#
# Al terminar se reaplica nginx (que enlaza el certificado nuevo) y
# stunnel (que necesita cert+clave en un mismo .pem), y se deja un
# deploy-hook para que la renovacion automatica haga lo mismo.
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
source "$NEXO_INSTALL/lib/common.sh"
need_root
load_ports

WEBROOT="/var/www/nexotunnel"

cls; header "Configuracion" "Dominio y certificado"

ACTUAL=$(get_domain)
[[ -n "$ACTUAL" ]] && info "Dominio actual: $ACTUAL"

# El instalador ya pregunto el dominio en su primera fase y lo pasa por
# entorno: asi la instalacion no se para a mitad esperando a que alguien
# vuelva a teclear lo mismo.
DESATENDIDO=0
if [[ -n "${NEXO_DOMAIN:-}" ]]; then
  DOMAIN="$NEXO_DOMAIN"
  DESATENDIDO=1
  info "Dominio: $DOMAIN"
else
  read -rp "Dominio (ENTER para mantener '${ACTUAL:-ninguno}'): " DOMAIN
  DOMAIN="${DOMAIN:-$ACTUAL}"
fi
[[ -z "$DOMAIN" ]] && { err "Hace falta un dominio"; pause; exit 1; }
valid_domain "$DOMAIN" || { err "Formato de dominio invalido"; pause; exit 1; }

# Llamado desde el instalador no hay nadie mirando la pantalla para pulsar
# una tecla: las pausas se anulan y los mensajes quedan en el scroll.
if (( DESATENDIDO )); then
  pause() { :; }
fi

# --- Comprobar el DNS --------------------------------------------------
IP=$(get_ip)
info "Comprobando DNS de $DOMAIN..."
DNS_IP=$(dig +short A "$DOMAIN" 2>/dev/null | tail -1)
[[ -z "$DNS_IP" ]] && DNS_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)

if [[ -z "$DNS_IP" ]]; then
  err "El dominio no resuelve. Crea un registro A hacia $IP y espera la propagacion."
  pause; exit 1
elif [[ "$DNS_IP" != "$IP" ]]; then
  warn "El dominio apunta a $DNS_IP, pero este servidor es $IP"
  if (( DESATENDIDO )); then
    # Durante la instalacion se sigue: si el DNS aun no ha propagado,
    # certbot fallara y lo dira claro, en vez de dejar la instalacion
    # parada esperando una respuesta que nadie va a dar.
    warn "Se continua igualmente (certbot dira si el reto no llega)"
  else
    ask_yes "¿Continuar igualmente? (s/n):" n || { info "Cancelado"; pause; exit 0; }
  fi
else
  ok "DNS correcto: $DOMAIN -> $IP"
fi

mkdir -p "$NEXO_CONF"
echo "$DOMAIN" > "$DOMAIN_FILE"

# --- certbot -----------------------------------------------------------
if ! command -v certbot >/dev/null 2>&1; then
  info "Instalando certbot..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot >/dev/null 2>&1 \
    || { err "No se pudo instalar certbot"; pause; exit 1; }
fi

mkdir -p "$WEBROOT/.well-known/acme-challenge"

# El reto entra por el 80 (hproxy) y sale por el 8081 (nginx). Si el
# proxy no esta arriba, certbot fallara con un 'Connection refused' poco
# claro, asi que se avisa antes.
# El proxy que reenvia los retos ya no tiene un nombre fijo: se busca por
# su funcion (el que tiene puerto ACME configurado), porque el revendedor
# puede haberlo renombrado o movido desde el panel de puertos.
PX_ACME=$(px_unidad_acme)
if [[ -z "$PX_ACME" ]]; then
  err "Ningun proxy tiene activado el reenvio de retos ACME."
  err "Configuralo en:  menu -> Puertos y proxies"
  pause; exit 1
fi

if ! is_active "$PX_ACME"; then
  warn "$PX_ACME no esta activo: el reto del puerto 80 no llegara."
  if (( DESATENDIDO )); then
    systemctl restart "$PX_ACME" >/dev/null 2>&1
    is_active "$PX_ACME" && ok "$PX_ACME reiniciado" \
      || warn "Sigue caido; el certificado probablemente falle"
  else
    ask_yes "¿Intentarlo igualmente? (s/n):" n || { pause; exit 1; }
  fi
fi
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null

if [[ -n "${NEXO_EMAIL+x}" ]]; then
  EMAIL="$NEXO_EMAIL"
else
  read -rp "Email para avisos de caducidad (ENTER para omitir): " EMAIL
fi
if [[ -n "$EMAIL" ]]; then
  EMAIL_ARG="--email $EMAIL --no-eff-email"
else
  EMAIL_ARG="--register-unsafely-without-email"
  warn "Sin email no recibiras avisos antes de que caduque."
fi

info "Solicitando certificado (webroot, puerto 80 via $PX_ACME)..."
# shellcheck disable=SC2086
if certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
     --non-interactive --agree-tos $EMAIL_ARG --keep-until-expiring; then
  ok "Certificado emitido"
else
  err "Certbot fallo. Revisa /var/log/letsencrypt/letsencrypt.log"
  echo ""
  echo "  Causas habituales:"
  echo "   - el puerto 80 no llega desde internet (firewall del proveedor)"
  echo "   - el DNS aun no ha propagado"
  echo "   - el proxy del 80 caido, o ese puerto lo ocupa otro proceso"
  echo "   - limite de 5 certificados por dominio y semana"
  pause; exit 1
fi

# --- Aplicar el certificado -------------------------------------------
bash "$NEXO_INSTALL/core/nginx.sh"   apply
bash "$NEXO_INSTALL/core/stunnel.sh" apply

# Si no habia SNI configurado, el dominio real es el valor sensato
load_payload
if [[ -z "$SNI_HOST" ]]; then
  SNI_HOST="$DOMAIN"
  save_payload
  info "SNI por defecto: $DOMAIN (cambialo en Payload si usas un bug)"
fi

# --- Hook de renovacion ------------------------------------------------
# Sin esto, a los 90 dias nginx y stunnel siguen con el certificado viejo.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/nexotunnel.sh <<EOF
#!/bin/bash
# Reaplica el certificado renovado en nginx y stunnel
bash $NEXO_INSTALL/core/nginx.sh   apply >/dev/null 2>&1
bash $NEXO_INSTALL/core/stunnel.sh apply >/dev/null 2>&1
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/nexotunnel.sh

systemctl enable --now certbot.timer >/dev/null 2>&1 \
  && ok "Renovacion automatica activada" \
  || warn "Revisa la renovacion: certbot renew --dry-run"

LIVE="/etc/letsencrypt/live/$DOMAIN"
echo ""
ok "Listo"
ui_field "Dominio" "$DOMAIN"
ui_field "Vence"   "$(openssl x509 -enddate -noout -in "$LIVE/fullchain.pem" 2>/dev/null | cut -d= -f2)"
ui_field "WSS"     "wss://$DOMAIN:$TLS_PORT$WS_PATH"
pause
