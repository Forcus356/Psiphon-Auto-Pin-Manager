<div align="center">

<img src="docs/assets/banner.svg" alt="Forcus Auto-Pin — Psiphon Manager" width="100%">

# Forcus Auto-Pin

**SOCKS5 local · PIN automático · Google/Gemini · recuperación**

![Version](https://img.shields.io/badge/version-4.3.0-32b98b?style=flat-square)
![Platform](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-x86__64-2496ed?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

[English](README.md) · [فارسی](README.fa_IR.md) · [العربية](README.ar_EG.md) · [中文](README.zh_CN.md) · **Español** · [Русский](README.ru_RU.md) · [Türkçe](README.tr_TR.md)

</div>

Gestor de Psiphon para VPS Linux. Instala, elige Easy o Advanced y administra instancias independientes desde la consola. Xray utiliza el mismo SOCKS5 mediante un outbound JSON.

[Inicio rápido](#quick-start) · [Funciones](#features) · [Menú de consola](#menu) · [Referencia de comandos](#commands) · [Integración con Xray](#xray) · [Actualización y mantenimiento](#operations) · [Desinstalación](#uninstall) · [Preguntas frecuentes](#faq)

[YouTube Mode](#youtube) · [Seguridad](#security)

<a id="quick-start"></a>

## Inicio rápido

Ejecuta los comandos como root en Bash. Compatible con Ubuntu/Debian x86_64 y systemd; requiere Internet y curl. El instalador añade Docker/Go si faltan y conserva las instalaciones existentes.

El exportador necesita Go 1.22; Go 1.21+ puede seleccionar un toolchain nuevo verificado. Un Go anterior se rechaza antes de detener servicios y no se sustituye.

Descarga y ejecuta el instalador. Sin argumentos, en una terminal, abre el menú:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh -o /tmp/install_psiphon_autopin.sh && bash /tmp/install_psiphon_autopin.sh
```

Después de instalar, vuelve al menú en cualquier momento:

```bash
auto-pin
```

**SOCKS5:** `127.0.0.1:40000` → `1080`  ·  **HTTP:** `127.0.0.1:40001` → `8080`

Hay documentación en siete idiomas. El menú de consola está actualmente en ruso; los comandos y las opciones son iguales en todas las guías.

<a id="features"></a>

## Funciones

- Primer PIN automático: crea la caché, conecta al servidor elegido y verifica antes de declarar el PIN.
- Un túnel con PIN o un grupo de 2–32 túneles con comprobaciones por muestreo.
- Hasta 99 instancias independientes con puertos, archivos, bases, bloqueos y servicios separados.
- Grupos de países, países de Google bloqueados y coincidencia estricta opcional.
- Prueba opcional de Gemini y perfil TLS de navegador para detectar CAPTCHA.
- Umbral de velocidad con confirmación por muestras consecutivas y recuperación automática.
- SOCKS5 local, HTTP opcional, IPv4 privada y JSON outbound de Xray.
- Desinstalación que respeta Docker/Go preexistentes y otros consumidores.

<a id="menu"></a>

## Menú de consola

Tras instalar o aplicar interactivamente, se abre automáticamente el menú principal de la instancia elegida. Si la búsqueda o prueba IP sigue pendiente, se indica; un servicio iniciado no equivale a una salida verificada. Pulsa **r** para refrescar el resultado guardado sin iniciar otra prueba de red. La automatización no interactiva termina normalmente.

**Easy:** país, formato de conexión, Gemini, puerto SOCKS e intervalo del watchdog en minutos. **Advanced:** todas las opciones. Los puntos 3 y 4 del menú principal permiten administrar y seleccionar la instancia.

Easy, punto **6**, y Advanced incluyen **YouTube Mode**. El watchdog sigue en el punto 5. Si Gemini está activo, el menú ofrece una instancia independiente con puertos libres. No aplica cambios a la instancia original; sustituir su modo exige una elección y confirmación explícitas.

Con YouTube activo, Easy añade el punto **7** para la velocidad mínima de vídeo.

Enter conserva el valor; `-` vacía una lista de países. La `y` latina muestra y aplica la configuración tras confirmar con `y/n`. Cancelar conserva los archivos. Aplicar puede reconectar el túnel elegido; Easy mantiene los valores ocultos de Advanced.

El pie muestra resultados guardados; abrir el menú no hace una nueva prueba de red. Usa `check`. `NO_COLOR=1 auto-pin` desactiva el color; `TERM=dumb auto-pin` usa bordes ASCII.

<details>
<summary>Vista previa del menú</summary>

Ejemplo del renderizador actual; las direcciones y los estados mostrados son datos de demostración.

![Vista previa del menú](docs/assets/menu-preview.png)

![Easy Mode — YouTube](docs/assets/easy-mode-preview.png)

[Easy Mode (.txt)](docs/assets/easy-mode-demo.txt)

[Vista previa del menú (.txt)](docs/assets/menu-demo.txt)

</details>

<a id="examples"></a>

## Ejemplos de instalación

Cada ejemplo descarga y ejecuta el instalador sin menú. Las opciones explícitas sustituyen valores guardados; las demás se conservan al actualizar.

<details>
<summary>Ejemplos de instalación</summary>

### Sin comprobar Gemini

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --no-gemini-check
```

### Grupo de países y velocidad mínima

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL,DE,PL --min-speed 1000
```

### Segunda instancia independiente

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --instance 2 --region DE --port 40002
```

### Publicar solo SOCKS5

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --no-http
```

### Guardar una conexión Xray

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --connection xray
```

### Tres túneles y watchdog de 10 minutos

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --tunnel-pool 3 --interval 600
```

### Gemini con perfil TLS de navegador

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --gemini-check --impersonate
```

</details>

<a id="commands"></a>

## Referencia de comandos

| Comando | Función |
| --- | --- |
| `psiphon-autopin xray-routing --youtube-instance 2 --gemini-instance 1` | Exportar reglas con los puertos guardados. |
| `psiphon-autopin update` | Actualizar desde auto-pin. |
| `auto-pin` | Abrir el menú de configuración y gestión. |
| `auto-pin --instance 2` | Abrir el menú de la instancia 2. |
| `psiphon-autopin status` | Mostrar configuración y último resultado. |
| `psiphon-autopin check` | Ejecutar una comprobación nueva. |
| `psiphon-autopin rotate` | Solicitar rotación del servidor. |
| `psiphon-autopin region NL` | Cambiar a NL y vaciar el grupo anterior. |
| `psiphon-autopin pool NL,DE,PL` | Definir un grupo de países alternativos. |
| `psiphon-autopin pool ''` | Vaciar el grupo de países. |
| `psiphon-autopin speed` | Medir la velocidad mediante Psiphon. |
| `psiphon-autopin logs 100` | Mostrar registros recientes del monitor y túnel. |
| `psiphon-autopin start` | Iniciar la instancia elegida. |
| `psiphon-autopin stop` | Detener la instancia elegida. |
| `psiphon-autopin restart` | Reiniciar la instancia elegida. |
| `psiphon-autopin xray` | Imprimir el outbound SOCKS para Xray. |
| `psiphon-autopin-2 status` | Mostrar el estado de la instancia 2. |
| `psiphon-autopin menu` | Abrir el menú desde la CLI original. |
| `vps-psiphon status` | Alias compatible del mismo gestor. |
| `psiphon-autopin refresh-cache --allow-interruption` | Renovar la caché; interrumpe el túnel. |
| `psiphon-autopin prepare-pin` | Preparar un PIN para un reinicio futuro. |
| `psiphon-autopin search` | Buscar un servidor adecuado. |
| `psiphon-autopin monitor` | Entrada interna del monitor; normalmente la ejecuta systemd. |

`set-region --region NL` y `set-pool --region-pool NL,DE` son las formas largas de `region NL` y `pool NL,DE`. Las opciones de ejecución pueden cambiar la política de un comando; usa el menú o instalador para guardar toda la configuración del servicio.

```bash
psiphon-autopin set-region --region NL
psiphon-autopin set-pool --region-pool NL,DE
```

Códigos de salida de `check`: **0** resultado aceptado, **2** rechazo por política, incluida velocidad baja, **1** error de prueba/ejecución. Un resultado aceptado puede incluir Gemini `INCONCLUSIVE`.

<a id="youtube"></a>

## YouTube Mode

Opcional y **desactivado inicialmente**. Solo acepta **Google GeoIP = RU**, obtenido de YouTube mediante el SOCKS5h de esta instancia. Verifica el país y el PIN, no la ausencia de anuncios.

YouTube exige un túnel, loopback y Gemini desactivado en esa instancia. El país Psiphon puede ser AUTO u otro; no se cambia automáticamente a RU. La aceptación Google RU sustituye deny/strict sin borrar sus valores guardados. UNKNOWN se reintenta y nunca se acepta. Se conservan pausas, umbrales de velocidad, caché, candidatos de reserva y verificación del PIN.

Las nuevas instancias YouTube usan **1500 KiB/s ≈ 12,3 Mbps**. Se conservan valores guardados o explícitos. **4 MiB es el tamaño de prueba**, no la velocidad mínima. Easy muestra el punto **7** para el umbral de vídeo al activar YouTube; también existen Advanced y --min-speed. Una prueba corta no garantiza la calidad sostenida del vídeo.

Ejemplo para un VPS limpio: Gemini en la instancia 1 (40000), YouTube en la 2 (40002). En un servidor existente elige números y puertos libres, conservando Gemini. El comando Gemini siguiente es para la configuración inicial.

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh -o /tmp/install_psiphon_autopin.sh
```

### Instancia Gemini

```bash
bash /tmp/install_psiphon_autopin.sh --instance 1 --region NL --gemini-check --no-youtube-mode
```

### Instancia YouTube

```bash
bash /tmp/install_psiphon_autopin.sh --instance 2 --region AUTO --youtube-mode --no-gemini-check --tunnel-pool 1
```

Desactiva desde el menú o repite el instalador con --instance 2 --no-youtube-mode. No cambia otras instancias ni el valor actual de Gemini. Si falta youtube_mode en un JSON antiguo, equivale a false. Los grupos 2–32 siguen disponibles con YouTube desactivado.

El estado incluye IP observada, país Google, ID, velocidad, PIN y última comprobación RU correcta. Tras reinicios o datos antiguos se exige una prueba nueva.

| Status | Función |
| --- | --- |
| `DISABLED` | Desactivado. |
| `SEARCHING` | Buscando Google RU. |
| `RU VERIFIED` | RU confirmado; PIN aún sin verificar. |
| `PIN VERIFIED` | RU y PIN del servidor verificados. |
| `DEGRADED` | Problema de conexión o velocidad. |
| `UNKNOWN` | Sin GeoIP actual fiable. |

### Exportar reglas con los puertos guardados

```bash
psiphon-autopin xray-routing --youtube-instance 2 --gemini-instance 1
```

Añade los outbounds **después del outbound predeterminado existente** y coloca las reglas específicas antes de las generales. Activa sniffing en los inbounds reales o transmite dominios de destino por SOCKS/VLESS. Para Xray en Docker usa la red host. Estos proxies TCP no transportan QUIC; el ejemplo bloquea UDP/443 solo para los dominios elegidos y permite volver a TCP. Los nombres ocultos o cifrados pueden impedir la detección. No se modifica Xray automáticamente.

[JSON + sniffing](docs/xray/README.md)

<a id="xray"></a>

## Integración con Xray

La ruta es **Xray → SOCKS5 → Psiphon → Internet**. xray imprime el outbound; --connection xray también guarda xray-outbound.json. Añade el outbound y las reglas de enrutamiento a Xray. Se utiliza el mismo SOCKS5, sin crear otro transporte.

```bash
psiphon-autopin xray
```

```json
{
  "tag": "psiphon-out",
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "127.0.0.1", "port": 40000}]
  }
}
```

En una red Docker bridge, 127.0.0.1 apunta al contenedor Xray. Usa la red del host o una IPv4 privada existente del VPS mediante --bind. No se admite una dirección pública. El proxy está destinado a TCP.

<a id="options"></a>

## Opciones del instalador

El menú usa minutos para el watchdog; --interval y el campo JSON interval siempre usan segundos. Sustituye los valores de ejemplo según tu configuración.

Una instalación nueva con `auto` usa `vps-psiphon`; se conservan los backends reconocidos existentes. `console` requiere loopback. `--no-gemini-check` mantiene comprobaciones de país, velocidad y recuperación.

<details>
<summary>Opciones del instalador</summary>

| Opción | Valor inicial | Función |
| --- | --- | --- |
| `--youtube-mode` / `--no-youtube-mode` | desactivado | Exigir Google RU y PIN verificado de un solo túnel; incompatible con Gemini en la misma instancia. |
| `--region NL / --region AUTO / --region NL,DE` | menú / obligatorio sin interacción (NL) | País Psiphon de dos letras, AUTO o lista separada por comas. |
| `--instance N` | 1 | Elegir instancia 1–99. |
| `--port N` | 40000 + 2 × (N−1) | Puerto SOCKS 1024–65534; HTTP usa el siguiente. |
| `--connection socks5\|xray` | socks5 | Guardar salida como dirección SOCKS5 o JSON Xray. |
| `--menu / --interactive` | TTY / 0 args | Abrir el asistente; admite --instance N. |
| `--menu-mode easy\|advanced` | easy | Recordar el modo Easy o Advanced. |
| `--region-pool NL,DE` | vacío | Lista de países alternativos. |
| `--bind ADDR` | 127.0.0.1 | Usar loopback o una IPv4 privada existente. |
| `--bind-loopback` | 127.0.0.1 | Restablecer 127.0.0.1. |
| `--http / --no-http` | activado | Activar/desactivar publicación HTTP. |
| `--gemini-check / --no-gemini-check` | activado | Activar/desactivar prueba de Gemini. |
| `--impersonate / --no-impersonate` | desactivado | Activar/desactivar TLS de navegador para la página Gemini. |
| `--strict-region / --no-strict-region` | desactivado | Exigir/desactivar coincidencia estricta del país Google. |
| `--interval N` | 300 s | Intervalo normal en segundos; mínimo 60. |
| `--wait N` | 75 s | Espera de conexión en segundos; mínimo 20. |
| `--delay N` | 12 s | Pausa entre intentos en segundos; mínimo 2. |
| `--min-speed N` | 800 / 1500 (YouTube) KiB/s | Mínimo KiB/s; 0 desactiva la rotación por velocidad. |
| `--probe-mb N` | 4 MiB | Muestra de 0–10 MiB; con 0 y umbral activo se mide una página. |
| `--slow-threshold N` | 2 | Muestras lentas consecutivas antes de rotar, 2–20. |
| `--fail-threshold N` | 3 | Fallos consecutivos antes de recuperar, 2–20. |
| `--deny-regions 'RU BY IR SY CU KP CN VE'` | RU BY IR SY CU KP CN VE | Países Google bloqueados; una cadena vacía limpia la lista. |
| `--tunnel-pool N` | 1 | 1 usa PIN; 2–32 utiliza un grupo sin un único PIN fijo. |
| `--backend auto\|console\|vps-psiphon` | auto | Detectar/conservar el backend o elegirlo explícitamente. |
| `--help` | — | Mostrar ayuda del instalador. |

</details>

<a id="operations"></a>

## Actualización y mantenimiento

### Actualizar desde auto-pin

El punto **5 — Update Auto-Pin (GitHub)** actualiza la instancia instalada elegida conservando sus ajustes. Las demás no cambian; elígelas con el punto 4. Resuelve main a un commit fijo, verifica el blob Git y la sintaxis Bash, muestra versión/commit/SHA-256 y pide confirmación. Un error de red o verificación impide ejecutar el instalador. Se rechazan versiones antiguas. El menú principal actualizado se abre automáticamente tras el éxito.

Estos comandos abren la misma actualización con confirmación. La función aparece tras instalar esta versión; publica primero todos los archivos del lanzamiento en tu repositorio.

```bash
auto-pin --update
psiphon-autopin update
psiphon-autopin-2 update
```

Se elige el menú instalado más nuevo; una primera instancia antigua no oculta funciones nuevas.

### Actualizar una instancia

Vuelve a descargar el instalador actual y aplícalo a la instancia. Conserva la configuración salvo las opciones indicadas. Abrir auto-pin no descarga una versión nueva.

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh -o /tmp/install_psiphon_autopin.sh && bash /tmp/install_psiphon_autopin.sh --instance 1
```

### Diagnóstico

Consulta el estado, sigue solo el registro del monitor y comprueba ambos proxies configurados:

```bash
psiphon-autopin status
journalctl -u psiphon-autopin.service -n 100 --no-pager
journalctl -u psiphon-autopin.service -f
systemctl status vps-psiphon.service psiphon-autopin.service --no-pager
```

```bash
curl -4 -fsS --noproxy '' --proxy socks5h://127.0.0.1:40000 https://api.ipify.org
```

```bash
curl -4 -fsS --noproxy '' --proxy http://127.0.0.1:40001 https://api.ipify.org
```

Las pruebas de conexión, IP, país, Gemini y velocidad usan SOCKS con DNS remoto sin conexión directa alternativa. Las descargas del instalador pueden usar la red del VPS. WARP no se elimina automáticamente.

### Instancias independientes

Usa psiphon-autopin-N o auto-pin --instance N. Estos son los puertos iniciales; --port permite cambiarlos. Los límites 99/32 son límites de configuración, no una garantía de capacidad del VPS.

| # | SOCKS5 | HTTP | CLI |
| --- | --- | --- | --- |
| 1 | `40000` | `40001` | `psiphon-autopin` |
| 2 | `40002` | `40003` | `psiphon-autopin-2` |
| 3 | `40004` | `40005` | `psiphon-autopin-3` |

### Watchdog y tráfico

El punto 5 de Easy y Advanced permiten elegir minutos: mínimo 1, inicialmente 5. Se aceptan fracciones como 1.5 si equivalen a segundos enteros. Los reintentos por fallos pueden ser más frecuentes. No hay un segundo watchdog de Chara.

Valores iniciales: Gemini activo, un túnel, 800 KiB/s, dos muestras lentas, prueba de 4 MiB y tres fallos antes de recuperar. Una prueba de 4 MiB cada cinco minutos consume unos 34 GiB en 30 días, sin búsquedas. --min-speed 0 desactiva rotación por velocidad; --probe-mb 0 por sí solo puede seguir midiendo una página.

<a id="uninstall"></a>

## Desinstalación

Eliminar la instancia conservando Docker/Go:

```bash
psiphon-autopin uninstall
```

Eliminar la instancia y los paquetes Docker/Go elegibles que instaló este gestor:

```bash
psiphon-autopin uninstall --purge-deps
```

```bash
psiphon-autopin-2 uninstall --purge-deps
```

Desde 4.2 se registra el origen de cada componente. Se conservan los paquetes previos o de origen desconocido. Otras instancias conservan dependencias compartidas; otros contenedores activos/detenidos o un uso desconocido conservan Docker. La simulación APT impide eliminar paquetes ajenos.

Las instalaciones antiguas sin registro conservan las dependencias. No se usa autoremove ni se borran datos Docker arbitrariamente. Permanecen Python, curl, GCC y las copias de migración. Los puntos 13 y 14 del menú corresponden a estos modos.

La desinstalación simple de la última instancia libera el registro de propiedad y conserva dependencias. Elige `--purge-deps` al desinstalar si deseas eliminar las dependencias propias elegibles.

Si falla la eliminación APT, se informa del error y se conserva el registro. Tras corregir APT, vuelve a intentarlo desde el proyecto descargado:

```bash
python3 autopin_system.py cleanup --purge
```

<a id="faq"></a>

## Preguntas frecuentes

<details>
<summary>¿Cómo sé que el PIN está verificado?</summary>

Busca INITIAL PIN VERIFIED y adopted_unpinned: false. pin_prepared: true solo indica preparación. El primer PIN reconecta el túnel; si falla la verificación se revierte y se reintenta en otro ciclo.

</details>

<details>
<summary>¿INCONCLUSIVE confirma Gemini?</summary>

No se confirmó una respuesta del modelo. SERVING es una prueba anónima satisfactoria; INCONCLUSIVE no está resuelto y no provoca rotación por sí solo. La política permite un PIN verificado con Gemini inconcluso. No se comprueba tu cuenta del navegador.

</details>

<details>
<summary>¿Por qué difieren ip y server_ip?</summary>

ip es la salida pública del proxy; server_ip es el servidor Psiphon. El mismo servidor puede cambiar su IP de salida al reconectar; no se garantiza una IP invariable.

</details>

<details>
<summary>¿Por qué y pide repetir?</summary>

Se rechaza UTF-8 incorrecto para evitar aplicar una entrada dañada o cerrar el menú. Escribe de nuevo la y latina y confirma con y/n.

</details>

<details>
<summary>¿Por qué Google muestra otro país?</summary>

EgressRegion solicita una región Psiphon; Google puede clasificar la salida de otro modo. La lista de bloqueo y strict-region controlan su aceptación. No se garantiza un país ni el acceso a un servicio.

</details>

<a id="files"></a>

## Archivos y configuración

Las rutas son de la instancia 1. Las demás añaden -N a sus directorios de aplicación, datos y configuración; el registro de origen y las copias son compartidos. Los archivos de conexión y servidores contienen configuración privada.

| Ruta | Función |
| --- | --- |
| `/var/lib/psiphon-autopin/youtube-status.json` | Última observación YouTube y metadatos de vigencia. |
| `/var/lib/psiphon-autopin/update-source.json` | Commit y suma del código de la última actualización correcta desde el menú. |
| `/var/lib/psiphon-autopin/settings.json` | Configuración efectiva y preferencias del menú. |
| `/var/lib/psiphon-autopin/state.json` | Último resultado y estado del PIN. |
| `/opt/vps-psiphon/config/psiphon.config` | Configuración privada Psiphon y entrada objetivo. |
| `/var/lib/psiphon-autopin/server-entry-cache.json` | Caché privada de servidores. |
| `/var/lib/psiphon-autopin/connection.json` | Formato de conexión elegido. |
| `/var/lib/psiphon-autopin/xray-outbound.json` | Outbound Xray cuando se elige ese formato. |
| `/var/lib/psiphon-autopin-system/dependencies.json` | Registro de origen Docker/Go, permisos 0600. |
| `/var/backups/psiphon-autopin` | Copias de migración y recuperación. |

<a id="security"></a>

## Seguridad

Las imágenes Psiphon/Debian se fijan por digest. ConsoleClient procede de un commit fijo y se verifica por SHA-256 antes de usarlo, también al actualizar. Los contenedores usan UID 1000, ninguna capability, raíz de solo lectura y no-new-privileges. systemd limita archivos y capacidades; el controlador Docker aún necesita privilegios equivalentes a root. --bind privado explícito se conserva fuera de YouTube. Consulta las notas de seguridad.

[SECURITY.md](SECURITY.md) · [SECURITY.ru_RU.md](SECURITY.ru_RU.md)

<a id="development"></a>

## Desarrollo y agradecimientos

Desde una copia local del proyecto:

```bash
python3 -m unittest discover -s tests -v
bash -n install_psiphon_autopin.sh
```

[CHANGELOG](CHANGELOG.md) · [tests](tests)

Componentes utilizados: [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker), [bbolt](https://github.com/etcd-io/bbolt), [curl-impersonate](https://github.com/lexiforest/curl-impersonate).

Licencia [GPL-3.0](LICENSE). Se estudiaron ideas operativas de [Chara vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon); su instalador y watchdog no se ejecutan aquí. La organización del README se inspira en [3x-ui](https://github.com/MHSanaei/3x-ui).
