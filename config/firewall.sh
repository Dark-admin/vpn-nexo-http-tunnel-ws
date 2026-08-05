#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Firewall + Anti-DDoS
#
# Solo iptables, nunca mezclado con ufw: `iptables -F` borra las cadenas
# que ufw acaba de crear y cualquier `ufw reload` posterior tumba las
# reglas anti-DDoS. Es la fuente de la mitad de los "se me cayo el VPS".
#
# Cuidado con una regla que circula en muchos scripts copiados:
#     iptables -A INPUT -m recent --name portscan --set -j ACCEPT
# Ese ACCEPT no tiene condicion: acepta TODO y termina el recorrido de la
# cadena, dejando la politica DROP muerta y el servidor entero abierto.
# La deteccion correcta esta abajo: rcheck arriba del todo, --set al final
# de la cadena (donde solo llegan los puertos cerrados).
#
# Uso: firewall.sh [apply|status|persist|reset]
#==========================================

set -uo pipefail

NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
if [[ -f "$NEXO_INSTALL/lib/common.sh" ]]; then
  source "$NEXO_INSTALL/lib/common.sh"
else
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
fi
need_root

IPT=$(command -v iptables)
IPT6=$(command -v ip6tables)
RULES_V4="/etc/iptables/rules.v4"
RULES_V6="/etc/iptables/rules.v6"

# ---------------------------------------------------------------------
apply_firewall() {
  load_ports
  info "Aplicando firewall (iptables puro)..."

  # --- Limpieza total --------------------------------------------------
  $IPT -P INPUT ACCEPT; $IPT -P FORWARD ACCEPT; $IPT -P OUTPUT ACCEPT
  $IPT -F; $IPT -X
  $IPT -t nat -F;    $IPT -t nat -X
  $IPT -t mangle -F; $IPT -t mangle -X

  # --- Politicas por defecto -------------------------------------------
  $IPT -P INPUT DROP
  $IPT -P FORWARD DROP
  $IPT -P OUTPUT ACCEPT

  # --- 1. Local y establecidas -----------------------------------------
  $IPT -A INPUT -i lo -j ACCEPT
  $IPT -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $IPT -A INPUT -m conntrack --ctstate INVALID -j DROP

  # --- 2. Escaneadores ya fichados (va ARRIBA) -------------------------
  $IPT -A INPUT -m recent --name portscan --rcheck --seconds 300 -j DROP

  # --- 3. Paquetes malformados -----------------------------------------
  $IPT -A INPUT -f -j DROP
  $IPT -A INPUT -p tcp --tcp-flags ALL NONE        -j DROP
  $IPT -A INPUT -p tcp --tcp-flags ALL ALL         -j DROP
  $IPT -A INPUT -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
  $IPT -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  $IPT -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
  $IPT -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW -j DROP

  # --- 4. SYN flood -----------------------------------------------------
  $IPT -N NEXO_SYN 2>/dev/null || $IPT -F NEXO_SYN
  $IPT -A NEXO_SYN -m limit --limit 80/second --limit-burst 150 -j RETURN
  $IPT -A NEXO_SYN -j DROP
  $IPT -A INPUT -p tcp --syn -j NEXO_SYN

  # --- 5. ICMP ----------------------------------------------------------
  $IPT -A INPUT -p icmp --icmp-type echo-request \
       -m limit --limit 1/second --limit-burst 5 -j ACCEPT
  $IPT -A INPUT -p icmp --icmp-type echo-request -j DROP
  $IPT -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
  $IPT -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT

  # --- 6. Anti fuerza bruta en los puertos de login --------------------
  for p in "$SSH_PORT" "$DROPBEAR_PORT1" "$DROPBEAR_PORT2"; do
    valid_port "$p" || continue
    $IPT -A INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW \
         -m recent --name "brute$p" --set
    $IPT -A INPUT -p tcp --dport "$p" -m conntrack --ctstate NEW \
         -m recent --name "brute$p" --update --seconds 60 --hitcount 12 -j DROP
  done

  # --- 7. Servicios: connlimit por IP y ACCEPT --------------------------
  # El 443 y el 80 llevan limites altos: un movil abre varias conexiones
  # por tunel y detras de un CGNAT del operador salen cientos de clientes
  # con la misma IP publica. Poner 16 aqui es cortar a usuarios legitimos.
  # No llamar a esta lista 'svc': ese nombre ya es una FUNCION en
  # common.sh y leerlo aqui despista al siguiente que toque el fichero.
  local reglas=(
    "$SSH_PORT:8"
    "$DROPBEAR_PORT1:8"
    "$DROPBEAR_PORT2:8"
    "$HTTP_PORT:64"
    "$HTTP_ALT1:64"
    "$HTTP_ALT2:64"
    "$TLS_PORT:96"
    "$STUNNEL_PORT:48"
  )
  for entry in "${reglas[@]}"; do
    local port="${entry%%:*}" max="${entry##*:}"
    valid_port "$port" || continue
    $IPT -A INPUT -p tcp --dport "$port" \
         -m connlimit --connlimit-above "$max" --connlimit-mask 32 -j DROP
    $IPT -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
  done

  # --- 8. SlowDNS -------------------------------------------------------
  # El 53 se redirige al puerto alto en nat/PREROUTING, asi que INPUT ve
  # ya el puerto traducido. Se permiten los dos por claridad.
  $IPT -A INPUT -p udp --dport 53 -m limit --limit 200/second --limit-burst 400 -j ACCEPT
  valid_port "$SLOWDNS_PORT" && \
    $IPT -A INPUT -p udp --dport "$SLOWDNS_PORT" -m limit --limit 200/second --limit-burst 400 -j ACCEPT

  # NOTA: BadVPN (7100-7300) escucha en 127.0.0.1 y se alcanza DENTRO del
  # tunel SSH. No se abre al exterior a proposito.

  # --- 9. Deteccion de port-scan ---------------------------------------
  # Solo llegan aqui los paquetes contra puertos cerrados.
  $IPT -A INPUT -p tcp -m conntrack --ctstate NEW \
       -m recent --name portscan --set -j DROP

  # --- 10. Log con limite y descarte final ------------------------------
  $IPT -A INPUT -m limit --limit 5/min --limit-burst 10 \
       -j LOG --log-prefix "NexoFW-Drop: " --log-level 4
  $IPT -A INPUT -j DROP

  # --- nat: rehacer la redireccion de SlowDNS --------------------------
  # El flush de arriba se la ha llevado por delante.
  if [[ -s "$NEXO_CONF/slowdns/ns" ]] && valid_port "$SLOWDNS_PORT"; then
    $IPT -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports "$SLOWDNS_PORT"
    info "Redireccion SlowDNS 53 -> $SLOWDNS_PORT restaurada"
  fi

  # --- IPv6: cerrado salvo loopback ------------------------------------
  if [[ -n "$IPT6" ]]; then
    $IPT6 -P INPUT DROP 2>/dev/null
    $IPT6 -P FORWARD DROP 2>/dev/null
    $IPT6 -P OUTPUT ACCEPT 2>/dev/null
    $IPT6 -F 2>/dev/null
    $IPT6 -A INPUT -i lo -j ACCEPT 2>/dev/null
    $IPT6 -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
  fi

  persist_rules
  ok "Firewall aplicado"
  echo ""
  echo "  TCP abiertos: $(tcp_ports | tr '\n' ' ')"
  echo "  UDP abiertos: 53 (SlowDNS)"
  echo "  Proteccion  : SYN flood, malformados, connlimit por IP,"
  echo "                anti-fuerza-bruta (60s), port-scan (ban 5 min), ICMP"
}

# ---------------------------------------------------------------------
persist_rules() {
  mkdir -p /etc/iptables
  iptables-save  > "$RULES_V4" 2>/dev/null
  [[ -n "$IPT6" ]] && ip6tables-save > "$RULES_V6" 2>/dev/null
  chmod 600 "$RULES_V4" 2>/dev/null

  # Unidad propia: no dependemos de netfilter-persistent
  cat > /etc/systemd/system/nexo-firewall.service <<'UNIT'
[Unit]
Description=NexoTunnel firewall (restaura reglas iptables al arrancar)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables-restore < /etc/iptables/rules.v4'
ExecStart=/bin/sh -c '[ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6 || true'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null
  systemctl enable nexo-firewall.service >/dev/null 2>&1
}

# ---------------------------------------------------------------------
show_status() {
  header "Estado del Firewall"
  echo -e "${W}Politicas:${N}"
  $IPT -S | grep -E '^-P' | sed 's/^/  /'
  echo ""
  echo -e "${W}Puertos aceptados:${N}"
  $IPT -S INPUT | grep -oP '(?<=--dport )[0-9:]+' | sort -un | tr '\n' ' ' | sed 's/^/  /'
  echo ""
  echo ""
  echo -e "${W}Redirecciones nat:${N}"
  $IPT -t nat -S PREROUTING | grep -v '^-P' | sed 's/^/  /' || echo "  (ninguna)"
  echo ""
  echo -e "${W}Top 10 reglas por paquetes bloqueados:${N}"
  $IPT -nvxL INPUT 2>/dev/null | awk 'NR>2 && $3=="DROP" && $1>0 {print $1, $4, $NF}' \
    | sort -rn | head -10 | awk '{printf "  %-14s %s\n", $1" pkts", $2}'
  echo ""
  echo -e "${W}IPs en lista de port-scan:${N}"
  if [[ -f /proc/net/xt_recent/portscan ]]; then
    awk '{print "  " $1}' /proc/net/xt_recent/portscan 2>/dev/null | sed 's/src=//' | head -20
    local n; n=$(wc -l < /proc/net/xt_recent/portscan 2>/dev/null || echo 0)
    echo "  (total: $n)"
  else
    echo "  (sin datos)"
  fi
}

# ---------------------------------------------------------------------
reset_firewall() {
  warn "Abriendo TODO el firewall (modo rescate)"
  $IPT -P INPUT ACCEPT; $IPT -P FORWARD ACCEPT; $IPT -P OUTPUT ACCEPT
  $IPT -F; $IPT -X
  $IPT -t nat -F; $IPT -t nat -X
  $IPT -t mangle -F; $IPT -t mangle -X
  ok "Firewall abierto. Reaplica con: nexo-fw apply"
}

case "${1:-apply}" in
  apply)   apply_firewall ;;
  status)  show_status ;;
  persist) persist_rules; ok "Reglas guardadas" ;;
  reset)   reset_firewall ;;
  *)       echo "Uso: $(basename "$0") [apply|status|persist|reset]"; exit 1 ;;
esac
