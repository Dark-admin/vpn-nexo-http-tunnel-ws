#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Generador de configuraciones de cliente
#
# Sobre los ficheros .ehi (HTTP Injector) y .hc (HTTP Custom): su formato
# no esta publicado y el .ehi ademas va cifrado con la clave del autor de
# la app. Generarlos "a ojo" produce ficheros que la app rechaza al
# importar, asi que este panel NO se los inventa. Lo que genera es:
#
#   - una FICHA con todos los campos listos para pegar en la app
#   - el PAYLOAD ya montado con el bug host configurado
#   - los enlaces estandar vmess:// vless:// trojan:// (esos SI estan
#     documentados y se importan de un pegado o por QR)
#   - un QR por enlace
#
# Todo se guarda ademas en $NEXO_OUT/<usuario>/ para reenviarlo luego.
#==========================================

# Codifica una ruta para meterla en una query string: / -> %2F
urlenc_path() { printf '%s' "$1" | sed 's|/|%2F|g'; }

b64() { base64 -w0; }

# --- Enlaces -----------------------------------------------------------
# vmess:// es base64 de un JSON; el resto son URIs con query string.
vmess_link() {
  local host="$1" port="$2" uuid="$3" sni="$4" nombre="$5"
  jq -nc \
    --arg ps "$nombre" --arg add "$host" --arg port "$port" \
    --arg id "$uuid"   --arg host "$sni" --arg sni "$sni" \
    '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto",
      net:"ws", type:"none", host:$host, path:"/vmess", tls:"tls", sni:$sni}' \
    | { printf 'vmess://'; b64; echo ""; }
}

vless_link() {
  local host="$1" port="$2" uuid="$3" sni="$4" nombre="$5"
  echo "vless://${uuid}@${host}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlenc_path /vless)#${nombre}"
}

trojan_link() {
  local host="$1" port="$2" uuid="$3" sni="$4" nombre="$5"
  echo "trojan://${uuid}@${host}:${port}?security=tls&sni=${sni}&type=ws&host=${sni}&path=$(urlenc_path /trojan)#${nombre}"
}

grpc_link() {
  local host="$1" port="$2" uuid="$3" sni="$4" nombre="$5"
  echo "vless://${uuid}@${host}:${port}?encryption=none&security=tls&sni=${sni}&type=grpc&serviceName=nexo-grpc&mode=gun#${nombre}-grpc"
}

# --- Payload -----------------------------------------------------------
gen_payload() {
  local bug="$1"
  [[ -z "$bug" ]] && bug="bug.tudominio.com"
  printf 'GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]' "$bug"
}

# --- Ficha de texto ----------------------------------------------------
# gen_card <usuario>  -> escribe la ficha completa por stdout (sin colores,
# para que se pueda copiar y pegar en WhatsApp tal cual).
gen_card() {
  local u="$1"
  local pass uuid exp limite
  pass=$(db_get "$u" pass)
  uuid=$(db_get "$u" uuid)
  exp=$(db_get "$u" exp)
  limite=$(db_get "$u" limit)

  load_ports
  load_payload
  local host ip sni
  host=$(conn_host)
  ip=$(get_ip)
  sni="${SNI_HOST:-$host}"

  local slowns="" slowpub=""
  [[ -f "$NEXO_CONF/slowdns/ns"  ]] && slowns=$(cat "$NEXO_CONF/slowdns/ns")
  [[ -f "$NEXO_CONF/slowdns/server.pub" ]] && slowpub=$(cat "$NEXO_CONF/slowdns/server.pub")

  cat <<EOF
=========================================
        NEXOTUNNEL - CUENTA
=========================================
Usuario   : $u
Password  : $pass
UUID      : $uuid
Expira    : $exp  ($(days_left "$exp") dias)
Limite    : $limite conexiones simultaneas

-----------------------------------------
SERVIDOR
-----------------------------------------
Host      : $host
IP        : $ip
SNI / Bug : ${SNI_HOST:-$host}
Bug host  : ${BUG_HOST:-(sin definir)}

-----------------------------------------
SSH (usuario y clave de arriba)
-----------------------------------------
Directo         : $ip:$SSH_PORT
Dropbear        : $ip:$DROPBEAR_PORT1 , $ip:$DROPBEAR_PORT2
Payload / WS    : $host:$HTTP_PORT   (tambien $HTTP_ALT1 y $HTTP_ALT2)
WebSocket TLS   : wss://$host:$TLS_PORT$WS_PATH
SSL / TLS crudo : $host:$STUNNEL_PORT
UDPGW (BadVPN)  : 127.0.0.1:$(echo "$BADVPN_PORTS" | awk '{print $1}')   [dentro del tunel]

PAYLOAD
$(gen_payload "${BUG_HOST:-}")

-----------------------------------------
SLOWDNS
-----------------------------------------
EOF
  if [[ -n "$slowns" && -n "$slowpub" ]]; then
    cat <<EOF
Nameserver: $slowns
Public key: $slowpub
Resolver  : 8.8.8.8 (o el del operador)
EOF
  else
    echo "(no configurado)"
  fi

  cat <<EOF

-----------------------------------------
V2RAY / XRAY  (mismo UUID)
-----------------------------------------
$(vmess_link  "$host" "$TLS_PORT" "$uuid" "$sni" "$u")

$(vless_link  "$host" "$TLS_PORT" "$uuid" "$sni" "$u")

$(trojan_link "$host" "$TLS_PORT" "$uuid" "$sni" "$u")

$(grpc_link   "$host" "$TLS_PORT" "$uuid" "$sni" "$u")

=========================================
EOF
}

# --- Ficheros ----------------------------------------------------------
# gen_files <usuario> -> deja ficha, enlaces y QR en $NEXO_OUT/<usuario>/
gen_files() {
  local u="$1"
  local dir="$NEXO_OUT/$u"
  mkdir -p "$dir"
  chmod 700 "$NEXO_OUT" "$dir"

  gen_card "$u" > "$dir/$u.txt"
  chmod 600 "$dir/$u.txt"

  local uuid exp host sni
  uuid=$(db_get "$u" uuid)
  host=$(conn_host)
  load_payload; load_ports
  sni="${SNI_HOST:-$host}"

  vmess_link  "$host" "$TLS_PORT" "$uuid" "$sni" "$u" >  "$dir/enlaces.txt"
  vless_link  "$host" "$TLS_PORT" "$uuid" "$sni" "$u" >> "$dir/enlaces.txt"
  trojan_link "$host" "$TLS_PORT" "$uuid" "$sni" "$u" >> "$dir/enlaces.txt"
  grpc_link   "$host" "$TLS_PORT" "$uuid" "$sni" "$u" >> "$dir/enlaces.txt"
  chmod 600 "$dir/enlaces.txt"

  if command -v qrencode >/dev/null 2>&1; then
    local i=1
    while read -r link; do
      [[ -z "$link" ]] && continue
      qrencode -o "$dir/qr-$i.png" -s 6 -m 2 "$link" 2>/dev/null
      i=$(( i + 1 ))
    done < "$dir/enlaces.txt"
  fi

  echo "$dir"
}

# Dibuja un QR en el propio terminal (util desde Termux)
gen_qr_term() {
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 -m 1 "$1"
  else
    warn "Instala qrencode para ver el QR aqui: apt install qrencode"
  fi
}
