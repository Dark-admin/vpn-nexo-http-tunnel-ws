#!/bin/bash
#==========================================
# NexoTunnel v1.0 - Base de datos de cuentas
#
# Una sola cuenta sirve para TODOS los transportes: la misma persona usa
# usuario/clave para SSH (directo, payload, WS, TLS, SlowDNS) y el mismo
# UUID para VMess/VLESS/Trojan. Por eso hay un unico registro por cuenta.
#
# Formato ($NEXO_CONF/users.json):
#   { "users": [ { "user","pass","uuid","exp","limit","note","created" } ] }
#
# Todas las escrituras van bajo flock y a un fichero temporal: si jq falla
# a mitad, la base de datos original no se toca.
#==========================================

DB_LOCK="${NEXO_STATE:-/var/lib/nexotunnel}/db.lock"

db_init() {
  mkdir -p "$(dirname "$USERS_DB")" "${NEXO_STATE:-/var/lib/nexotunnel}"
  if [[ ! -s "$USERS_DB" ]]; then
    echo '{"users":[]}' > "$USERS_DB"
  fi
  # Si el fichero quedo corrupto, se aparta en vez de perderlo
  if ! jq -e . "$USERS_DB" >/dev/null 2>&1; then
    mv "$USERS_DB" "$USERS_DB.roto.$(date +%s)"
    echo '{"users":[]}' > "$USERS_DB"
  fi
  chmod 600 "$USERS_DB"
}

# db_write '<filtro jq>' [args...]
db_write() {
  local filter="$1"; shift
  db_init
  local tmp; tmp=$(mktemp)
  (
    flock -x 200
    if jq "$@" "$filter" "$USERS_DB" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      cat "$tmp" > "$USERS_DB"
    else
      rm -f "$tmp"
      exit 1
    fi
    rm -f "$tmp"
  ) 200>"$DB_LOCK"
}

db_read() {
  db_init
  jq "$@" "$USERS_DB" 2>/dev/null
}

db_exists() {
  db_init
  [[ "$(jq --arg u "$1" '[.users[]|select(.user==$u)]|length' "$USERS_DB" 2>/dev/null)" != "0" ]]
}

# db_add usuario clave uuid fecha_exp limite [nota]
db_add() {
  db_write '.users |= (map(select(.user != $u)) + [{
      user: $u, pass: $p, uuid: $id, exp: $e,
      limit: ($l|tonumber), note: $n, created: $c
    }])' \
    --arg u "$1" --arg p "$2" --arg id "$3" --arg e "$4" \
    --arg l "$5" --arg n "${6:-}" --arg c "$(date +%Y-%m-%d)"
}

db_del() {
  db_write '.users |= map(select(.user != $u))' --arg u "$1"
}

# db_set usuario campo valor  (valor siempre como texto; 'limit' se castea)
db_set() {
  if [[ "$2" == "limit" ]]; then
    db_write '.users |= map(if .user==$u then .limit = ($v|tonumber) else . end)' \
      --arg u "$1" --arg v "$3"
  else
    db_write '.users |= map(if .user==$u then .[$k] = $v else . end)' \
      --arg u "$1" --arg k "$2" --arg v "$3"
  fi
}

# db_get usuario campo
db_get() {
  db_read -r --arg u "$1" --arg k "$2" \
    '.users[]|select(.user==$u)|.[$k] // empty'
}

db_users() {
  db_read -r '.users[].user' | sort
}

db_count() {
  db_read -r '.users|length'
}

# Cuentas cuya fecha de expiracion ya paso (formato YYYY-MM-DD)
db_expired() {
  local hoy; hoy=$(date +%Y-%m-%d)
  db_read -r --arg h "$hoy" '.users[]|select(.exp < $h)|.user'
}

# Volcado tabular: usuario|exp|limite|uuid
db_table() {
  db_read -r '.users[]|[.user,.exp,(.limit|tostring),.uuid]|join("|")' | sort
}

# --- Seleccion interactiva --------------------------------------------
# Escribe el usuario elegido en la variable cuyo nombre se pasa. Devuelve
# 1 si no hay cuentas o si el usuario cancela.
# Uso: pick_user DESTINO "Titulo del listado"
pick_user() {
  local __var="$1" titulo="${2:-CUENTAS}"
  local -a lista=()
  mapfile -t lista < <(db_users)

  if (( ${#lista[@]} == 0 )); then
    ui_vacio "No hay ninguna cuenta todavia." \
             "Crea la primera desde:  Cuentas › Crear cuenta"
    return 1
  fi

  local -A ses
  load_sessions ses

  # Cada cuenta con su estado a la derecha: cuantos dias le quedan y si
  # hay alguien dentro. Elegir "el que caduca manana" deja de ser adivinar.
  ui_top "$titulo"
  local i=1 u n d pista col
  for u in "${lista[@]}"; do
    n=${ses[$u]:-0}
    d=$(days_left "$(db_get "$u" exp)")
    col="$C_KEY"
    if [[ "$d" =~ ^-?[0-9]+$ ]] && (( d < 0 )); then
      pista="vencida"; col="$C_ERR"
    elif [[ "$d" =~ ^-?[0-9]+$ ]] && (( d <= 3 )); then
      pista="${d}d"; col="$C_WARN"
    else
      pista="${d}d"
    fi
    (( n > 0 )) && pista="$pista · $n en linea"
    ui_opt "$i" "$u" "$pista" "$col"
    ((i++))
  done
  ui_item_quiet "0" "Cancelar"
  ui_bottom
  ui_keys " numero, o el nombre tal cual · 0 cancelar"

  ui_prompt; local sel; read -r sel; sel="${sel//[[:space:]]/}"
  [[ "$sel" == "0" || -z "$sel" ]] && return 1

  # Se acepta tanto el numero como el nombre escrito a mano
  if valid_number "$sel" && (( sel >= 1 && sel <= ${#lista[@]} )); then
    printf -v "$__var" '%s' "${lista[$((sel-1))]}"
    return 0
  fi
  for u in "${lista[@]}"; do
    if [[ "$u" == "$sel" ]]; then
      printf -v "$__var" '%s' "$u"
      return 0
    fi
  done

  err "Seleccion invalida"
  return 1
}
