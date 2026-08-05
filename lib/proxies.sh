#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Proxies de payload / WebSocket configurables
#
# Antes los cuatro proxies estaban quemados en setup.sh: para cambiar un
# puerto habia que editar el instalador y reinstalar. Ahora viven en
# $NEXO_CONF/proxies.conf y se gestionan desde el panel; cada linea genera
# su propia unidad de systemd (nexo-px-<nombre>.service).
#
# Formato (campos separados por |, sin espacios alrededor):
#
#   nombre|esc_host|esc_puerto|dst_host|dst_puerto|respuesta|acme|descripcion
#
#   nombre      identificador corto [a-z0-9_-]; da nombre a la unidad
#   esc_host    0.0.0.0 = publico, 127.0.0.1 = solo local
#   dst_*       a donde entrega el trafico ya limpio de payload
#   respuesta   "panel" = la que elijas en Payload/Bug/SNI
#               o una linea literal: HTTP/1.1 200 OK
#   acme        puerto del nginx local para los retos de Let's Encrypt
#               (0 = desactivado). Solo tiene sentido en el proxy del 80.
#   descripcion texto libre que se muestra en el panel
#==========================================

PROXIES_CONF="${NEXO_CONF:-/etc/nexotunnel}/proxies.conf"
PX_PREFIJO="nexo-px"

# --- Fichero por defecto ----------------------------------------------
px_defaults() {
  cat <<'EOF'
# NexoTunnel - proxies de payload / WebSocket
# Editalo desde el panel:  menu -> Puertos y proxies   (o: sudo nexo-puertos)
#
#   nombre|esc_host|esc_puerto|dst_host|dst_puerto|respuesta|acme|descripcion
#
# respuesta: "panel" usa la del panel; o una linea literal (HTTP/1.1 200 OK)
# acme     : puerto del nginx local para Let's Encrypt (0 = no)
#
ws80|0.0.0.0|80|127.0.0.1|109|panel|8081|Payload/WS principal -> Dropbear
ws8080|0.0.0.0|8080|127.0.0.1|109|panel|0|Payload/WS alterno -> Dropbear
ws8880|0.0.0.0|8880|127.0.0.1|109|panel|0|Payload/WS alterno -> Dropbear
wstls|127.0.0.1|10080|127.0.0.1|109|HTTP/1.1 101 Switching Protocols|0|Interno: nginx lo usa para el WSS del 443
EOF
}

px_init() {
  mkdir -p "$(dirname "$PROXIES_CONF")"
  [[ -s "$PROXIES_CONF" ]] || px_defaults > "$PROXIES_CONF"
  chmod 644 "$PROXIES_CONF"
}

# --- Lectura -----------------------------------------------------------
# Lineas utiles, sin comentarios ni vacias
px_list() {
  px_init
  grep -vE '^\s*(#|$)' "$PROXIES_CONF" 2>/dev/null
}

px_nombres() { px_list | cut -d'|' -f1; }

# px_campo <nombre> <n>   (1=nombre .. 8=descripcion)
px_campo() {
  local n="$1" i="$2"
  px_list | awk -F'|' -v n="$n" -v i="$i" '$1==n {print $i; salir=1} END{}' | head -1
}

px_existe() {
  local n="$1" x
  for x in $(px_nombres); do [[ "$x" == "$n" ]] && return 0; done
  return 1
}

# Puertos publicos que el firewall debe abrir (los de 127.0.0.1 no)
px_puertos_publicos() {
  px_list | awk -F'|' '$2 != "127.0.0.1" && $2 != "localhost" {print $3}' | sort -un
}

px_unidades() {
  local n
  for n in $(px_nombres); do echo "$PX_PREFIJO-$n"; done
}

# Unidad del proxy que reenvia los retos de Let's Encrypt (campo acme != 0).
# Antes esto era el nombre fijo "nexo-hproxy"; ahora el revendedor puede
# renombrar o mover ese proxy, asi que hay que buscarlo por su funcion y no
# por como se llame.
px_unidad_acme() {
  local n
  n=$(px_list | awk -F'|' '$7 != "0" && $7 != "" {print $1; exit}')
  [[ -n "$n" ]] && echo "$PX_PREFIJO-$n"
}

# --- Escritura ---------------------------------------------------------
px_guardar_linea() {
  local nombre="$1" linea="$2" tmp
  px_init
  tmp=$(mktemp)
  awk -F'|' -v n="$nombre" '$1 != n' "$PROXIES_CONF" > "$tmp"
  [[ -n "$linea" ]] && echo "$linea" >> "$tmp"
  cat "$tmp" > "$PROXIES_CONF"
  rm -f "$tmp"
  chmod 644 "$PROXIES_CONF"
}

# px_add nombre esc_host esc_puerto dst_host dst_puerto respuesta acme desc
px_add() {
  px_guardar_linea "$1" "$1|$2|$3|$4|$5|$6|$7|$8"
}

px_del() { px_guardar_linea "$1" ""; }

# px_set <nombre> <n_campo> <valor>
px_set() {
  local n="$1" i="$2" v="$3" linea nueva
  linea=$(px_list | awk -F'|' -v n="$n" '$1==n' | head -1)
  [[ -z "$linea" ]] && return 1
  nueva=$(awk -F'|' -v OFS='|' -v i="$i" -v v="$v" '{$i=v; print}' <<<"$linea")
  px_guardar_linea "$n" "$nueva"
}

# --- Conflictos --------------------------------------------------------
# ¿Quien tiene cogido ya ese puerto? Devuelve el nombre del proceso, o
# vacio si esta libre. Es lo que evita el clasico "instale todo y solo
# arranca uno de los dos servicios".
px_quien_usa() {
  local puerto="$1" excluir="${2:-}" lista
  lista=$(ss -tlnpH 2>/dev/null)
  awk -v p="$puerto" -v ex="$excluir" '
    {
      n = split($4, a, ":")
      if (a[n] != p) next
      proc = $0
      sub(/.*users:\(\("/, "", proc)
      sub(/".*/, "", proc)
      if (proc != "" && proc != ex) { print proc; salida=1 }
    }' <<<"$lista" | head -1
}

# Otro proxy del propio fichero escuchando en el mismo puerto
px_choque_interno() {
  local puerto="$1" propio="$2"
  px_list | awk -F'|' -v p="$puerto" -v yo="$propio" \
    '$3==p && $1!=yo {print $1}' | head -1
}

# --- Generacion de unidades -------------------------------------------
px_escribir_unidad() {
  local nombre="$1" eh="$2" ep="$3" dh="$4" dp="$5" resp="$6" acme="$7" desc="$8"
  local unidad="$PX_PREFIJO-$nombre"
  local envfile="EnvironmentFile=-${NEXO_CONF:-/etc/nexotunnel}/hproxy.env"
  local fija=""

  if [[ "$resp" != "panel" ]]; then
    # Comillas OBLIGATORIAS: systemd parte Environment= por los espacios y
    # sin ellas HP_RESPONSE se queda en "HTTP/1.1".
    envfile=""
    fija="Environment=\"HP_RESPONSE=$resp\""
  fi

  cat > "/etc/systemd/system/$unidad.service" <<EOF
[Unit]
Description=NexoTunnel proxy [$nombre] $eh:$ep -> $dh:$dp ($desc)
After=network.target

[Service]
Type=simple
$envfile
Environment=HP_BIND_HOST=$eh
Environment=HP_BIND_PORT=$ep
Environment=HP_TARGET_HOST=$dh
Environment=HP_TARGET_PORT=$dp
Environment=HP_ACME_HOST=127.0.0.1
Environment=HP_ACME_PORT=$acme
Environment=HP_SERVER_NAME=nginx
$fija
ExecStart=/usr/bin/python3 /usr/bin/nexo-hproxy
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=append:${NEXO_LOG:-/var/log/nexotunnel}/hproxy.log
StandardError=append:${NEXO_LOG:-/var/log/nexotunnel}/hproxy.log

[Install]
WantedBy=multi-user.target
EOF
}

# Regenera todas las unidades, retira las que ya no estan en el fichero y
# arranca lo que toque. Idempotente: se puede llamar las veces que sea.
px_apply() {
  px_init
  local vivos=() nombre eh ep dh dp resp acme desc unidad fallos=0

  while IFS='|' read -r nombre eh ep dh dp resp acme desc; do
    [[ -z "$nombre" ]] && continue
    px_escribir_unidad "$nombre" "$eh" "$ep" "$dh" "$dp" "$resp" "$acme" "$desc"
    vivos+=("$PX_PREFIJO-$nombre")
  done < <(px_list)

  # Unidades huerfanas: proxies que se borraron del fichero pero cuya
  # unidad seguiria escuchando y ocupando el puerto.
  local f base
  for f in /etc/systemd/system/$PX_PREFIJO-*.service; do
    [[ -e "$f" ]] || continue
    base=$(basename "$f" .service)
    local sigue=0 v
    for v in "${vivos[@]}"; do [[ "$v" == "$base" ]] && sigue=1; done
    if (( ! sigue )); then
      systemctl disable --now "$base" >/dev/null 2>&1
      rm -f "$f"
      # Sin reset-failed la unidad se queda como "not-found failed" en
      # `systemctl --failed` aunque el fichero ya no exista.
      systemctl reset-failed "$base" >/dev/null 2>&1
      info "Proxy retirado: ${base#$PX_PREFIJO-}"
    fi
  done

  # Las unidades viejas de la version 1.0 (nombres fijos) estorban: si
  # siguen activas ocupan el puerto y el proxy nuevo no puede arrancar.
  for base in nexo-hproxy nexo-hproxy-alt1 nexo-hproxy-alt2 nexo-hproxy-ws; do
    if [[ -e "/etc/systemd/system/$base.service" ]]; then
      systemctl disable --now "$base" >/dev/null 2>&1
      rm -f "/etc/systemd/system/$base.service"
      systemctl reset-failed "$base" >/dev/null 2>&1
    fi
  done

  systemctl daemon-reload 2>/dev/null

  for unidad in "${vivos[@]}"; do
    systemctl enable "$unidad" >/dev/null 2>&1
    if systemctl restart "$unidad" >/dev/null 2>&1; then
      ok "${unidad#$PX_PREFIJO-}: activo"
    else
      err "${unidad#$PX_PREFIJO-}: NO arranco (journalctl -u $unidad -n 20)"
      fallos=$(( fallos + 1 ))
    fi
  done

  return $fallos
}

px_restart() {
  local u
  for u in $(px_unidades); do systemctl restart "$u" >/dev/null 2>&1; done
}
