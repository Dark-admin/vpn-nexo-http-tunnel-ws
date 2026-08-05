#!/bin/bash
#==========================================
# NexoTunnel v1.0 - SlowDNS (dnstt)
#
# El transporte que salva cuando el operador cobra todo menos el DNS. El
# cliente encapsula SSH dentro de consultas DNS que salen por el resolver
# del propio operador y acaban aqui, en el servidor autoritativo de un
# subdominio nuestro.
#
# Hace falta preparar el DNS del dominio ANTES (en el panel del registrador):
#
#   Tipo  Nombre                Valor
#   A     dns.tudominio.com     <IP del VPS>
#   NS    sdns.tudominio.com    dns.tudominio.com
#
# El cliente pone entonces:
#   Nameserver / NS : sdns.tudominio.com
#   Public key      : la que imprime este script
#   DNS resolver    : el del operador, o 8.8.8.8, 1.1.1.1...
#
# Se usa dnstt de David Fifield (bamsoftware), compilado desde fuente. No
# se descargan binarios sueltos de repositorios de terceros: es codigo que
# ve todo el trafico de los clientes.
#
# Uso: slowdns.sh [install|apply|status|keys|remove]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
if [[ -f "$NEXO_INSTALL/lib/common.sh" ]]; then
  source "$NEXO_INSTALL/lib/common.sh"
else
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi
need_root

SD_DIR="$NEXO_CONF/slowdns"
SD_KEY="$SD_DIR/server.key"
SD_PUB="$SD_DIR/server.pub"
SD_NS="$SD_DIR/ns"
SD_BIN="/usr/local/bin/dnstt-server"
SD_UNIT="/etc/systemd/system/nexo-slowdns.service"

# ---------------------------------------------------------------------
install_dnstt() {
  if [[ -x "$SD_BIN" ]]; then
    ok "dnstt-server ya instalado"
    return 0
  fi

  if ! command -v go >/dev/null 2>&1; then
    info "Instalando Go (necesario para compilar dnstt)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y golang-go >/dev/null 2>&1 \
      || { err "No se pudo instalar Go"; return 1; }
  fi

  info "Compilando dnstt-server (tarda 1-3 min)..."
  local tmp; tmp=$(mktemp -d)
  if GOPATH="$tmp" GOBIN="$tmp/bin" GOFLAGS=-mod=mod \
     go install www.bamsoftware.com/git/dnstt.git/dnstt-server@latest >/dev/null 2>&1 \
     && [[ -x "$tmp/bin/dnstt-server" ]]; then
    install -m 755 "$tmp/bin/dnstt-server" "$SD_BIN"
    rm -rf "$tmp"
    ok "dnstt-server compilado en $SD_BIN"
  else
    rm -rf "$tmp"
    err "Fallo la compilacion de dnstt"
    warn "Comprueba que el VPS tiene salida a internet y >=512MB de RAM libre."
    return 1
  fi
}

# ---------------------------------------------------------------------
gen_keys() {
  mkdir -p "$SD_DIR"
  chmod 700 "$SD_DIR"
  if [[ -s "$SD_KEY" && -s "$SD_PUB" ]]; then
    return 0
  fi
  info "Generando par de claves..."
  "$SD_BIN" -gen-key -privkey-file "$SD_KEY" -pubkey-file "$SD_PUB" >/dev/null 2>&1 \
    || { err "No se pudieron generar las claves"; return 1; }
  chmod 600 "$SD_KEY"
  ok "Claves creadas"
}

# ---------------------------------------------------------------------
apply_slowdns() {
  load_ports
  [[ -x "$SD_BIN" ]] || { install_dnstt || return 1; }
  gen_keys || return 1

  local ns_actual=""
  [[ -f "$SD_NS" ]] && ns_actual=$(cat "$SD_NS")

  # El instalador pregunta el NS en su primera fase y lo pasa por entorno,
  # para no parar la instalacion a mitad.
  local NS
  if [[ -n "${NEXO_SLOWDNS_NS:-}" ]]; then
    NS="$NEXO_SLOWDNS_NS"
    info "Nameserver: $NS"
  else
    echo ""
    info "Subdominio NS delegado a este servidor (ej: sdns.tudominio.com)"
    [[ -n "$ns_actual" ]] && info "Actual: $ns_actual"
    read -rp "Nameserver [${ns_actual:-ninguno}]: " NS
    NS="${NS:-$ns_actual}"
  fi
  [[ -z "$NS" ]] && { err "Hace falta el subdominio NS"; return 1; }
  valid_domain "$NS" || { err "Formato de dominio invalido"; return 1; }
  echo "$NS" > "$SD_NS"

  # dnstt escucha en un puerto alto y el 53 se le redirige. Asi no hace
  # falta darle root ni pelearse con systemd-resolved.
  cat > "$SD_UNIT" <<EOF
[Unit]
Description=NexoTunnel SlowDNS (dnstt) -> SSH
After=network.target

[Service]
Type=simple
ExecStart=$SD_BIN -udp 0.0.0.0:$SLOWDNS_PORT -privkey-file $SD_KEY $NS 127.0.0.1:$DROPBEAR_PORT1
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=append:$NEXO_LOG/slowdns.log
StandardError=append:$NEXO_LOG/slowdns.log

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$NEXO_LOG"; touch "$NEXO_LOG/slowdns.log"
  systemctl daemon-reload >/dev/null 2>&1
  svc enable nexo-slowdns
  svc restart nexo-slowdns

  # Redireccion 53 -> 5300. Se borra la anterior antes para no acumular.
  while iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT"
  done
  iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT"
  bash "$NEXO_INSTALL/config/firewall.sh" persist >/dev/null 2>&1

  echo ""
  show_status
}

# ---------------------------------------------------------------------
show_status() {
  header "SlowDNS"
  if [[ ! -x "$SD_BIN" ]]; then
    warn "dnstt-server no instalado"
    return
  fi
  if is_active nexo-slowdns; then ok "nexo-slowdns activo"; else err "nexo-slowdns detenido"; fi
  echo ""
  ui_field "Nameserver" "$(cat "$SD_NS" 2>/dev/null || echo '(sin configurar)')"
  ui_field "Puerto UDP" "53 -> $SLOWDNS_PORT"
  ui_field "Backend" "127.0.0.1:$DROPBEAR_PORT1 (dropbear)"
  echo ""
  if [[ -s "$SD_PUB" ]]; then
    ui_raw "Public key (va en el cliente):" "$(cat "$SD_PUB")"
  else
    warn "Sin claves generadas"
  fi
  echo ""
  ui_thead "RECORDS DNS NECESARIOS"
  local ip; ip=$(get_ip)
  local ns; ns=$(cat "$SD_NS" 2>/dev/null || echo "sdns.tudominio.com")
  printf "  A    dns.%s\t%s\n" "${ns#*.}" "$ip"
  printf "  NS   %s\tdns.%s\n" "$ns" "${ns#*.}"
}

# ---------------------------------------------------------------------
remove_slowdns() {
  systemctl disable --now nexo-slowdns >/dev/null 2>&1
  rm -f "$SD_UNIT"
  systemctl daemon-reload >/dev/null 2>&1
  while iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT" 2>/dev/null; do
    iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT"
  done
  ok "SlowDNS desactivado (las claves se conservan en $SD_DIR)"
}

case "${1:-status}" in
  install) install_dnstt && gen_keys ;;
  apply)   apply_slowdns ;;
  status)  show_status ;;
  keys)    gen_keys && cat "$SD_PUB" ;;
  remove)  remove_slowdns ;;
  *)       echo "Uso: $(basename "$0") [install|apply|status|keys|remove]"; exit 1 ;;
esac
