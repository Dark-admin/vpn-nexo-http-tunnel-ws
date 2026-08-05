<h1 align="center">VPN NEXO · HTTP TUNNEL WS</h1>

<p align="center">
  <sub><i>netfree · free to the world</i></sub>
</p>

<p align="center">
  <img alt="Bash" src="https://img.shields.io/badge/bash-5.x-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
  <img alt="Python" src="https://img.shields.io/badge/python-3.9%2B-3776AB?style=flat-square&logo=python&logoColor=white">
  <img alt="Debian" src="https://img.shields.io/badge/debian-11%20|%2012%20|%2013-A81D33?style=flat-square&logo=debian&logoColor=white">
  <img alt="Ubuntu" src="https://img.shields.io/badge/ubuntu-22.04%20|%2024.04-E95420?style=flat-square&logo=ubuntu&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square">
</p>

---

Panel de gestión para servidores de túnel, pensado para clientes de tipo **inyector**
(HTTP Custom, HTTP Injector, NapsternetV) y para clientes **V2Ray/Xray**.

Una cuenta sirve para todos los transportes: el mismo usuario y contraseña valen para SSH
directo, payload, WebSocket, TLS y SlowDNS, y el mismo UUID vale para VMess, VLESS y
Trojan. El cliente recibe una sola ficha y tú no llevas tres listas distintas.

```
┏━ ESTADO ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ ● Todo operativo        10 de 10 servicios ┃
┠────────────────────────────────────────────┨
┃ HOST       203.0.113.10                    ┃
┃ RAM        █░░░░░░░░░  19% 368/1936M       ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

┏━ MENU ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ DIA A DIA                                  ┃
┃ ▸ 1   Cuentas              12 · 3 en linea ┃
┃ ▸ 2   Payload / Bug / SNI       cdn.ejem.. ┃
┃ ▸ 3   Puertos y proxies          4 proxies ┃
┠────────────────────────────────────────────┨
┃ SISTEMA                                    ┃
┃ ▸ 4   Servicios                      10/10 ┃
┃ ▸ 5   Configuracion                        ┃
┃ ▸ 6   Apagar / Reiniciar                   ┃
┃ · 0   Salir                                ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
```

## Instalación

```bash
sudo apt update && sudo apt install -y git
```

```bash
git clone https://github.com/Dark-admin/vpn-nexo-http-tunnel-ws.git nexotunnel
cd nexotunnel && chmod +x setup.sh && sudo ./setup.sh
```

El instalador es autosuficiente: **no hay que instalar nada a mano ni antes ni después.**
Todas las preguntas están al principio, así que puedes dejarlo corriendo.

| Fase | Qué hace |
|:--:|---|
| 0 | Preguntas: zona horaria, Xray, dominio, SlowDNS |
| 1 | `apt update` + `apt upgrade` |
| 2 | Todas las dependencias |
| 3 | Componentes externos: BadVPN, Xray, Go + dnstt |
| 4 | Zona horaria, sysctl (BBR), límites de ficheros |
| 5 | El panel, sus servicios, firewall y timers |
| 6 | Dominio y SlowDNS |
| 7 | **Comprobación**: servicios activos, puertos escuchando, binarios |

La fase 7 no da nada por bueno: verifica que cada servicio esté `active`, que cada puerto
esté realmente a la escucha y que cada herramienta exista. Todo queda registrado en
`/var/log/nexotunnel/instalacion.log`.

**Requisitos:** Debian 11/12/13 o Ubuntu 22.04/24.04, KVM (no OpenVZ), root, ~2 GB libres
en `/`.

> Si tu VPS está en AWS, Google Cloud, Oracle o similar, recuerda **abrir los puertos en el
> panel del proveedor**. Es la causa número uno de "instaló bien pero no conecta nada".

## Transportes

| Modo del cliente | Puerto | Cómo funciona |
|---|:--:|---|
| SSH directo | 22 | OpenSSH |
| SSH ligero | 109, 143 | Dropbear |
| **SSH + Payload** | **80, 8080, 8880** | `nexo-hproxy` responde la cabecera que espera el inyector |
| **SSH + WebSocket + SSL** | **443** | nginx termina TLS y enruta por ruta |
| SSH + SSL/TLS crudo | 444 | stunnel |
| VMess / VLESS / Trojan | 443 | Xray tras nginx (`/vmess`, `/vless`, `/trojan`) |
| VLESS gRPC | 443 | serviceName `nexo-grpc` |
| SlowDNS | 53/udp | dnstt |
| UDP en el túnel | interno | BadVPN UDPGW |

### El proxy de payload

Un inyector no habla HTTP correcto. Manda cosas como:

```
GET / HTTP/1.1[crlf]Host: cdn.ejemplo.com[crlf]Upgrade: websocket[crlf][crlf]
```

`nexo-hproxy` (Python, sin dependencias externas) está escrito para aguantarlo:

- responde siempre una primera línea `HTTP/1.1 ...` aunque el método y la ruta sean basura;
- **no reenvía el payload** al backend SSH — dropbear cortaría al ver bytes que no son un banner;
- aguanta payloads partidos con `[split]`: tras contestar espera medio segundo por si llega
  otro trozo, hasta 4 rondas;
- si los primeros bytes ya son `SSH-`, pasa directo: el mismo puerto sirve con y sin payload;
- si el banner SSH viene pegado detrás de las cabeceras, lo rescata en vez de tirarlo;
- desvía `/.well-known/` al nginx local, así **certbot renueva sin parar el túnel**.

`CONNECT` no honra el destino que pide el cliente: siempre va al SSH local. Honrarlo
convertiría el servidor en un proxy abierto.

### SNI y bug host

nginx sirve el certificado con **cualquier SNI** (`server_name _` + `default_server`), que
es justo lo que necesita el modo bug. Y un escaneo del 443 ve una web con TLS válido, no un
túnel.

## Puertos configurables

Nada está quemado en el instalador. Desde `menu → Puertos y proxies` (o `nexo-puertos`):

```
NOMBRE   ESCUCHA          ENTREGA A                 ESTADO
────────────────────────────────────────────────────────────
ws80     0.0.0.0:80       127.0.0.1:109 (Dropbear)  activo
  Payload/WS principal (reenvia los retos de Let's Encrypt)
ws8080   0.0.0.0:8080     127.0.0.1:109 (Dropbear)  activo
wstls    local:10080      127.0.0.1:109 (Dropbear)  activo
  Interno: nginx lo usa para el WSS del 443
```

Traduce los números (109 → *Dropbear*), avisa si el puerto está ocupado y por quién, y
**reaplica el firewall solo** al añadir o quitar un proxy. También se editan desde ahí los
puertos de OpenSSH, Dropbear, nginx, stunnel, SlowDNS y BadVPN.

## Comandos

| Comando | Qué hace |
|---|---|
| `menu` | panel completo |
| `nexo-add` · `nexo-trial` | crear cuenta / cuenta de prueba |
| `nexo-renew` · `nexo-del` | renovar / eliminar |
| `nexo-list` · `nexo-online` | listado / quién está conectado |
| `nexo-show` | reimprimir ficha y QR |
| `nexo-limit` | límite de multi-login |
| `nexo-payload` | bug host, SNI, ruta WS, respuesta HTTP |
| `nexo-puertos` | puertos y proxies |
| `nexo-domain` | dominio + Let's Encrypt |
| `nexo-nginx` · `nexo-xray` · `nexo-slowdns` · `nexo-stunnel` | `status` / `apply` |
| `nexo-fw` | `apply` / `status` / `reset` del firewall |
| `nexo-backup` | backup y migración |

## Qué genera al crear una cuenta

En `/root/nexotunnel-configs/<usuario>/`: la ficha completa lista para enviar, los enlaces
`vmess://` `vless://` `trojan://` y un QR por enlace.

> **Sobre los `.ehi` y `.hc`:** el panel **no** los genera. El formato del `.ehi` de HTTP
> Injector va cifrado con la clave del autor de la app y el `.hc` de HTTP Custom no está
> publicado; inventárselos produce ficheros que la app rechaza. Lo que sí se genera es la
> ficha con todos los campos y el payload ya montado, más los enlaces V2Ray, que son formato
> estándar y se importan de un pegado o por QR.

## Multi-login

Es la parte que más fácil se hace mal, y hacerla mal significa echar a clientes que pagan.

OpenSSH crea **dos** procesos por sesión (`sshd: user [priv]` y `sshd: user@notty`), así que
el patrón habitual `sshd: user(@|\[| |$)` cuenta el doble: una cuenta con límite 1 se expulsa
sola en cuanto alguien entra. Aquí se cuenta **solo la forma con `@`**, que aparece
exactamente una vez por conexión. Del lado de dropbear se excluye a `root`, porque el demonio
también lleva `dropbear` en su línea de comandos.

`count_sessions` y `session_pids` usan el mismo criterio a propósito: si contaras unos
procesos y mataras otros, el timer descontaría mal.

En VMess/VLESS/Trojan no hay proceso por usuario (Xray multiplexa), así que ahí el límite no
se aplica: contar por IP daría falsos positivos en cuanto una casa comparte wifi.

## Interfaz

Diez temas con vista previa en vivo (`Configuración → Tema de colores`), con color verdadero
de 24 bits y respaldo a 256 colores. Incluye un tema **accesible** con azul y naranja en vez
de verde y rojo, la única pareja que distinguen todos los tipos comunes de daltonismo; los
símbolos `●`/`○` y los textos siguen ahí, porque el color nunca debe ser el único portador
de la información.

El panel se dibuja en ~200 ms: el estado de todos los servicios se resuelve con **una sola**
llamada a systemd en vez de dos por unidad.

## Seguridad

- **Sin squid.** Muchos paneles lo dejan con `http_access allow all`, o sea un proxy abierto
  a todo internet: spam, reportes de abuso y VPS suspendido.
- **Firewall solo iptables**, nunca mezclado con ufw: `iptables -F` borra las cadenas de ufw
  y cualquier `ufw reload` tumba las reglas anti-DDoS.
- Xray bloquea `geoip:private`: un cliente no puede alcanzar la red interna del servidor.
- BadVPN escucha en `127.0.0.1`: se alcanza dentro del túnel, no se expone.
- `sshd -t` se valida antes de reiniciar: una config rota te dejaría fuera del servidor.
- Límites del 80/443 altos a propósito (64 y 96 conexiones por IP): detrás del CGNAT de un
  operador salen cientos de clientes con la misma IP pública.

> `users.json` guarda las contraseñas en claro (modo 600). Es deliberado: el panel tiene que
> poder reimprimir la ficha de un cliente que perdió sus datos. Los backups heredan ese 600 —
> trátalos como la lista de clientes que son.

## Backup y migración

`menu → Configuración → Backup`. No copia `/etc/shadow`: copia `/etc/nexotunnel` y al
restaurar **recrea** las cuentas desde `users.json`. Por eso el mismo `.tar.gz` sirve para
recuperar el servidor **y para migrar a otro VPS**, aunque cambie la distribución.

## Estructura

```
.
├── setup.sh              instalador en 7 fases
├── menu.sh               panel
├── lib/
│   ├── ui.sh             cajas, colores, temas
│   ├── common.sh         rutas, puertos, validación, helpers
│   ├── proxies.sh        proxies configurables
│   ├── db.sh             users.json (jq + flock)
│   └── gen.sh            fichas, enlaces v2ray, QR
├── bin/
│   ├── nexo-hproxy.py    proxy payload/WebSocket → SSH
│   ├── nexo-limits.sh    control de multi-login
│   └── nexo-expire.sh    borrado de vencidas
├── core/                 nginx, xray, slowdns, stunnel, payload, puertos, domain, backup
├── users/                add, trial, del, renew, list, online, show, limit
└── config/firewall.sh    iptables + anti-DDoS
```

## Uso responsable

Esto es infraestructura de túnel: sirve igual para saltarse censura, para dar acceso remoto o
para reventa. Lo que hagas con el bug host y con qué operador es cosa tuya y de las
condiciones que hayas aceptado con él — el panel no elige host ni payload por ti, y a
propósito no incluye listas de "hosts gratis" de ninguna operadora.

Lo que sí está deliberadamente cerrado: proxy abierto, `CONNECT` hacia destinos arbitrarios y
acceso a la red privada del servidor. Eso no protege al operador, te protege a ti de que te
cierren el servidor.

## Licencia

MIT — ver [LICENSE](LICENSE).
