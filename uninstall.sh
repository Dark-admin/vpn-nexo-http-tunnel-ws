#!/bin/bash
#==========================================
# NexoTunnel - Desinstalador
#
# Deja el servidor como estaba antes de instalar el panel.
#
# El orden NO es casual. Lo primero que se hace es abrir el firewall,
# antes de parar o borrar nada: si algo falla a mitad, el peor escenario
# es un servidor sin panel, no un servidor con politica DROP y sin las
# reglas que dejaban entrar por SSH.
#
# Y el sshd_config se restaura validandolo con `sshd -t` ANTES de
# reiniciar el servicio: una config rota ahi te deja fuera de la maquina
# sin manera de volver a entrar.
#
# Uso:
#   sudo ./uninstall.sh            quita el panel, conserva los paquetes
#   sudo ./uninstall.sh --purge    quita ademas nginx, dropbear, stunnel,
#                                  Xray y BadVPN (para reinstalar de cero)
#   sudo ./uninstall.sh --si       no pregunta
#==========================================

set -uo pipefail

[[ $EUID -ne 0 ]] && { echo "Requiere root: sudo $0"; exit 1; }

PURGAR=0
SIN_PREGUNTAR=0
for a in "$@"; do
  case "$a" in
    --purge) PURGAR=1 ;;
    --si|-y) SIN_PREGUNTAR=1 ;;
    *) echo "Opcion desconocida: $a"; exit 1 ;;
  esac
done

V=$'\033[0m'; R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;36m'
ok()   { echo "  ${G}✓${V} $*"; }
info() { echo "  ${B}·${V} $*"; }
warn() { echo "  ${Y}!${V} $*"; }
err()  { echo "  ${R}✗${V} $*"; }

echo ""
echo "${B}╔════════════════════════════════════════╗${V}"
echo "${B}║      NexoTunnel - Desinstalador        ║${V}"
echo "${B}╚════════════════════════════════════════╝${V}"
echo ""

# --- Que se va a borrar ------------------------------------------------
CUENTAS=""
if [[ -s /etc/nexotunnel/users.json ]] && command -v jq >/dev/null 2>&1; then
  CUENTAS=$(jq -r '.users[].user' /etc/nexotunnel/users.json 2>/dev/null | tr '\n' ' ')
fi

echo "  Se va a eliminar:"
echo "    - servicios, timers y unidades del panel"
echo "    - /usr/local/nexotunnel, /etc/nexotunnel, /var/log/nexotunnel"
echo "    - /var/lib/nexotunnel, configuraciones y backups de /root"
echo "    - los comandos nexo-* y menu"
echo "    - la configuracion de nginx, stunnel, fail2ban y sysctl del panel"
if [[ -n "$CUENTAS" ]]; then
  echo "    - ${Y}las cuentas de cliente:${V} $CUENTAS"
fi
if (( PURGAR )); then
  echo "    - ${Y}los paquetes:${V} nginx, dropbear, stunnel4, Xray, BadVPN"
fi
echo ""
echo "  Se conserva: OpenSSH y tu acceso al servidor."
echo ""

if (( ! SIN_PREGUNTAR )); then
  read -rp "  Escribe BORRAR para confirmar: " c
  [[ "$c" == "BORRAR" ]] || { echo "  Cancelado."; exit 0; }
  echo ""
fi

# --- 1. Abrir el firewall PRIMERO --------------------------------------
# Antes que nada. Si el script muriera a mitad, mejor un servidor abierto
# que uno inaccesible.
echo "${B}[1/8]${V} Abriendo el firewall"
if command -v iptables >/dev/null 2>&1; then
  iptables -P INPUT ACCEPT 2>/dev/null
  iptables -P FORWARD ACCEPT 2>/dev/null
  iptables -P OUTPUT ACCEPT 2>/dev/null
  iptables -F 2>/dev/null; iptables -X 2>/dev/null
  iptables -t nat -F 2>/dev/null; iptables -t nat -X 2>/dev/null
  iptables -t mangle -F 2>/dev/null; iptables -t mangle -X 2>/dev/null
  ok "iptables en ACCEPT y sin reglas"
fi
systemctl disable --now nexo-firewall.service >/dev/null 2>&1
rm -f /etc/systemd/system/nexo-firewall.service
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6
systemctl reset-failed nexo-firewall.service >/dev/null 2>&1

# --- 2. Restaurar sshd_config ------------------------------------------
echo "${B}[2/8]${V} Restaurando OpenSSH"
if [[ -f /etc/ssh/sshd_config.nexo-bak ]]; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.desinstalado 2>/dev/null
  cp /etc/ssh/sshd_config.nexo-bak /etc/ssh/sshd_config
  if sshd -t 2>/dev/null; then
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1
    rm -f /etc/ssh/sshd_config.nexo-bak
    ok "sshd_config original restaurado y validado"
  else
    # La copia de seguridad esta rota: se deja la que funciona ahora mismo
    cp /etc/ssh/sshd_config.desinstalado /etc/ssh/sshd_config
    warn "El backup de sshd_config no valida; se conserva el actual"
  fi
  rm -f /etc/ssh/sshd_config.desinstalado
else
  warn "No hay backup de sshd_config; se deja el actual sin tocar"
fi

# --- 3. Parar y borrar las unidades ------------------------------------
echo "${B}[3/8]${V} Parando servicios del panel"
UNIDADES=()
for f in /etc/systemd/system/nexo-px-*.service \
         /etc/systemd/system/badvpn-*.service \
         /etc/systemd/system/nexo-hproxy*.service; do
  [[ -e "$f" ]] && UNIDADES+=("$(basename "$f" .service)")
done
UNIDADES+=(nexo-slowdns nexo-expire.timer nexo-expire nexo-limits.timer nexo-limits
           nexo-bandwidth.timer nexo-bandwidth)

for u in "${UNIDADES[@]}"; do
  systemctl disable --now "$u" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$u.service" "/etc/systemd/system/$u"
  systemctl reset-failed "$u" >/dev/null 2>&1
done
# Los timers transitorios de las cuentas de prueba
for t in $(systemctl list-units 'nexo-trial-*' --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
  systemctl stop "$t" >/dev/null 2>&1
done

# Servicios de TERCEROS que el panel configuro. No son unidades nuestras,
# asi que no se borran; pero hay que PARARLOS antes de quitarles la
# configuracion. Si no, el proceso sigue vivo con el fichero ya borrado
# (lo tiene abierto en memoria), se queda con el puerto cogido y la
# reinstalacion falla con "address already in use" sin que se vea por que.
for s in stunnel4 nginx xray fail2ban dropbear; do
  systemctl stop "$s" >/dev/null 2>&1
done
# Red de seguridad por si alguno sobrevivio al stop.
#
# Los patrones van ANCLADOS con '^' a proposito. Un `pkill -f stunnel4` a
# secas tambien casa con la propia linea de comandos que lo invoca, asi
# que el shell se mata a si mismo y el resto del script no llega a
# ejecutarse (probado en carne propia). Con '^' solo casa el ejecutable.
pkill -f '^/usr/bin/stunnel4'   >/dev/null 2>&1
pkill -f '^/usr/bin/badvpn-udpgw' >/dev/null 2>&1
pkill -f '^/usr/bin/python3 /usr/bin/nexo-hproxy' >/dev/null 2>&1

systemctl daemon-reload >/dev/null 2>&1
ok "${#UNIDADES[@]} unidad(es) retiradas y servicios de terceros parados"

# --- 4. Cuentas de cliente ----------------------------------------------
echo "${B}[4/8]${V} Eliminando cuentas de cliente"
BORRADAS=0
for u in $CUENTAS; do
  [[ -z "$u" ]] && continue
  pkill -9 -u "$u" >/dev/null 2>&1
  userdel -f "$u" >/dev/null 2>&1 && BORRADAS=$(( BORRADAS + 1 ))
done
if (( BORRADAS > 0 )); then ok "$BORRADAS cuenta(s) eliminada(s)"; else info "ninguna"; fi

# --- 5. Ficheros del panel ----------------------------------------------
echo "${B}[5/8]${V} Borrando ficheros"
rm -rf /usr/local/nexotunnel /etc/nexotunnel /var/log/nexotunnel /var/lib/nexotunnel
rm -rf /root/nexotunnel-configs /root/nexotunnel-backups /var/www/nexotunnel
rm -f /usr/bin/nexo-hproxy
for c in menu nexo-add nexo-del nexo-renew nexo-trial nexo-list nexo-online \
         nexo-show nexo-limit nexo-payload nexo-puertos nexo-nginx nexo-xray \
         nexo-slowdns nexo-stunnel nexo-domain nexo-backup nexo-fw nexo-expire; do
  rm -f "/usr/bin/$c"
done
ok "directorios y comandos eliminados"

# --- 6. Configuraciones del sistema -------------------------------------
echo "${B}[6/8]${V} Revirtiendo configuraciones del sistema"
rm -f /etc/nginx/sites-available/nexotunnel /etc/nginx/sites-enabled/nexotunnel
rm -f /etc/nginx/conf.d/nexotunnel-map.conf
rm -f /etc/stunnel/nexotunnel.conf /etc/stunnel/nexotunnel.pem
rm -f /etc/logrotate.d/nexotunnel
rm -f /etc/sysctl.d/99-nexotunnel.conf
rm -f /etc/security/limits.d/99-nexotunnel.conf
rm -f /etc/systemd/system.conf.d/99-nexotunnel.conf
rm -f /etc/letsencrypt/renewal-hooks/deploy/nexotunnel.sh
rm -f /etc/fail2ban/jail.local
sysctl --system >/dev/null 2>&1

# Devolver nginx a su sitio por defecto para que no quede sin ninguno
if [[ -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi
if command -v nginx >/dev/null 2>&1 && (( ! PURGAR )); then
  nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1
fi
ok "configuraciones revertidas"

# --- 7. Paquetes (solo con --purge) -------------------------------------
echo "${B}[7/8]${V} Paquetes"
if (( PURGAR )); then
  if [[ -x /usr/local/bin/xray || -x /usr/local/bin/Xray ]] || command -v xray >/dev/null 2>&1; then
    info "Quitando Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
      @ remove --purge >/dev/null 2>&1 && ok "Xray eliminado" || warn "Xray: no se pudo quitar del todo"
    rm -rf /usr/local/etc/xray /var/log/xray
  fi
  rm -f /usr/bin/badvpn-udpgw /usr/local/bin/dnstt-server
  info "Quitando paquetes (puede tardar)..."
  DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    nginx nginx-common nginx-core dropbear dropbear-bin stunnel4 fail2ban \
    >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1
  rm -rf /etc/nginx /etc/stunnel /etc/default/dropbear
  ok "paquetes eliminados"
else
  info "conservados (usa --purge para quitarlos tambien)"
  rm -f /etc/default/dropbear
fi

# --- 8. Comprobacion -----------------------------------------------------
echo "${B}[8/8]${V} Comprobacion"
RESTOS=0
for r in /usr/local/nexotunnel /etc/nexotunnel /var/lib/nexotunnel /usr/bin/menu; do
  [[ -e "$r" ]] && { err "queda: $r"; RESTOS=$(( RESTOS + 1 )); }
done
for u in $(systemctl list-unit-files 'nexo-*' --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
  err "queda la unidad: $u"; RESTOS=$(( RESTOS + 1 ))
done

# Puertos del panel que sigan cogidos: es la señal de que algun proceso
# sobrevivio, y lo que hara fallar la reinstalacion.
for p in 80 443 444 109 143 8080 8880 10080 10001; do
  if ss -tlnH 2>/dev/null | awk -v p="$p" '{n=split($4,a,":"); if (a[n]==p) hallado=1} END{exit !hallado}'; then
    err "el puerto $p sigue ocupado por algo"
    RESTOS=$(( RESTOS + 1 ))
  fi
done
if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
  ok "OpenSSH sigue activo (tu acceso esta a salvo)"
else
  err "OpenSSH NO esta activo. NO CIERRES ESTA SESION."
  RESTOS=$(( RESTOS + 1 ))
fi

echo ""
if (( RESTOS == 0 )); then
  echo "${G}  Desinstalado por completo.${V}"
else
  echo "${Y}  Desinstalado con $RESTOS aviso(s); revisa lo marcado arriba.${V}"
fi
echo ""
echo "  El firewall quedo ABIERTO. Si no vas a reinstalar, ponle uno."
echo "  Para reinstalar:  sudo ./setup.sh"
echo ""
