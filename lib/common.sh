#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Libreria comun
# Todos los scripts hacen: source .../lib/common.sh
#==========================================

# --- Rutas canonicas ---------------------------------------------------
NEXO_INSTALL="${NEXO_INSTALL:-/usr/local/nexotunnel}"
NEXO_CONF="${NEXO_CONF:-/etc/nexotunnel}"
NEXO_LOG="${NEXO_LOG:-/var/log/nexotunnel}"
NEXO_STATE="${NEXO_STATE:-/var/lib/nexotunnel}"
NEXO_OUT="${NEXO_OUT:-/root/nexotunnel-configs}"

PORTS_CONF="$NEXO_CONF/ports.conf"
PAYLOAD_CONF="$NEXO_CONF/payload.conf"
LIMITS_CONF="$NEXO_CONF/limits.conf"
DOMAIN_FILE="$NEXO_CONF/domain"
IP_CACHE="$NEXO_STATE/ip.cache"

USERS_DB="$NEXO_CONF/users.json"
XRAY_CONF="/usr/local/etc/xray/config.json"

# --- Interfaz ----------------------------------------------------------
_UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_UI_DIR/ui.sh" ]]; then
  source "$_UI_DIR/ui.sh"
else
  source "$NEXO_INSTALL/lib/ui.sh"
fi

R="$C_ERR"; G="$C_OK"; Y="$C_WARN"
B="$C_INFO"; C="$C_ACCENT"; W="$C_TEXT"; N="$C_RESET"

info() { ui_info "$*"; }
ok()   { ui_ok   "$*"; }
warn() { ui_warn "$*"; }
err()  { ui_err  "$*"; }

cls()   { ui_clear; }
pause() { ui_pause; }

# Cabecera de pantalla. Antes era una caja de tres lineas con el titulo
# dentro; ahora son migas de pan de una sola linea: ocupa un tercio (en
# Termux eso es media pantalla) y ademas dice DONDE estas, no solo como se
# llama la pantalla. Acepta varios niveles: header "Cuentas" "Crear".
header() {
  ui_crumbs "$@"
  echo ""
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Este comando requiere root. Usa: sudo $(basename "$0")"
    exit 1
  fi
}

# --- Validacion --------------------------------------------------------
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_number()   { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_port()     { valid_number "$1" && (( $1 >= 1 && $1 <= 65535 )); }
valid_domain()   { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; }
valid_uuid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# Una ruta WebSocket: /algo, sin espacios ni comodines. Se exige al menos
# un caracter despues de la barra: un WS_PATH de "/" haria que el bloque
# de nginx se tragara /vmess, /vless y la web entera.
valid_wspath()   { [[ "$1" =~ ^/[A-Za-z0-9_-][A-Za-z0-9_./-]{0,62}$ ]]; }

ask_valid() {
  local __var="$1" __prompt="$2" __fn="$3" __val=""
  while true; do
    read -rp "$__prompt" __val
    if "$__fn" "$__val"; then
      printf -v "$__var" '%s' "$__val"
      return 0
    fi
    err "Valor invalido, intenta de nuevo."
  done
}

ask_password() {
  local __var="$1" p1 p2
  while true; do
    read -rsp "Contraseña: " p1; echo ""
    if [[ ${#p1} -lt 4 ]]; then
      err "Minimo 4 caracteres."
      continue
    fi
    read -rsp "Confirmar   : " p2; echo ""
    if [[ "$p1" == "$p2" ]]; then
      printf -v "$__var" '%s' "$p1"
      return 0
    fi
    err "No coinciden."
  done
}

# Confirmacion s/n con valor por defecto
ask_yes() {
  local prompt="$1" def="${2:-n}" ans
  read -rp "$prompt " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[sSyY]$ ]]
}

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    # Fallback sin uuidgen: v4 armado a mano desde /dev/urandom
    local h; h=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    printf '%s-%s-4%s-a%s-%s\n' \
      "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  fi
}

# --- Puertos -----------------------------------------------------------
# Cada puerto tiene UN solo dueño. Es el error clasico de estos paneles:
# poner sshd, stunnel y sslh a la vez en el 443 y que solo arranque uno.
#
#   80  -> nexo-hproxy   (payload / WebSocket plano; ACME pasa a nginx)
#   443 -> nginx TLS     (wss + vmess/vless/trojan/grpc por rutas)
#   444 -> stunnel       (TLS crudo -> dropbear, modo "SSH + SSL")
#   8081-> nginx local   (solo 127.0.0.1: retos ACME y web)
SSH_PORT=22
DROPBEAR_PORT1=109
DROPBEAR_PORT2=143
HTTP_PORT=80
HTTP_ALT1=8080
HTTP_ALT2=8880
WS_INTERNAL=10080
TLS_PORT=443
STUNNEL_PORT=444
NGINX_LOCAL=8081
XRAY_VMESS=10001
XRAY_VLESS=10002
XRAY_TROJAN=10003
XRAY_GRPC=10004
SLOWDNS_PORT=5300
BADVPN_PORTS="7100 7200 7300"

load_ports() {
  # shellcheck disable=SC1090
  [[ -f "$PORTS_CONF" ]] && source "$PORTS_CONF"
}

save_ports() {
  mkdir -p "$NEXO_CONF"
  cat > "$PORTS_CONF" <<EOF
# NexoTunnel - puertos activos. Tras cambiar algo: nexo-fw apply
SSH_PORT=$SSH_PORT
DROPBEAR_PORT1=$DROPBEAR_PORT1
DROPBEAR_PORT2=$DROPBEAR_PORT2
HTTP_PORT=$HTTP_PORT
HTTP_ALT1=$HTTP_ALT1
HTTP_ALT2=$HTTP_ALT2
WS_INTERNAL=$WS_INTERNAL
TLS_PORT=$TLS_PORT
STUNNEL_PORT=$STUNNEL_PORT
NGINX_LOCAL=$NGINX_LOCAL
XRAY_VMESS=$XRAY_VMESS
XRAY_VLESS=$XRAY_VLESS
XRAY_TROJAN=$XRAY_TROJAN
XRAY_GRPC=$XRAY_GRPC
SLOWDNS_PORT=$SLOWDNS_PORT
BADVPN_PORTS="$BADVPN_PORTS"
EOF
  chmod 644 "$PORTS_CONF"
}

# Puertos TCP que el firewall abre al exterior. Los inbounds de Xray
# (10001-10004) y nginx local (8081) escuchan en 127.0.0.1 y NO se abren:
# se llega a ellos solo a traves del 443.
#
# Los puertos de los proxies ya NO estan fijos aqui: salen de
# proxies.conf, para que abrir uno nuevo desde el panel actualice el
# firewall solo. Si hubiera que acordarse de tocar el firewall a mano, el
# proxy nuevo escucharia y nadie llegaria a el.
tcp_ports() {
  load_ports
  {
    echo "$SSH_PORT $DROPBEAR_PORT1 $DROPBEAR_PORT2 $TLS_PORT $STUNNEL_PORT" \
      | tr ' ' '\n'
    px_puertos_publicos 2>/dev/null
  } | grep -E '^[0-9]+$' | sort -un
}

# --- Payload / bug host ------------------------------------------------
BUG_HOST=""
SNI_HOST=""
WS_PATH="/nexo"
HTTP_RESPONSE="HTTP/1.1 101 Switching Protocols"

load_payload() {
  # shellcheck disable=SC1090
  [[ -f "$PAYLOAD_CONF" ]] && source "$PAYLOAD_CONF"
}

save_payload() {
  mkdir -p "$NEXO_CONF"
  cat > "$PAYLOAD_CONF" <<EOF
# NexoTunnel - datos que se imprimen en las configuraciones de cliente.
# BUG_HOST : host que va en la cabecera del payload (HTTP Injector/Custom)
# SNI_HOST : servername que se envia en el handshake TLS
# WS_PATH  : ruta WebSocket del tunel SSH detras de nginx
# HTTP_RESPONSE : primera linea que responde nexo-hproxy al inyector
BUG_HOST="$BUG_HOST"
SNI_HOST="$SNI_HOST"
WS_PATH="$WS_PATH"
HTTP_RESPONSE="$HTTP_RESPONSE"
EOF
  chmod 644 "$PAYLOAD_CONF"
}

# Las tres instancias de nexo-hproxy leen la respuesta HTTP de un mismo
# EnvironmentFile. Asi cambiar la respuesta desde el panel es reescribir
# un fichero y reiniciar, sin regenerar unidades de systemd.
write_hproxy_env() {
  mkdir -p "$NEXO_CONF"
  # El valor va entrecomillado: lleva espacios y a veces un '|' para
  # encadenar dos respuestas. systemd quita las comillas al leerlo.
  cat > "$NEXO_CONF/hproxy.env" <<EOF
# Generado por NexoTunnel. Lo leen las unidades nexo-hproxy*.
HP_RESPONSE="$HTTP_RESPONSE"
EOF
  chmod 644 "$NEXO_CONF/hproxy.env"
}

restart_hproxy() { px_restart; }

# --- BadVPN UDPGW ------------------------------------------------------
# Regenera las unidades a partir de $BADVPN_PORTS y retira las que sobren.
# Vive aqui y no en setup.sh porque el panel tambien cambia estos puertos:
# si cada uno los escribiera por su lado, acabarian discrepando.
#
# Escuchan SOLO en 127.0.0.1 a proposito: se llega a ellos DENTRO del tunel
# SSH, no desde internet. Por eso el firewall no los abre. El cliente los
# apunta en su campo "UDPGW" como 127.0.0.1:<puerto>.
badvpn_apply() {
  load_ports
  if ! command -v badvpn-udpgw >/dev/null 2>&1; then
    warn "BadVPN no esta instalado; no hay nada que aplicar"
    return 1
  fi

  local vivos=() port f base v sigue
  for port in $BADVPN_PORTS; do
    valid_port "$port" || continue
    # OJO: udpgw escucha en TCP, no en UDP. El cliente le habla por TCP
    # DENTRO del tunel y es el quien saca el UDP real hacia internet. Por
    # eso se comprueba con `ss -tlnp` y no con `ss -ulnp`.
    #
    # DynamicUser en vez de User=nobody: systemd avisa de que 'nobody' es
    # un usuario compartido por medio sistema ("Special user nobody
    # configured, this is not safe!"). DynamicUser le da uno propio y
    # efimero, y udpgw no necesita escribir en ningun sitio.
    cat > "/etc/systemd/system/badvpn-$port.service" <<UNIT
[Unit]
Description=BadVPN UDPGW 127.0.0.1:$port (UDP dentro del tunel)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:$port --max-clients 400 --max-connections-for-client 20
Restart=always
RestartSec=3
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT
    vivos+=("badvpn-$port")
  done

  # Unidades de puertos que ya no estan en la lista: si se quedan, siguen
  # escuchando y el panel mostraria un puerto que ya no anuncia a nadie.
  for f in /etc/systemd/system/badvpn-*.service; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f" .service)
    sigue=0
    for v in "${vivos[@]}"; do [[ "$v" == "$base" ]] && sigue=1; done
    if (( ! sigue )); then
      systemctl disable --now "$base" >/dev/null 2>&1
      rm -f "$f"
      # Sin reset-failed, systemd conserva la unidad como "not-found
      # failed" para siempre y `systemctl --failed` queda lleno de basura
      # que hace pensar que algo va mal.
      systemctl reset-failed "$base" >/dev/null 2>&1
      info "BadVPN retirado: ${base#badvpn-}"
    fi
  done

  systemctl daemon-reload 2>/dev/null
  for v in "${vivos[@]}"; do
    systemctl enable "$v" >/dev/null 2>&1
    systemctl restart "$v" >/dev/null 2>&1 \
      && ok "${v#badvpn-}: activo" \
      || err "${v#badvpn-}: no arranco"
  done
}

# Host que se usa para conectar: dominio si lo hay, si no la IP
conn_host() {
  local d; d=$(get_domain)
  [[ -n "$d" ]] && { echo "$d"; return; }
  get_ip
}

# --- Red ---------------------------------------------------------------
get_ip() {
  local ip=""
  if [[ -f "$IP_CACHE" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$IP_CACHE" 2>/dev/null || echo 0) ))
    if (( age < 3600 )); then
      ip=$(cat "$IP_CACHE")
    fi
  fi
  if [[ -z "$ip" ]]; then
    ip=$(curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null \
         || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
         || wget -qO- --timeout=5 https://ipinfo.io/ip 2>/dev/null)
    if [[ -n "$ip" ]]; then
      mkdir -p "$NEXO_STATE"
      echo "$ip" > "$IP_CACHE"
    fi
  fi
  [[ -z "$ip" ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  echo "${ip:-0.0.0.0}"
}

get_domain() { cat "$DOMAIN_FILE" 2>/dev/null || echo ""; }

# --- Usuarios del sistema ----------------------------------------------
list_ssh_users() {
  awk -F: '$3>=1000 && $3!=65534 {print $1}' /etc/passwd 2>/dev/null | grep -v '^nobody$'
}

user_expiry() {
  local exp
  exp=$(chage -l "$1" 2>/dev/null | awk -F: '/Account expires/ {gsub(/^[ \t]+/,"",$2); print $2}')
  [[ -z "$exp" || "$exp" == "never" ]] && { echo "never"; return; }
  date -d "$exp" +%Y-%m-%d 2>/dev/null || echo "never"
}

# Dias que le quedan a una cuenta.
#
# Se redondea hacia ARRIBA a proposito. La expiracion cae a medianoche, asi
# que una cuenta de 7 dias creada a las 22:30 tiene 6,06 dias reales y una
# division entera mostraria 6: acabas de cobrar una semana y el panel dice
# seis. Con el redondeo hacia arriba muestra 7, que es lo que el cliente
# entiende por "le quedan 7 dias".
# Las vencidas siguen saliendo en negativo, para que se vean como tales.
days_left() {
  local d="$1"
  [[ "$d" == "never" || -z "$d" ]] && { echo "-"; return; }
  local e n s; e=$(date -d "$d" +%s 2>/dev/null) || { echo "-"; return; }
  # printf %(%s)T es un builtin de bash: da la hora actual sin lanzar un
  # proceso. Llamado una vez por cuenta en el listado, ahorra tantos
  # procesos como cuentas haya.
  printf -v n '%(%s)T' -1
  s=$(( e - n ))
  if (( s > 0 )); then
    echo $(( (s + 86399) / 86400 ))
  else
    echo $(( (s - 86399) / 86400 ))
  fi
}

# --- Conteo de sesiones ------------------------------------------------
# Dos trampas que hay que esquivar aqui, y de las que depende que el
# limite de multi-login funcione o eche a gente que esta pagando:
#
#  1. OpenSSH crea DOS procesos por sesion:
#         sshd: pepe [priv]     <- monitor privilegiado, corre como root
#         sshd: pepe@notty      <- la sesion de verdad
#     Contar los dos (que es lo que hace el patron "(@|\[| |$)" que
#     circula por ahi) duplica el numero: una cuenta con limite 1 se
#     expulsa sola en cuanto alguien entra. Se cuenta SOLO la forma con
#     '@', que sale exactamente una vez por conexion.
#
#  2. El demonio de dropbear tambien lleva "dropbear" en la linea de
#     comandos y corre como root. Filtrar por usuario != root lo deja
#     fuera; las cuentas de cliente son siempre UID >= 1000.
#
# `ps aux` trunca los usuarios de mas de 8 caracteres, por eso se pide
# explicitamente `user:32`.

count_sessions() {
  local user="$1" a=0 b=0
  # Mismo criterio que sessions_map, incluida la exclusion de root: si las
  # dos funciones contaran distinto, el menu y el timer de limites darian
  # numeros que no cuadran y nadie sabria cual creer.
  [[ "$user" == "root" ]] && { echo 0; return; }
  a=$(ps -eo args= 2>/dev/null \
      | awk -v p="sshd: $user@" 'index($0,p)==1 {c++} END{print c+0}')
  b=$(ps -eo user:32=,args= 2>/dev/null \
      | awk -v u="$user" '$1==u && $2 ~ /dropbear/ {c++} END{print c+0}')
  echo $(( a + b ))
}

# PIDs de las sesiones de un usuario, mas nuevas primero. Devuelve
# exactamente los mismos procesos que cuenta count_sessions: si contara
# unos y matara otros, el timer de limites descontaria mal y dejaria
# sesiones de sobra vivas.
session_pids() {
  local user="$1"
  {
    ps -eo pid=,args= 2>/dev/null \
      | awk -v p="sshd: $user@" 'index($0,p) {print $1}'
    ps -eo pid=,user:32=,args= 2>/dev/null \
      | awk -v u="$user" '$2==u && $3 ~ /dropbear/ {print $1}'
  } | sort -rn | uniq
}

# Sesiones de TODAS las cuentas de una sola pasada: lineas "usuario<TAB>n".
#
# count_sessions lanza dos `ps` por usuario. Usarlo dentro de un bucle
# sobre la lista de cuentas -que es justo lo que hacen el menu, el listado
# y el timer de limites- son 400 procesos con 200 clientes, cada minuto y
# cada vez que se dibuja una pantalla. Aqui se paga un `ps` y ya.
sessions_map() {
  {
    ps -eo args= 2>/dev/null \
      | sed -n 's/^sshd: \([a-z_][a-z0-9_-]*\)@.*/\1/p'
    ps -eo user:32=,args= 2>/dev/null \
      | awk '$1 != "root" && $2 ~ /dropbear/ {print $1}'
  } | sort | uniq -c | awk '{print $2"\t"$1}'
}

# Carga sessions_map en el array asociativo cuyo nombre se pasa.
# Uso:  declare -A SES; load_sessions SES;  echo "${SES[pepe]:-0}"
load_sessions() {
  local -n __map="$1"
  __map=()
  local u n
  while IFS=$'\t' read -r u n; do
    [[ -n "$u" ]] && __map["$u"]="$n"
  done < <(sessions_map)
}

# --- Servicios ---------------------------------------------------------
#
# AVISO PARA QUIEN EDITE ESTOS SCRIPTS
#
# Todos llevan `set -o pipefail`. Eso hace que NO se pueda usar una
# tuberia como condicion de un `if` si el ultimo comando termina antes de
# leerlo todo (`grep -q`, `head -1`, `awk ... exit`):
#
#     if systemctl list-unit-files | grep -q '^dropbear'; then   # MAL
#
# grep encuentra la coincidencia, cierra la tuberia y systemctl muere con
# SIGPIPE; con pipefail el estado de la tuberia pasa a ser 141 y el `if`
# resulta FALSO justo cuando deberia ser verdadero. Y depende del tiempo:
# si el comando de la izquierda es rapido y cabe todo en el buffer, no hay
# SIGPIPE y funciona. O sea que falla a veces, que es lo peor que puede
# hacer.
#
# Por eso existen los helpers de abajo: capturan la salida en una variable
# y comparan con patrones de bash, sin tuberia.

# ¿Existe esta unidad de systemd (aunque este parada)?
#
# NO usar `systemctl list-unit-files`: enumera TODAS las unidades del
# sistema y tarda ~360 ms. Preguntar por una sola con `show -p LoadState`
# tarda ~11 ms. Con la version lenta, dibujar el menu principal (que
# consulta una decena de unidades) costaba casi 4 segundos.
hay_unidad() {
  local estado
  estado=$(systemctl show -p LoadState --value -- "$1" 2>/dev/null)
  [[ -n "$estado" && "$estado" != "not-found" ]]
}

# Estado de VARIAS unidades en UNA sola llamada a systemd.
# Escribe lineas "unidad|existe(si/no)|activa(si/no)".
#
# 10 unidades sueltas son 10 procesos (~110 ms); las 10 de golpe, uno solo
# (~35 ms). Cuando la pantalla se redibuja en cada pulsacion, esa
# diferencia es la que separa un panel agil de uno que "va lento".
estado_unidades() {
  (( $# == 0 )) && return 0
  local salida
  salida=$(systemctl show -p Id -p LoadState -p ActiveState --value -- "$@" 2>/dev/null)
  # systemd devuelve tres lineas por unidad separadas por una linea en
  # blanco; awk en modo parrafo las agrupa. Sin 'exit' para que lea toda
  # la entrada y nadie reciba SIGPIPE (ver el aviso sobre pipefail).
  awk 'BEGIN{RS=""; FS="\n"}
       NF>=3 {
         id=$1; sub(/\.service$/, "", id)
         print id "|" ($2=="not-found" ? "no" : "si") "|" ($3=="active" ? "si" : "no")
       }' <<<"$salida"
}

# ¿Hay algo escuchando en este puerto?  puerto_escucha 443 [tcp|udp]
puerto_escucha() {
  local puerto="$1" proto="${2:-tcp}" lista
  if [[ "$proto" == "udp" ]]; then
    lista=$(ss -ulnH 2>/dev/null)
  else
    lista=$(ss -tlnH 2>/dev/null)
  fi
  # awk sin 'exit': lee toda la entrada, asi nadie recibe SIGPIPE
  awk -v p="$puerto" \
      '{n=split($4,a,":"); if (a[n]==p) hallado=1} END{exit !hallado}' <<<"$lista"
}

# En Docker o sin systemd no queremos abortar la instalacion entera.
svc() {
  local action="$1" name="$2"
  systemctl "$action" "$name" >/dev/null 2>&1 \
    && ok "$name: $action" \
    || warn "$name: no se pudo $action"
}

svc_quiet() { systemctl "$1" "$2" >/dev/null 2>&1; }

is_active() { systemctl is-active "$1" >/dev/null 2>&1; }

# Gestion de los proxies configurables (px_*). Va al final: sus funciones
# usan info/ok/err, que se definen mas arriba.
if [[ -f "$_UI_DIR/proxies.sh" ]]; then
  source "$_UI_DIR/proxies.sh"
else
  source "$NEXO_INSTALL/lib/proxies.sh"
fi

load_ports
load_payload
