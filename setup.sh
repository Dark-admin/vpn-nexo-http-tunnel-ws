#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Instalador
# Panel VPN para HTTP Custom / HTTP Injector
# Compatible: Debian 11/12/13, Ubuntu 22.04/24.04
#
# Instala TODO lo necesario y deja el panel funcionando. El orden es:
#
#   FASE 0  preguntas (todas juntas, para poder irse a hacer otra cosa)
#   FASE 1  apt update + apt upgrade del sistema
#   FASE 2  dependencias
#   FASE 3  componentes externos (Xray, dnstt) - las descargas largas
#   FASE 4  ajustes del sistema (zona horaria, sysctl/BBR, limites)
#   FASE 5  el panel y sus servicios
#   FASE 6  dominio y SlowDNS con lo respondido en la FASE 0
#   FASE 7  comprobacion: binarios, servicios y puertos a la escucha
#
# Reparto de puertos (uno y solo un dueño por puerto):
#
#    22        OpenSSH
#   109 / 143  Dropbear
#    80        nexo-hproxy   payload / WebSocket plano  (+ retos ACME)
#  8080 / 8880 nexo-hproxy   mismos, puertos alternativos
#   443        nginx TLS     wss + vmess/vless/trojan/grpc por ruta
#   444        stunnel       TLS crudo -> dropbear
#    53 udp    dnstt         SlowDNS
#  8081        nginx local   solo 127.0.0.1 (retos ACME y web)
# 10080        nexo-hproxy   solo 127.0.0.1 (el WSS del 443)
# 10001-10004  Xray          solo 127.0.0.1, detras de nginx
# 7100-7300    BadVPN UDPGW  solo 127.0.0.1, dentro del tunel
#==========================================

set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NEXO_INSTALL="/usr/local/nexotunnel"

source "$BASE_DIR/lib/common.sh"
need_root

# ======================================================================
# Comprobaciones previas
# ======================================================================
source /etc/os-release
case "$ID" in
  debian) [[ "$VERSION_ID" =~ ^(11|12|13)$ ]] || { err "Debian $VERSION_ID no soportado (usa 11/12/13)"; exit 1; } ;;
  ubuntu) [[ "$VERSION_ID" =~ ^(22.04|24.04)$ ]] || { err "Ubuntu $VERSION_ID no soportado (usa 22.04/24.04)"; exit 1; } ;;
  *)      err "SO no soportado: $ID"; exit 1 ;;
esac

if [[ "$(systemd-detect-virt 2>/dev/null)" == "openvz" ]]; then
  err "OpenVZ no soportado (no permite iptables ni systemd propios)"
  exit 1
fi

if [[ -f /.dockerenv ]] || grep -qa docker /proc/1/cgroup 2>/dev/null; then
  warn "Entorno Docker detectado: systemd puede no estar disponible"
fi

# Espacio en disco: compilar badvpn + dnstt con Go necesita sitio, y
# quedarse sin espacio a mitad deja el sistema de paquetes roto.
LIBRE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
if (( LIBRE_MB < 2048 )); then
  warn "Solo quedan ${LIBRE_MB}MB libres en /. Se recomiendan 2GB o mas."
  warn "Si instalas SlowDNS (compila Go) puede no caber."
fi

mkdir -p "$NEXO_CONF" "$NEXO_LOG" "$NEXO_STATE" "$NEXO_OUT" \
         "$NEXO_INSTALL"/{lib,bin,core,users,config} /var/www/nexotunnel
chmod 700 "$NEXO_STATE" "$NEXO_OUT"

LOG_INST="$NEXO_LOG/instalacion.log"
: > "$LOG_INST"

cls
echo -e "${C}"
echo "╔════════════════════════════════════════╗"
echo "║           NexoTunnel v1.0              ║"
echo "║     netfree · free to the world        ║"
echo "╚════════════════════════════════════════╝"
echo -e "${N}"
info "SO       : $PRETTY_NAME"
info "Arquit.  : $(uname -m)"
info "RAM      : $(free -m 2>/dev/null | awk '/^Mem:/ {print $2"MB"}' || echo '?')"
info "Disco    : ${LIBRE_MB}MB libres"
info "Origen   : $BASE_DIR"
info "Registro : $LOG_INST"
echo ""

# ======================================================================
# Utilidades del instalador
# ======================================================================

# Ejecuta un comando largo mandando la salida al log. Reintenta: el fallo
# mas comun al arrancar un VPS recien creado es que unattended-upgrades
# tiene cogido el lock de apt, y basta esperar un poco.
paso() {
  local desc="$1"; shift
  local intento=1 max=3 salida
  salida=$(mktemp)
  info "$desc"
  while (( intento <= max )); do
    echo "### $(date '+%F %T') [$intento/$max] $desc" >> "$LOG_INST"
    if "$@" > "$salida" 2>&1; then
      cat "$salida" >> "$LOG_INST"
      rm -f "$salida"
      ok "$desc"
      return 0
    fi
    cat "$salida" >> "$LOG_INST"

    # apt devuelve 100 tanto si el lock esta cogido como si el paquete no
    # existe. Reintentar lo primero tiene sentido; lo segundo no se va a
    # arreglar solo, y serian 30s de espera por cada grupo con un paquete
    # que ese repositorio no tiene. Se distinguen por el mensaje.
    if grep -qE 'Unable to locate package|has no installation candidate|Unable to correct problems' \
         "$salida"; then
      warn "$desc: algun paquete no esta en los repositorios (no reintento)"
      break
    fi

    if (( intento < max )); then
      warn "$desc: fallo, reintentando en 15s (¿apt ocupado?)"
      sleep 15
    fi
    intento=$(( intento + 1 ))
  done

  err "$desc: no se pudo completar"
  echo ""
  tail -n 12 "$salida" | sed 's/^/      /'
  echo ""
  rm -f "$salida"
  return 1
}

# apt-get sin una sola pregunta:
#  - DEBIAN_FRONTEND: nada de dialogos de configuracion
#  - force-confdef/confold: ante un fichero de config modificado, conserva
#    el tuyo en vez de parar a preguntar (un upgrade que pregunta y nadie
#    contesta deja la instalacion colgada para siempre)
#  - NEEDRESTART_MODE=a: Ubuntu 22.04+ pregunta que servicios reiniciar
apt_q() {
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
  apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

# Instala un grupo de paquetes; si el grupo entero falla, prueba uno a uno
# para que un solo paquete inexistente no tumbe la instalacion completa.
instalar() {
  local desc="$1"; shift
  local paquetes=("$@")
  if paso "$desc" apt_q install "${paquetes[@]}"; then
    return 0
  fi
  warn "Reintentando '$desc' paquete a paquete..."
  local p faltan=()
  for p in "${paquetes[@]}"; do
    if apt_q install "$p" >> "$LOG_INST" 2>&1; then
      echo "  ok  $p" >> "$LOG_INST"
    else
      faltan+=("$p")
    fi
  done
  if (( ${#faltan[@]} > 0 )); then
    warn "No se pudieron instalar: ${faltan[*]}"
    FALTANTES+=("${faltan[@]}")
    return 1
  fi
  ok "$desc (uno a uno)"
}

# Instala el PRIMER paquete de la lista que exista en este repositorio.
# Los nombres cambian entre versiones: en Debian 13 'dnsutils' ya no
# existe (es bind9-dnsutils) y 'dropbear-run' tampoco (es dropbear-bin).
# Sin esto, la instalacion se queda sin `dig` y domain.sh no puede validar
# el DNS antes de pedir el certificado.

# ¿Este repositorio ofrece ese paquete?
# Sin tuberia: `apt-cache policy X | grep -q` devuelve 141 bajo pipefail
# (SIGPIPE) y descarta paquetes que SI existen. Ver el aviso en common.sh.
paquete_existe() {
  local pol
  pol=$(apt-cache policy "$1" 2>/dev/null)
  [[ -n "$pol" ]] || return 1
  [[ "$pol" == *"Candidate: (none)"*    ]] && return 1
  [[ "$pol" == *"Candidato: (ninguno)"* ]] && return 1
  [[ "$pol" == *"Candidate: "* || "$pol" == *"Candidato: "* ]]
}

instalar_alguno() {
  local desc="$1"; shift
  local p
  for p in "$@"; do
    if paquete_existe "$p"; then
      if paso "$desc ($p)" apt_q install "$p"; then
        return 0
      fi
    fi
  done
  warn "$desc: ninguna de estas opciones sirvio: $*"
  FALTANTES+=("$1")
  return 1
}

FALTANTES=()

# ======================================================================
# FASE 0 - Preguntas
# ======================================================================
ui_top "FASE 0 - CONFIGURACION"
ui_line "Todo lo que hay que decidir, de una vez."
ui_line "Despues el instalador va solo."
ui_bottom
echo ""

read -rp " Zona horaria [America/Tegucigalpa]: " TZ_INPUT
TZ_INPUT="${TZ_INPUT:-America/Tegucigalpa}"

echo ""
info "Xray añade VMess, VLESS y Trojan sobre el mismo 443."
if ask_yes " ¿Instalar Xray? (S/n):" s; then Q_XRAY=1; else Q_XRAY=0; fi

echo ""
info "Con un dominio real obtienes certificado de Let's Encrypt. Sin el,"
info "el 443 usa un autofirmado: funciona, pero algunos filtros lo cortan."
Q_DOMINIO=""
Q_EMAIL=""
if ask_yes " ¿Tienes un dominio apuntando a este VPS? (s/N):" n; then
  while true; do
    read -rp " Dominio (ej: vpn.tudominio.com): " Q_DOMINIO
    if valid_domain "$Q_DOMINIO"; then break; fi
    err "Formato invalido."
  done
  read -rp " Email para avisos de caducidad (ENTER para omitir): " Q_EMAIL
fi

echo ""
info "SlowDNS tunela por consultas DNS. Necesita delegar un subdominio NS"
info "a este servidor, y compilar dnstt con Go (tarda unos minutos)."
Q_SLOWNS=""
if ask_yes " ¿Instalar SlowDNS? (s/N):" n; then
  while true; do
    read -rp " Subdominio NS delegado (ej: sdns.tudominio.com): " Q_SLOWNS
    if valid_domain "$Q_SLOWNS"; then break; fi
    err "Formato invalido."
  done
fi

echo ""
ui_top "RESUMEN"
ui_row "Zona"    "$TZ_INPUT"
ui_row "Xray"    "$( (( Q_XRAY )) && echo si || echo no )"
ui_row "Dominio" "${Q_DOMINIO:-no}"
ui_row "SlowDNS" "${Q_SLOWNS:-no}"
ui_bottom
echo ""
ask_yes " ¿Empezar la instalacion? (S/n):" s || { info "Cancelado"; exit 0; }
echo ""

# ======================================================================
# FASE 1 - Actualizar el sistema
# ======================================================================
echo ""
ui_top "FASE 1 - ACTUALIZAR EL SISTEMA"
ui_bottom

paso "apt update (indices de paquetes)" apt_q update \
  || { err "No se pueden leer los repositorios. Revisa la red o /etc/apt/sources.list"; exit 1; }

paso "apt upgrade (esto puede tardar varios minutos)" apt_q upgrade \
  || warn "El upgrade dio problemas; se continua (mira $LOG_INST)"

apt_q autoremove >> "$LOG_INST" 2>&1

# ======================================================================
# FASE 2 - Dependencias
# ======================================================================
echo ""
ui_top "FASE 2 - DEPENDENCIAS"
ui_bottom

# Base. procps es CRITICO aunque parezca de relleno: trae `ps`, `free`,
# `pkill` y `pgrep`, y de `ps` depende TODO el conteo de sesiones y el
# limite de multi-login. En imagenes minimas de VPS no viene.
instalar "Herramientas base" \
  ca-certificates curl wget gnupg unzip tar gzip \
  coreutils procps psmisc util-linux \
  sudo screen nano cron logrotate

instalar "Utilidades del panel" \
  jq qrencode openssl

instalar "Red y diagnostico" \
  iproute2 net-tools iputils-ping

# `dig`: bind9-dnsutils en Debian 12/13 y Ubuntu 22+; dnsutils en las viejas
instalar_alguno "Consultas DNS (dig)" bind9-dnsutils dnsutils

instalar "Firewall y proteccion" \
  iptables fail2ban

instalar "Servicios del tunel" \
  nginx python3 stunnel4

instalar "Certificados (Let's Encrypt)" \
  certbot

# El nombre del paquete de dropbear ha ido cambiando: 'dropbear' a secas,
# 'dropbear-run' en las intermedias, 'dropbear-bin' en Debian 13. Sin
# dropbear el panel sigue funcionando contra OpenSSH, pero aguanta
# bastantes menos sesiones simultaneas.
instalar_alguno "Dropbear" dropbear dropbear-run dropbear-bin \
  || warn "Sin dropbear: el proxy usara OpenSSH como backend"

# Compilador: hace falta para BadVPN (UDP dentro del tunel)
instalar "Compilador (BadVPN)" \
  build-essential cmake pkg-config

# NOTA: aqui NO se instala squid. Muchos paneles lo dejan con
# "acl localnet src 0.0.0.0/0" + "http_access allow all", o sea un proxy
# abierto a todo internet: atrae spam, llegan reportes de abuso y el
# proveedor suspende el VPS. El proxy del 80 ya hace de tunel y solo sabe
# llegar al SSH local.

# --- Verificacion de lo imprescindible --------------------------------
# Mas vale parar aqui que dejar un panel a medias que "arranca" pero no
# puede crear una sola cuenta.
ESENCIALES="python3 nginx openssl iptables jq curl awk sed ps"
FALTA_ESENCIAL=""
for b in $ESENCIALES; do
  command -v "$b" >/dev/null 2>&1 || FALTA_ESENCIAL+=" $b"
done
if [[ -n "$FALTA_ESENCIAL" ]]; then
  err "Faltan componentes imprescindibles:$FALTA_ESENCIAL"
  err "Revisa $LOG_INST y vuelve a lanzar el instalador."
  exit 1
fi
ok "Todas las dependencias imprescindibles presentes"

# ======================================================================
# FASE 3 - Componentes externos
# ======================================================================
echo ""
ui_top "FASE 3 - COMPONENTES EXTERNOS"
ui_bottom

# --- BadVPN UDPGW (UDP dentro del tunel: juegos, llamadas) -------------
if command -v badvpn-udpgw >/dev/null 2>&1; then
  ok "BadVPN ya instalado"
else
  info "Compilando BadVPN UDPGW..."
  tmp=$(mktemp -d)
  if wget -qO "$tmp/badvpn.zip" \
       https://github.com/ambrop72/badvpn/archive/refs/heads/master.zip 2>>"$LOG_INST"; then
    unzip -q "$tmp/badvpn.zip" -d "$tmp" 2>>"$LOG_INST"
    mkdir -p "$tmp/build" && cd "$tmp/build"
    cmake "$tmp/badvpn-master" -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >>"$LOG_INST" 2>&1
    make >>"$LOG_INST" 2>&1
    if [[ -f udpgw/badvpn-udpgw ]]; then
      install -m 755 udpgw/badvpn-udpgw /usr/bin/badvpn-udpgw
      ok "BadVPN compilado"
    else
      warn "No se pudo compilar BadVPN (el resto funciona; se pierde el UDP)"
    fi
    cd / && rm -rf "$tmp"
  else
    warn "No se pudo descargar BadVPN"
    rm -rf "$tmp"
  fi
fi

# --- Xray --------------------------------------------------------------
if (( Q_XRAY )); then
  if command -v xray >/dev/null 2>&1; then
    ok "Xray ya instalado ($(xray version 2>/dev/null | head -1))"
  else
    info "Instalando Xray (instalador oficial de XTLS)..."
    if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
         @ install >>"$LOG_INST" 2>&1; then
      ok "Xray instalado"
    else
      warn "No se pudo instalar Xray. Reintentalo luego con: nexo-xray install"
      Q_XRAY=0
    fi
  fi
fi

# --- Go + dnstt (SlowDNS) ---------------------------------------------
if [[ -n "$Q_SLOWNS" ]]; then
  instalar "Go (para compilar dnstt)" golang-go
  if command -v go >/dev/null 2>&1; then
    ok "Go $(go version 2>/dev/null | awk '{print $3}')"
  else
    warn "Sin Go no se puede compilar SlowDNS; se omitira"
    Q_SLOWNS=""
  fi
fi

# ======================================================================
# FASE 4 - Ajustes del sistema
# ======================================================================
echo ""
ui_top "FASE 4 - AJUSTES DEL SISTEMA"
ui_bottom

timedatectl set-timezone "$TZ_INPUT" 2>/dev/null \
  || ln -sf "/usr/share/zoneinfo/$TZ_INPUT" /etc/localtime 2>/dev/null
ok "Zona horaria: $TZ_INPUT"

# BBR + fq cambian mucho la sensacion en un tunel con perdida de paquetes
# (movil, 3G), que es el escenario de uso normal aqui.
info "Ajustando red (BBR, buffers, endurecimiento)..."
cat > /etc/sysctl.d/99-nexotunnel.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.netfilter.nf_conntrack_max = 262144

net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
modprobe tcp_bbr 2>/dev/null
modprobe nf_conntrack 2>/dev/null
sysctl --system >>"$LOG_INST" 2>&1
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
  ok "BBR activo"
else
  warn "BBR no disponible en este kernel (no es critico)"
fi

# Cada tunel son dos sockets: sin subir el limite, el VPS se queda sin
# descriptores mucho antes de quedarse sin CPU o RAM.
cat > /etc/security/limits.d/99-nexotunnel.conf <<'EOF'
*  soft  nofile  65535
*  hard  nofile  65535
root soft nofile 65535
root hard nofile 65535
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-nexotunnel.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=65535
EOF
ok "Limites de ficheros abiertos: 65535"

# ======================================================================
# FASE 5 - Panel y servicios
# ======================================================================
echo ""
ui_top "FASE 5 - PANEL Y SERVICIOS"
ui_bottom

info "Instalando en $NEXO_INSTALL..."
cp -f "$BASE_DIR/lib/"*.sh    "$NEXO_INSTALL/lib/"
cp -f "$BASE_DIR/bin/"*       "$NEXO_INSTALL/bin/"
cp -f "$BASE_DIR/core/"*.sh   "$NEXO_INSTALL/core/"
cp -f "$BASE_DIR/users/"*.sh  "$NEXO_INSTALL/users/"
cp -f "$BASE_DIR/config/"*.sh "$NEXO_INSTALL/config/"
cp -f "$BASE_DIR/menu.sh"     "$NEXO_INSTALL/menu.sh"
chmod 755 "$NEXO_INSTALL"/menu.sh "$NEXO_INSTALL"/{core,users,config}/*.sh "$NEXO_INSTALL"/bin/*
chmod 644 "$NEXO_INSTALL"/lib/*.sh
ok "Archivos instalados"

[[ -f "$NEXO_CONF/theme" ]] || echo "catppuccin" > "$NEXO_CONF/theme"

save_ports
load_ports
[[ -f "$PAYLOAD_CONF" ]] || save_payload
load_payload
write_hproxy_env

# Nunca pisar una base de datos existente: reinstalar encima no puede
# significar perder la cartera de clientes.
if [[ -s "$USERS_DB" ]]; then
  info "Base de datos existente conservada ($(jq '.users|length' "$USERS_DB" 2>/dev/null || echo '?') cuentas)"
else
  echo '{"users":[]}' > "$USERS_DB"
fi
chmod 600 "$USERS_DB"

# --- OpenSSH -----------------------------------------------------------
# sshd escucha SOLO en el 22. El 443 es de nginx y el 80 del proxy; que
# sshd tambien intente ocuparlos es lo que hace que uno de los dos muera
# con "address already in use".
info "Configurando OpenSSH (puerto $SSH_PORT)..."
[[ -f /etc/ssh/sshd_config && ! -f /etc/ssh/sshd_config.nexo-bak ]] \
  && cp /etc/ssh/sshd_config /etc/ssh/sshd_config.nexo-bak

cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
Protocol 2
AddressFamily inet

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

SyslogFacility AUTH
LogLevel INFO

LoginGraceTime 60
MaxAuthTries 4
MaxSessions 30
MaxStartups 40:60:150

PermitRootLogin yes
StrictModes yes
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
IgnoreRhosts yes
HostbasedAuthentication no
KbdInteractiveAuthentication no

# Imprescindible: es lo que hace de tunel
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
X11Forwarding no

ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
UseDNS no

PrintMotd no
PrintLastLog yes
Banner /etc/issue.net
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
AcceptEnv LANG LC_*
EOF

# Validar ANTES de reiniciar: con una config rota te quedas fuera del VPS
if sshd -t 2>/dev/null; then
  svc_quiet restart ssh || svc_quiet restart sshd
  ok "sshd validado y reiniciado"
else
  err "sshd_config invalido, restaurando backup"
  cp /etc/ssh/sshd_config.nexo-bak /etc/ssh/sshd_config
  sshd -t && systemctl restart ssh 2>/dev/null
fi

# --- Banner ------------------------------------------------------------
cat > /etc/issue.net <<'EOF'

  ==========================================
        N E X O T U N N E L
  ==========================================
    Acceso solo para cuentas autorizadas.
    Prohibido el spam, el abuso y el
    escaneo de redes ajenas.
  ==========================================

EOF

# --- Dropbear ----------------------------------------------------------
if command -v dropbear >/dev/null 2>&1 || hay_unidad dropbear; then
  info "Configurando Dropbear ($DROPBEAR_PORT1, $DROPBEAR_PORT2)..."
  cat > /etc/default/dropbear <<EOF
NO_START=0
DROPBEAR_PORT=$DROPBEAR_PORT1
DROPBEAR_EXTRA_ARGS="-p $DROPBEAR_PORT2"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
EOF
  grep -q '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
  grep -q '/usr/sbin/nologin' /etc/shells || echo '/usr/sbin/nologin' >> /etc/shells
  svc enable dropbear
  svc restart dropbear
fi

# --- Nginx (443 TLS) ---------------------------------------------------
# VA ANTES DEL PROXY A PROPOSITO. Al instalar el paquete, Debian arranca
# nginx con su sitio por defecto escuchando en el 80. Si aqui lanzaramos
# primero nexo-hproxy, se encontraria el 80 ocupado y moriria con
# "Address already in use". nginx.sh borra ese sitio por defecto y deja
# nginx solo en el 443 y en el 8081 local, liberando el 80.
info "Configurando Nginx..."
bash "$NEXO_INSTALL/core/nginx.sh" apply

# --- Proxy de payload / WebSocket --------------------------------------
info "Instalando nexo-hproxy (payload / WebSocket)..."
install -m 755 "$NEXO_INSTALL/bin/nexo-hproxy.py" /usr/bin/nexo-hproxy
touch "$NEXO_LOG/hproxy.log"

# Backend preferido: dropbear, que aguanta mejor cientos de sesiones
# cortas en un VPS pequeño. Si no se pudo instalar, se cae a OpenSSH: sin
# esta comprobacion el tunel quedaria apuntando a un puerto muerto y el
# panel diria que todo esta "activo".
if hay_unidad dropbear; then
  HP_BACKEND=$DROPBEAR_PORT1
else
  HP_BACKEND=$SSH_PORT
  warn "Dropbear ausente: el proxy usara OpenSSH ($SSH_PORT) como backend"
fi

# Los proxies ya NO se escriben aqui: viven en proxies.conf y se editan
# desde el panel (menu -> Puertos y proxies). Reinstalar no puede pisar
# los puertos que el revendedor haya ajustado a su operador.
if [[ -s "$PROXIES_CONF" ]]; then
  info "Proxies existentes conservados ($(px_list | wc -l) configurados)"
else
  info "Creando los proxies por defecto (80, 8080, 8880 + interno del WSS)..."
  cat > "$PROXIES_CONF" <<EOF
# NexoTunnel - proxies de payload / WebSocket
# Editalo desde el panel:  menu -> Puertos y proxies   (o: sudo nexo-puertos)
#
#   nombre|esc_host|esc_puerto|dst_host|dst_puerto|respuesta|acme|descripcion
#
# respuesta: "panel" usa la del panel; o una linea literal (HTTP/1.1 200 OK)
# acme     : puerto del nginx local para Let's Encrypt (0 = no)
#
ws80|0.0.0.0|$HTTP_PORT|127.0.0.1|$HP_BACKEND|panel|$NGINX_LOCAL|Payload/WS principal (reenvia los retos de Let's Encrypt)
ws8080|0.0.0.0|$HTTP_ALT1|127.0.0.1|$HP_BACKEND|panel|0|Payload/WS alterno
ws8880|0.0.0.0|$HTTP_ALT2|127.0.0.1|$HP_BACKEND|panel|0|Payload/WS alterno
wstls|127.0.0.1|$WS_INTERNAL|127.0.0.1|$HP_BACKEND|HTTP/1.1 101 Switching Protocols|0|Interno: nginx lo usa para el WSS del 443
EOF
  chmod 644 "$PROXIES_CONF"
fi

# La respuesta del proxy interno va clavada a proposito: nginx necesita ver
# un 101 para hacer el upgrade, y si compartiera la respuesta configurable
# del panel, cambiarla a "200 OK" tumbaria el WSS sin avisar.
px_apply

# --- BadVPN ------------------------------------------------------------
# Las unidades las genera badvpn_apply (lib/common.sh), la misma funcion
# que usa el panel al cambiar los puertos. Duplicar la plantilla aqui es
# como acaban discrepando el instalador y el gestor.
if command -v badvpn-udpgw >/dev/null 2>&1; then
  badvpn_apply
  ok "BadVPN en 127.0.0.1: $(echo "$BADVPN_PORTS" | tr ' ' ',')"
fi

# --- Stunnel -----------------------------------------------------------
info "Configurando Stunnel..."
bash "$NEXO_INSTALL/core/stunnel.sh" apply

# --- Xray --------------------------------------------------------------
if (( Q_XRAY )) && command -v xray >/dev/null 2>&1; then
  bash "$NEXO_INSTALL/core/xray.sh" sync
fi

# --- Fail2Ban ----------------------------------------------------------
info "Configurando Fail2Ban..."
AUTH_LOG="/var/log/auth.log"; [[ -f "$AUTH_LOG" ]] || AUTH_LOG="/var/log/syslog"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 86400
findtime = 600
maxretry = 5
backend  = auto
banaction = iptables-multiport
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = $SSH_PORT
logpath  = $AUTH_LOG
maxretry = 5
findtime = 300

[dropbear]
enabled  = true
port     = $DROPBEAR_PORT1,$DROPBEAR_PORT2
logpath  = $AUTH_LOG
maxretry = 5

[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
maxretry  = 3
findtime  = 86400
bantime   = 604800
banaction = iptables-allports
EOF
svc restart fail2ban

# --- Rotacion de logs --------------------------------------------------
# El access.log de Xray crece MUCHO (una linea por conexion aceptada) y
# hproxy.log tambien. En un VPS de 10-20 GB llenan el disco en semanas, y
# cuando el disco se llena no arranca nada y parece que "se rompio solo".
info "Configurando rotacion de logs..."
cat > /etc/logrotate.d/nexotunnel <<EOF
$NEXO_LOG/*.log {
    daily
    rotate 7
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}

/var/log/xray/*.log {
    daily
    rotate 5
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
# copytruncate y no create: los servicios mantienen el fichero abierto y
# con 'create' seguirian escribiendo en el inodo viejo (log fantasma que
# ocupa disco y no se ve con ls).
ok "logrotate configurado"

# --- Timers ------------------------------------------------------------
info "Configurando tareas automaticas..."

cat > /etc/systemd/system/nexo-expire.service <<EOF
[Unit]
Description=NexoTunnel - borrar cuentas vencidas
[Service]
Type=oneshot
ExecStart=$NEXO_INSTALL/bin/nexo-expire.sh
EOF
cat > /etc/systemd/system/nexo-expire.timer <<'EOF'
[Unit]
Description=NexoTunnel - limpieza de vencidas cada hora
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/nexo-limits.service <<EOF
[Unit]
Description=NexoTunnel - aplicar limites de multi-login
[Service]
Type=oneshot
ExecStart=$NEXO_INSTALL/bin/nexo-limits.sh
EOF
cat > /etc/systemd/system/nexo-limits.timer <<'EOF'
[Unit]
Description=NexoTunnel - control de multi-login cada minuto
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload 2>/dev/null
for t in nexo-expire nexo-limits; do
  systemctl enable --now "$t.timer" >/dev/null 2>&1 && ok "timer $t activo" \
    || warn "timer $t no se pudo activar"
done

# --- Comandos ----------------------------------------------------------
info "Creando comandos..."
ln -sf "$NEXO_INSTALL/menu.sh"            /usr/bin/menu
ln -sf "$NEXO_INSTALL/users/add.sh"       /usr/bin/nexo-add
ln -sf "$NEXO_INSTALL/users/del.sh"       /usr/bin/nexo-del
ln -sf "$NEXO_INSTALL/users/renew.sh"     /usr/bin/nexo-renew
ln -sf "$NEXO_INSTALL/users/trial.sh"     /usr/bin/nexo-trial
ln -sf "$NEXO_INSTALL/users/list.sh"      /usr/bin/nexo-list
ln -sf "$NEXO_INSTALL/users/online.sh"    /usr/bin/nexo-online
ln -sf "$NEXO_INSTALL/users/show.sh"      /usr/bin/nexo-show
ln -sf "$NEXO_INSTALL/users/limit.sh"     /usr/bin/nexo-limit
ln -sf "$NEXO_INSTALL/core/payload.sh"    /usr/bin/nexo-payload
ln -sf "$NEXO_INSTALL/core/puertos.sh"    /usr/bin/nexo-puertos
ln -sf "$NEXO_INSTALL/core/nginx.sh"      /usr/bin/nexo-nginx
ln -sf "$NEXO_INSTALL/core/xray.sh"       /usr/bin/nexo-xray
ln -sf "$NEXO_INSTALL/core/slowdns.sh"    /usr/bin/nexo-slowdns
ln -sf "$NEXO_INSTALL/core/stunnel.sh"    /usr/bin/nexo-stunnel
ln -sf "$NEXO_INSTALL/core/domain.sh"     /usr/bin/nexo-domain
ln -sf "$NEXO_INSTALL/core/backup.sh"     /usr/bin/nexo-backup
ln -sf "$NEXO_INSTALL/config/firewall.sh" /usr/bin/nexo-fw
ln -sf "$NEXO_INSTALL/bin/nexo-expire.sh" /usr/bin/nexo-expire
ok "Comandos disponibles (menu, nexo-add, nexo-payload, ...)"

# --- Firewall ----------------------------------------------------------
bash "$NEXO_INSTALL/config/firewall.sh" apply

# ======================================================================
# FASE 6 - Dominio y SlowDNS
# ======================================================================
if [[ -n "$Q_DOMINIO" || -n "$Q_SLOWNS" ]]; then
  echo ""
  ui_top "FASE 6 - DOMINIO Y SLOWDNS"
  ui_bottom
fi

if [[ -n "$Q_DOMINIO" ]]; then
  # domain.sh lee estas variables y no vuelve a preguntar
  NEXO_DOMAIN="$Q_DOMINIO" NEXO_EMAIL="$Q_EMAIL" \
    bash "$NEXO_INSTALL/core/domain.sh"
fi

if [[ -n "$Q_SLOWNS" ]]; then
  NEXO_SLOWDNS_NS="$Q_SLOWNS" \
    bash "$NEXO_INSTALL/core/slowdns.sh" apply
fi

# ======================================================================
# FASE 7 - Comprobacion
# ======================================================================
echo ""
ui_top "FASE 7 - COMPROBACION"
ui_bottom

PROBLEMAS=0

comprobar_servicio() {
  local unidad="$1" etiqueta="$2" critico="${3:-si}"
  if systemctl is-active "$unidad" >/dev/null 2>&1; then
    ui_status_row "$etiqueta" ok "activo"
  elif ! hay_unidad "$unidad"; then
    ui_status_row "$etiqueta" off "no instalado"
  else
    ui_status_row "$etiqueta" err "DETENIDO"
    [[ "$critico" == "si" ]] && PROBLEMAS=$(( PROBLEMAS + 1 ))
  fi
}

comprobar_puerto() {
  local puerto="$1" etiqueta="$2" proto="${3:-tcp}" critico="${4:-si}"
  if puerto_escucha "$puerto" "$proto"; then
    ui_status_row "$etiqueta" ok "$proto/$puerto"
    return
  fi
  ui_status_row "$etiqueta" err "$proto/$puerto CERRADO"
  [[ "$critico" == "si" ]] && PROBLEMAS=$(( PROBLEMAS + 1 ))
}

ui_top "SERVICIOS"
comprobar_servicio ssh          "OpenSSH"
comprobar_servicio dropbear     "Dropbear"       no
for _u in $(px_unidades); do
  comprobar_servicio "$_u" "${_u#$PX_PREFIJO-}"
done
comprobar_servicio nginx        "Nginx TLS"
comprobar_servicio stunnel4     "Stunnel"        no
comprobar_servicio xray         "Xray"           no
comprobar_servicio nexo-slowdns "SlowDNS"        no
comprobar_servicio fail2ban     "Fail2Ban"       no
ui_bottom

echo ""
ui_top "PUERTOS A LA ESCUCHA"
comprobar_puerto "$SSH_PORT"    "OpenSSH"
while IFS='|' read -r _n _eh _ep _dh _dp _r _a _d; do
  [[ -z "$_n" ]] && continue
  comprobar_puerto "$_ep" "proxy $_n"
done < <(px_list)
comprobar_puerto "$TLS_PORT"    "TLS 443"
comprobar_puerto "$STUNNEL_PORT" "SSL crudo"     tcp no
[[ -n "$Q_SLOWNS" ]] && comprobar_puerto "$SLOWDNS_PORT" "SlowDNS" udp no
ui_bottom

echo ""
ui_top "HERRAMIENTAS"
for b in python3 nginx jq qrencode openssl curl dig logrotate iptables; do
  if command -v "$b" >/dev/null 2>&1; then
    ui_status_row "$b" ok "instalado"
  else
    ui_status_row "$b" err "FALTA"
    PROBLEMAS=$(( PROBLEMAS + 1 ))
  fi
done
ui_bottom

if (( ${#FALTANTES[@]} > 0 )); then
  echo ""
  warn "Paquetes que no se pudieron instalar: ${FALTANTES[*]}"
fi

# ======================================================================
# Resumen
# ======================================================================
load_ports; load_payload
IP=$(get_ip)
DOM=$(get_domain)
echo ""
if (( PROBLEMAS == 0 )); then
  echo -e "${G}"
  echo "╔════════════════════════════════════════╗"
  echo "║   NexoTunnel v1.0 - TODO CORRECTO      ║"
  echo "╚════════════════════════════════════════╝"
  echo -e "${N}"
else
  echo -e "${Y}"
  echo "╔════════════════════════════════════════╗"
  echo "║   NexoTunnel instalado con $PROBLEMAS aviso(s)   ║"
  echo "╚════════════════════════════════════════╝"
  echo -e "${N}"
  warn "Revisa arriba lo marcado en rojo y el registro: $LOG_INST"
  warn "Para reintentar servicios: menu -> Transportes -> Reiniciar"
fi

echo "  IP publica : $IP"
[[ -n "$DOM" ]] && echo "  Dominio    : $DOM"
echo ""
echo -e "  ${W}Para el cliente (HTTP Custom / Injector):${N}"
printf "    %-18s %s\n" "SSH directo"     "$IP:$SSH_PORT"
printf "    %-18s %s\n" "Dropbear"        "$IP:$DROPBEAR_PORT1, $IP:$DROPBEAR_PORT2"
printf "    %-18s %s\n" "Payload / WS"    "$IP:$HTTP_PORT, :$HTTP_ALT1, :$HTTP_ALT2"
printf "    %-18s %s\n" "WebSocket TLS"   "wss://${DOM:-$IP}:$TLS_PORT$WS_PATH"
printf "    %-18s %s\n" "SSL/TLS crudo"   "${DOM:-$IP}:$STUNNEL_PORT"
if (( Q_XRAY )); then
printf "    %-18s %s\n" "VMess / VLESS"   "${DOM:-$IP}:$TLS_PORT  rutas /vmess /vless"
printf "    %-18s %s\n" "Trojan / gRPC"   "${DOM:-$IP}:$TLS_PORT  ruta /trojan, servicio nexo-grpc"
fi
[[ -n "$Q_SLOWNS" ]] && printf "    %-18s %s\n" "SlowDNS" "$Q_SLOWNS (ver: nexo-slowdns status)"
echo ""
echo -e "  Abre el panel con:          ${W}sudo menu${N}"
echo -e "  Crea la primera cuenta con: ${W}sudo nexo-add${N}"
echo ""
if [[ -z "$BUG_HOST" && -z "$SNI_HOST" ]]; then
  warn "Aun no has definido bug host ni SNI. Configuralos en:"
  warn "  menu -> Payload / Bug / SNI     (o: sudo nexo-payload)"
  echo ""
fi

echo -e "${Y}Se recomienda reiniciar: aplica BBR, los limites y el kernel nuevo.${N}"
if ask_yes "¿Reiniciar ahora? (s/N):" n; then
  reboot
else
  info "Reinicia cuando puedas con: sudo reboot"
fi
