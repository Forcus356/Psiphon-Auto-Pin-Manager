<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**Rotación automática de servidores Psiphon y fijación de IP según Google**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

Gestor para Linux que selecciona servidores Psiphon individualmente, comprueba la IP de salida y el país detectado por Google **solo a través del SOCKS5h local**, y fija una salida válida. Si Google la clasifica como RU, vuelve a buscar.

## ✨ Características

- Selección de servidores mediante `TargetServerEntry`
- Lectura de BoltDB en modo de solo lectura
- Comprobación de IP y país de Google con SOCKS5h, sin conexión directa alternativa
- Fijación verificada, monitorización periódica y cambio automático
- País, puerto e intervalos configurables
- Compatible con Docker CE o `docker.io` existentes

## 📋 Requisitos

Ubuntu o Debian **x86_64**, root, systemd y acceso a Internet. Comprueba que el proveedor permita VPN o proxies.

## 🚀 Inicio rápido

Selección interactiva de país y puerto:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### Ejemplos no interactivos

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ Opciones de instalación

| Opción | Predeterminado | Descripción |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | País del servidor Psiphon (código de dos letras) o `AUTO`. |
| `--port 40000` | Prompt; `40000` | Puerto SOCKS5 local, de 1024 a 65534; HTTP usa el siguiente. |
| `--interval 3600` | `3600` | Intervalo de monitorización en segundos; mínimo 60. |
| `--wait 75` | `75` | Espera de conexión en segundos; mínimo 20. |
| `--delay 12` | `12` | Pausa entre intentos en segundos; mínimo 2. |
| `--help` | — | Mostrar ayuda. |

## 🧰 Comandos del gestor

| Command | Description |
|---|---|
| `status` | Mostrar estado y salida fijada |
| `check` | Comprobar IP y Google mediante SOCKS5h; códigos 0=no RU, 2=RU |
| `search` | Buscar servidor; detener antes el monitor |
| `monitor` | Monitorización continua por systemd |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

`--region`, `--port`, `--interval`, `--wait`, `--delay` — Descripción.

## 🛠️ Servicio y diagnóstico

```bash
journalctl -u psiphon-autopin -f
journalctl -u psiphon-autopin -n 80 --no-pager
systemctl status psiphon-autopin --no-pager
systemctl restart psiphon-autopin
systemctl stop psiphon-autopin
systemctl enable --now psiphon-autopin
docker logs --tail 80 vps-psiphon
docker ps -a --filter name=vps-psiphon
```

## 📌 Ejemplos

```bash
# Exit IP through Psiphon
curl -4 -fsS --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search; monitor must not be running
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin
```

## 🔄 Funcionamiento

El gestor lee las entradas de Psiphon desde BoltDB en modo de solo lectura, selecciona un servidor con `TargetServerEntry` y comprueba la IP y región de Google mediante SOCKS5h. Confirma el resultado dos veces antes de guardarlo.

## ⚠️ Notas importantes

`--region PL` no garantiza `Google=PL`: el criterio actual es `Google != RU`. La IP del servidor puede diferir de la IP de salida. Cambiar de servidor interrumpe las conexiones activas.

Los puertos SOCKS5 y HTTP escuchan solo en `127.0.0.1`; HTTP usa el puerto SOCKS + 1. Las descargas de instalación usan la conexión del VPS. Revisa el código antes de ejecutarlo como root.

## 🩺 Solución de problemas

| Error | Solution |
|---|---|
| `containerd.io : Conflicts: containerd` | Conflicto de paquetes Docker CE/docker.io; no elimines Docker sin comprobarlo. |
| `Config exists but container missing` | Guarda la configuración antigua e identifica su servicio. |
| `SOCKS/HTTP port ... occupied` | Comprueba con `ss -lntp` y cambia `--port`. |
| `No known servers in region` | Revisa los logs de Docker: la base de servidores puede estar vacía. |
| `Another search/monitor is running` | Detén la monitorización antes de `search`. |

## 📂 Rutas de instalación

```text
/opt/vps-psiphon/config/psiphon.config
/opt/psiphon-autopin/psiphon_autopin.py
/opt/psiphon-autopin/psiphon-server-export
/opt/psiphon-autopin/ipregion.sh
/var/lib/psiphon-autopin/settings.json
/var/lib/psiphon-autopin/state.json
/etc/systemd/system/psiphon-autopin.service
```

## 📄 Licencia y créditos

[GPL-3.0](LICENSE) · [Forcus356](https://github.com/Forcus356) · [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) · [ipregion](https://github.com/Davoyan/ipregion) · [bbolt](https://github.com/etcd-io/bbolt). Independent project; not officially affiliated with Psiphon.
