#!/usr/bin/env python3
"""
NexoTunnel v1.0 - Proxy HTTP / WebSocket tolerante a payload -> SSH

Este es el componente que hace que HTTP Injector, HTTP Custom, NapsternetV
y similares puedan conectar. Un inyector NO habla HTTP correcto: manda
cosas como

    GET / HTTP/1.1[crlf]Host: cdn.zerorated.example[crlf][crlf]

o partidas en dos con [split], o un CONNECT, o directamente basura con el
host metido a mano. El servidor tiene que:

  1. Responder SIEMPRE algo que empiece por "HTTP/1.1 ..." aunque la
     peticion sea invalida (el inyector solo mira esa primera linea).
  2. NO reenviar el payload al backend SSH: dropbear cortaria la conexion
     al ver bytes que no son un banner SSH.
  3. Aguantar respuestas partidas: algunos payloads esperan DOS respuestas
     (200 y luego 101). Por eso, tras contestar, se espera un instante
     (SPLIT_WAIT) por si llega otro trozo de payload.
  4. No quedarse esperando al cliente eternamente: en SSH el servidor
     manda su banner primero, asi que en cuanto no llega mas payload hay
     que conectar arriba y empezar a reenviar.

Ademas:
  - Si los primeros bytes ya son "SSH-", pasa directo (el mismo puerto
    sirve con y sin payload).
  - Si la peticion es /.well-known/acme-challenge/... la reenvia al nginx
    local. Asi el puerto 80 puede ser del tunel Y renovar el certificado
    de Let's Encrypt sin pelearse por el puerto.
  - CONNECT NO honra el destino que pide el cliente: siempre va al backend
    SSH. Honrarlo convertiria el VPS en un proxy abierto -> spam, reportes
    de abuso y suspension. Es el mismo fallo que tenia el squid de la v1.0
    de NexoServer con "http_access allow all".

Solo stdlib. Configuracion por variables de entorno (las pone systemd):

  HP_BIND_HOST    0.0.0.0
  HP_BIND_PORT    80
  HP_TARGET_HOST  127.0.0.1
  HP_TARGET_PORT  109              (dropbear)
  HP_RESPONSE     "HTTP/1.1 101 Switching Protocols"
                  varias separadas por '|' -> se envian en orden
  HP_SERVER_NAME  NexoTunnel
  HP_ACME_HOST    127.0.0.1
  HP_ACME_PORT    8081             (0 = desactivado)
  HP_MAX_CLIENTS  800
  HP_IDLE_TIMEOUT 300
"""

import logging
import os
import select
import signal
import socket
import sys
import threading

BIND_HOST   = os.environ.get("HP_BIND_HOST", "0.0.0.0")
BIND_PORT   = int(os.environ.get("HP_BIND_PORT", "80"))
TARGET_HOST = os.environ.get("HP_TARGET_HOST", "127.0.0.1")
TARGET_PORT = int(os.environ.get("HP_TARGET_PORT", "109"))
SERVER_NAME = os.environ.get("HP_SERVER_NAME", "NexoTunnel")
ACME_HOST   = os.environ.get("HP_ACME_HOST", "127.0.0.1")
ACME_PORT   = int(os.environ.get("HP_ACME_PORT", "8081"))

RESPONSES = [
    r.strip() for r in
    os.environ.get("HP_RESPONSE", "HTTP/1.1 101 Switching Protocols").split("|")
    if r.strip()
] or ["HTTP/1.1 101 Switching Protocols"]

MAX_CLIENTS   = int(os.environ.get("HP_MAX_CLIENTS", "800"))
IDLE_TIMEOUT  = int(os.environ.get("HP_IDLE_TIMEOUT", "300"))

BUFFER        = 32768
HANDSHAKE_TO  = 20      # segundos de margen para que el cliente hable
SPLIT_WAIT    = 0.5     # espera por un segundo trozo de payload
MAX_EXCHANGES = 4       # rondas de payload antes de pasar a relay
MAX_HEAD      = 32768   # cabeceras mas largas que esto = cliente basura

logging.basicConfig(
    level=os.environ.get("HP_LOGLEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("hproxy")

_slots = threading.BoundedSemaphore(MAX_CLIENTS)
_running = True

HTTP_METHODS = (
    b"GET", b"POST", b"HEAD", b"PUT", b"OPTIONS", b"PATCH",
    b"DELETE", b"TRACE", b"CONNECT", b"SOURCE",
)


# ---------------------------------------------------------------------
def looks_http(data: bytes) -> bool:
    """True si el buffer empieza por algo parecido a una peticion HTTP."""
    up = data[:8].upper()
    return any(up.startswith(m) for m in HTTP_METHODS)


def header_end(data: bytes):
    """Devuelve el separador de fin de cabeceras presente, o None."""
    for sep in (b"\r\n\r\n", b"\n\n"):
        if sep in data:
            return sep
    return None


def ssh_offset(data: bytes) -> int:
    """Posicion del banner SSH dentro del buffer, o -1.

    Hay payloads que pegan el banner justo detras de las cabeceras. Si se
    tira ese trozo, la negociacion SSH se pierde y el cliente se queda
    colgado en 'conectando'.
    """
    return data.find(b"SSH-")


def build_response(status: str, tunnel: bool = False) -> bytes:
    """Una respuesta minima pero valida para el inyector.

    `tunnel=True` para las respuestas tras las que el socket deja de ser
    HTTP (101 y el 200 del CONNECT): ahi NO puede ir Content-Length, o un
    cliente estricto se queda esperando un cuerpo que nunca llega.
    """
    up = status.upper()
    if tunnel or up.startswith("HTTP/1.1 101") or "SWITCHING" in up:
        extra = "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    elif "CONNECTION ESTABLISHED" in up:
        extra = ""
    else:
        extra = "Connection: keep-alive\r\nContent-Length: 0\r\n"
    return (
        f"{status}\r\n"
        f"Server: {SERVER_NAME}\r\n"
        f"{extra}"
        f"\r\n"
    ).encode("utf-8", "replace")


def send_all(sock, data: bytes) -> bool:
    try:
        sock.sendall(data)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------------
def relay(a, b):
    """Reenvia en ambos sentidos hasta que uno cierre o expire el idle."""
    a.setblocking(False)
    b.setblocking(False)
    socks = [a, b]
    while _running:
        try:
            readable, _, errored = select.select(socks, [], socks, IDLE_TIMEOUT)
        except (OSError, ValueError):
            return
        if errored or not readable:
            return
        for s in readable:
            try:
                data = s.recv(BUFFER)
            except BlockingIOError:
                continue
            except OSError:
                return
            if not data:
                return
            if not send_all(b if s is a else a, data):
                return


def pipe_to_acme(conn, first: bytes):
    """Reto de Let's Encrypt: se lo pasamos entero al nginx local."""
    if not ACME_PORT:
        send_all(conn, build_response("HTTP/1.1 404 Not Found"))
        return
    try:
        up = socket.create_connection((ACME_HOST, ACME_PORT), timeout=5)
    except OSError as e:
        log.warning("ACME: no se pudo abrir %s:%s (%s)", ACME_HOST, ACME_PORT, e)
        send_all(conn, build_response("HTTP/1.1 502 Bad Gateway"))
        return
    try:
        if send_all(up, first):
            conn.settimeout(None)
            up.settimeout(None)
            relay(conn, up)
    finally:
        close_quiet(up)


def close_quiet(sock):
    if sock is None:
        return
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


# ---------------------------------------------------------------------
def negotiate(conn, addr):
    """Consume el payload del inyector y devuelve los bytes que SI van a SSH.

    Devuelve None si la conexion debe cerrarse (o ya se atendio como ACME).
    """
    buf = b""
    exchanges = 0
    conn.settimeout(HANDSHAKE_TO)

    while True:
        # --- Traer datos si no hay nada que decidir ----------------------
        if not buf:
            try:
                chunk = conn.recv(BUFFER)
            except (socket.timeout, OSError):
                return None
            if not chunk:
                return None
            buf += chunk

        # --- Caso 1: ya es SSH puro, no hay payload ----------------------
        if buf.startswith(b"SSH-"):
            return buf

        # --- Caso 2: no parece HTTP: se pasa tal cual --------------------
        if not looks_http(buf):
            if len(buf) < 8:
                try:
                    more = conn.recv(BUFFER)
                except (socket.timeout, OSError):
                    return buf
                if not more:
                    return buf
                buf += more
                continue
            return buf

        # --- Caso 3: HTTP: hay que leer hasta el fin de cabeceras --------
        sep = header_end(buf)
        while sep is None:
            if len(buf) > MAX_HEAD:
                log.warning("Cabeceras excesivas desde %s, cerrando", addr[0])
                return None
            try:
                chunk = conn.recv(BUFFER)
            except (socket.timeout, OSError):
                return None
            if not chunk:
                return None
            buf += chunk
            sep = header_end(buf)

        head, _, rest = buf.partition(sep)
        first_line = head.split(b"\n", 1)[0].strip()
        method = first_line.split(b" ", 1)[0].upper()
        path = b""
        parts = first_line.split(b" ")
        if len(parts) > 1:
            path = parts[1]

        # Reto ACME -> nginx local (para que certbot funcione en el 80)
        if path.startswith(b"/.well-known/"):
            log.info("ACME desde %s: %s", addr[0], path.decode("ascii", "replace"))
            pipe_to_acme(conn, buf)
            return None

        # Respuesta al inyector
        if method == b"CONNECT":
            # El destino pedido se IGNORA a proposito (ver cabecera del fichero)
            ok = send_all(conn, build_response("HTTP/1.1 200 Connection established"))
        else:
            ok = True
            for status in RESPONSES:
                if not send_all(conn, build_response(status)):
                    ok = False
                    break
        if not ok:
            return None

        exchanges += 1
        buf = rest

        # ¿El banner SSH venia pegado detras de las cabeceras?
        off = ssh_offset(buf)
        if off >= 0:
            return buf[off:]

        if exchanges >= MAX_EXCHANGES:
            return b""

        # --- Espera corta por un segundo trozo de payload ---------------
        # Si no llega nada, hay que conectar ya: en SSH el banner del
        # SERVIDOR va primero y el cliente puede estar esperandolo.
        if not buf:
            try:
                ready, _, _ = select.select([conn], [], [], SPLIT_WAIT)
            except (OSError, ValueError):
                return None
            if not ready:
                return b""
            try:
                chunk = conn.recv(BUFFER)
            except (socket.timeout, OSError):
                return b""
            if not chunk:
                return None
            buf = chunk

        if buf.startswith(b"SSH-"):
            return buf
        if not looks_http(buf):
            return buf
        # Si vuelve a parecer HTTP, otra ronda de payload


# ---------------------------------------------------------------------
def handle(conn, addr):
    upstream = None
    try:
        leftover = negotiate(conn, addr)
        if leftover is None:
            return

        try:
            upstream = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10)
        except OSError as e:
            log.error("Backend %s:%s inaccesible (%s)", TARGET_HOST, TARGET_PORT, e)
            return
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        if leftover and not send_all(upstream, leftover):
            return

        conn.settimeout(None)
        upstream.settimeout(None)
        relay(conn, upstream)

    except (socket.timeout, ConnectionError, OSError) as e:
        log.debug("Sesion %s terminada: %s", addr[0], e)
    except Exception:
        log.exception("Error inesperado con %s", addr[0])
    finally:
        close_quiet(conn)
        close_quiet(upstream)
        _slots.release()


def shutdown(signum, _frame):
    global _running
    _running = False
    log.info("Señal %s recibida, cerrando...", signum)
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((BIND_HOST, BIND_PORT))
    server.listen(256)
    log.info("Escuchando en %s:%d -> %s:%d | respuesta: %s",
             BIND_HOST, BIND_PORT, TARGET_HOST, TARGET_PORT, " | ".join(RESPONSES))

    while _running:
        try:
            conn, addr = server.accept()
        except OSError:
            continue
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        if not _slots.acquire(blocking=False):
            log.warning("Limite de %d clientes alcanzado, rechazando %s",
                        MAX_CLIENTS, addr[0])
            close_quiet(conn)
            continue

        try:
            threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
        except RuntimeError:
            # Sin hilos disponibles: hay que devolver el hueco a mano, o el
            # contador de plazas baja para siempre y el proxy acaba
            # rechazando a todo el mundo con el servidor vacio.
            log.error("No se pudo crear el hilo para %s", addr[0])
            close_quiet(conn)
            _slots.release()


if __name__ == "__main__":
    main()
