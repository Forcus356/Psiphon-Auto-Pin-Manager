<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**Автоматический перебор серверов Psiphon и закрепление выходного IP по геолокации Google**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) ![Arch](https://img.shields.io/badge/arch-x86__64-lightgrey) [![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

Менеджер для Linux, который выбирает **конкретные серверы Psiphon**, определяет выходной IP и страну Google **строго через локальный SOCKS5h**, а затем закрепляет подходящее соединение. Если Google начинает определять IP как RU, запускается новый поиск.

## ✨ Возможности

- Перебор отдельных серверов через `TargetServerEntry`, а не только протоколов
- Чтение списка серверов из BoltDB в режиме read-only
- Проверка IP и региона Google через SOCKS5h без прямого fallback
- Двойная проверка перед закреплением, мониторинг и восстановление
- Выбор страны, локального порта и интервалов
- Совместимость с установленным Docker CE или Ubuntu `docker.io`

## 📋 Требования

Ubuntu или Debian **x86_64**, права root, systemd, доступ в интернет и место для Docker/Go. Перед запуском установщика с правами root рекомендуется проверить его исходники. Убедитесь, что правила хостинга разрешают прокси/VPN.

## 🚀 Быстрый старт

Интерактивный выбор страны и порта:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### Примеры без вопросов

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ Параметры установщика

| Параметр | По умолчанию | Описание |
|---|---|---|
| `--region DE` | Вопрос; `[DE]` | Страна серверов Psiphon: двухбуквенный код (`DE`, `PL`, `NL` и др.). `AUTO` — без ограничения страны. |
| `--port 40000` | Вопрос; `40000` | Локальный SOCKS5-порт от **1024 до 65534**. HTTP-прокси будет слушать следующий порт. |
| `--interval 3600` | `3600` | Период мониторинга в секундах, минимум **60**. |
| `--wait 75` | `75` | Ожидание подключения Psiphon в секундах, минимум **20**. |
| `--delay 12` | `12` | Пауза между попытками в секундах, минимум **2**. |
| `--help` | — | Показать справку установщика. |

## 🧰 Команды менеджера

После установки менеджер находится в `/opt/psiphon-autopin/psiphon_autopin.py`. Команды: `status`, `check`, `search`, `monitor`.

| Command | Description |
|---|---|
| `status` | Показать регион, прокси и сохранённое закрепление. |
| `check` | Проверить IP и Google через SOCKS5h. Код выхода: `0` — не RU, `2` — RU, `1` — ошибка. |
| `search` | Начать перебор до подходящего IP. Предварительно остановите systemd-службу, иначе сработает блокировка параллельного запуска. |
| `monitor` | Запустить постоянный мониторинг вручную; обычно этим управляет systemd. |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

### Опции менеджера

Поддерживаются `--region`, `--port`, `--interval`, `--wait`, `--delay`. Значения региона и порта по умолчанию читаются из сохранённых настроек.

## 🛠️ Управление и диагностика

| Action | Command |
|---|---|
| Журнал онлайн | `journalctl -u psiphon-autopin -f` |
| Последние записи | `journalctl -u psiphon-autopin -n 80 --no-pager` |
| Статус службы | `systemctl status psiphon-autopin --no-pager` |
| Перезапуск мониторинга | `systemctl restart psiphon-autopin` |
| Остановка мониторинга | `systemctl stop psiphon-autopin` |
| Автозапуск мониторинга | `systemctl enable --now psiphon-autopin` |
| Запуск мониторинга | `systemctl start psiphon-autopin` |
| Логи Psiphon | `docker logs --tail 80 vps-psiphon` |
| Контейнер | `docker ps -a --filter name=vps-psiphon` |

## 📌 Примеры

```bash
# Check the exit strictly through Psiphon SOCKS5h
curl -4 -fsS --max-time 15 --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search (stop the monitor to release its lock)
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin

# Stop/start the monitor (does not stop the Psiphon container)
systemctl stop psiphon-autopin
systemctl start psiphon-autopin
```

## 🔄 Принцип работы

Psiphon создаёт локальную базу серверов. Менеджер читает её через Go/BoltDB, выбирает сервер, записывает `TargetServerEntry` и подключается. Выходной IPv4 и регион Google проверяются через локальный SOCKS5h. При успехе IP повторно проверяется и закрепляется. Далее раз в час проводится проверка; поиск запускается при двукратном подтверждении RU. Временная ошибка проверки не приравнивается к RU.

## ⚠️ Важно

- **`--region PL` не означает `Google=PL`.** Критерий принятия сейчас — `Google != RU`.
- **IP сервера Psiphon может отличаться от выходного IP**, который видит Google.
- SOCKS5 и HTTP-прокси слушают только `127.0.0.1`; не выставляйте их наружу.
- Проверка IP/Google идёт через прокси, но загрузка зависимостей и установка используют прямое соединение VPS.
- При смене сервера действующие подключения обрываются. Конкретный IP и доступность сервисов не гарантируются.
- `search` и `monitor` используют общую блокировку; не запускайте их одновременно.
- При смене порта или страны повторите установку с новыми параметрами — возможно переподключение.
- Проверьте правила хостинга на допустимость VPN/прокси.

## 🩺 Решение проблем

| Error | Resolution |
|---|---|
| `containerd.io : Conflicts: containerd` | Конфликт пакетов Docker CE и Ubuntu `docker.io`. v3.3 старается использовать уже имеющийся Docker. Не удаляйте containerd без проверки. |
| `Config exists but container missing` | Есть конфигурация от прежней установки, но нет ожидаемого контейнера. Сохраните её и определите, какому сервису она принадлежит, прежде чем переносить. |
| `SOCKS/HTTP port ... occupied` | Занят SOCKS-порт или следующий за ним HTTP-порт. Проверьте через `ss -lntp` и укажите другой `--port`. |
| `No known servers in region` | База серверов ещё не заполнена или нет записей выбранной страны. Проверьте логи Docker. |
| `Another search/monitor is running` | Перед ручным `search` остановите `psiphon-autopin.service`. |

## 📂 Пути файлов

| Path | Purpose |
|---|---|
| `/opt/vps-psiphon/config/psiphon.config` | Конфигурация Psiphon |
| `/opt/psiphon-autopin/psiphon_autopin.py` | Менеджер |
| `/opt/psiphon-autopin/psiphon-server-export` | Экспортёр BoltDB |
| `/opt/psiphon-autopin/ipregion.sh` | Проверка геолокации |
| `/var/lib/psiphon-autopin/settings.json` | Страна и порт |
| `/var/lib/psiphon-autopin/state.json` | Состояние закрепления |
| `/etc/systemd/system/psiphon-autopin.service` | Служба systemd |

## 📄 Лицензия и авторы

Лицензия [GPL-3.0](LICENSE). Автор проекта — [Forcus356](https://github.com/Forcus356). Используются [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [ipregion](https://github.com/Davoyan/ipregion), [bbolt](https://github.com/etcd-io/bbolt). Проект независимый и не является официальным продуктом Psiphon.
