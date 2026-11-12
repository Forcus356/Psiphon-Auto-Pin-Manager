<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**چرخش خودکار سرورهای Psiphon و تثبیت IP خروجی بر اساس موقعیت Google**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

ابزاری برای لینوکس که سرورهای Psiphon را به‌صورت جداگانه انتخاب می‌کند، IP خروجی و کشور Google را **فقط از طریق SOCKS5h محلی** بررسی می‌کند و اتصال مناسب را ثابت نگه می‌دارد. اگر Google خروجی را RU تشخیص دهد، جستجو دوباره آغاز می‌شود.

## ✨ ویژگی‌ها

- انتخاب تک‌تک سرورهای Psiphon با `TargetServerEntry`
- خواندن فهرست سرورها از BoltDB در حالت فقط‌خواندنی
- بررسی IP خروجی و کشور Google با SOCKS5h، بدون اتصال مستقیم جایگزین
- تثبیت خروجی پس از تأیید، بررسی ساعتی و تغییر خودکار
- امکان تنظیم کشور، پورت و زمان‌بندی
- سازگاری با Docker CE و `docker.io` موجود

## 📋 نیازمندی‌ها

Ubuntu یا Debian نسخه **x86_64**، دسترسی root، systemd و اینترنت. قوانین سرویس‌دهنده درباره VPN و پروکسی را بررسی کنید.

## 🚀 شروع سریع

انتخاب تعاملی کشور و پورت:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### نمونه‌های بدون تعامل

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ پارامترهای نصب

| پارامتر | پیش‌فرض | توضیح |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | کشور سرور Psiphon (کد دوحرفی) یا `AUTO`. |
| `--port 40000` | Prompt; `40000` | پورت محلی SOCKS5 از 1024 تا 65534؛ پورت HTTP یک عدد بیشتر است. |
| `--interval 3600` | `3600` | فاصله بررسی به ثانیه، حداقل 60. |
| `--wait 75` | `75` | زمان انتظار اتصال به ثانیه، حداقل 20. |
| `--delay 12` | `12` | مکث بین تلاش‌ها به ثانیه، حداقل 2. |
| `--help` | — | نمایش راهنما. |

## 🧰 فرمان‌های مدیر

| Command | Description |
|---|---|
| `status` | نمایش وضعیت و IP ثابت‌شده |
| `check` | بررسی IP و Google از SOCKS5h؛ کد خروج 0=غیرRU، 2=RU |
| `search` | جستجوی سرور؛ ابتدا سرویس مانیتور را متوقف کنید |
| `monitor` | مانیتورینگ دائمی؛ معمولاً با systemd |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

`--region`, `--port`, `--interval`, `--wait`, `--delay` — توضیح.

## 🛠️ مدیریت سرویس و عیب‌یابی

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

## 📌 نمونه‌ها

```bash
# Exit IP through Psiphon
curl -4 -fsS --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search; monitor must not be running
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin
```

## 🔄 نحوه کار

مدیر، فهرست سرورها را از BoltDB به‌صورت فقط‌خواندنی دریافت می‌کند، با `TargetServerEntry` سرور معینی را انتخاب می‌کند و IP و کشور خروجی را از طریق SOCKS5h بررسی می‌کند. خروجی غیر RU پس از بررسی مجدد ثبت می‌شود.

## ⚠️ نکات مهم

`--region PL` لزوماً به معنای `Google=PL` نیست؛ معیار پذیرش `Google != RU` است. IP سرور و IP خروجی ممکن است متفاوت باشند. تغییر سرور اتصال فعلی را قطع می‌کند.

پورت‌های SOCKS5 و HTTP تنها روی `127.0.0.1` باز هستند؛ پورت HTTP یک عدد بیشتر است. دانلود وابستگی‌ها از اتصال عادی VPS انجام می‌شود. کد اسکریپت‌ها را پیش از اجرای root بررسی کنید.

## 🩺 رفع اشکال

| Error | Solution |
|---|---|
| `containerd.io : Conflicts: containerd` | تداخل بسته‌های Docker CE و docker.io؛ بدون بررسی حذف نکنید. |
| `Config exists but container missing` | پیکربندی قدیمی را حفظ کرده و سرویس مربوط به آن را شناسایی کنید. |
| `SOCKS/HTTP port ... occupied` | با `ss -lntp` بررسی کنید و `--port` دیگری انتخاب کنید. |
| `No known servers in region` | لاگ‌های Docker را بررسی کنید؛ دیتابیس ممکن است هنوز پر نشده باشد. |
| `Another search/monitor is running` | پیش از اجرای `search` سرویس مانیتور را متوقف کنید. |

## 📂 مسیرهای نصب

```text
/opt/vps-psiphon/config/psiphon.config
/opt/psiphon-autopin/psiphon_autopin.py
/opt/psiphon-autopin/psiphon-server-export
/opt/psiphon-autopin/ipregion.sh
/var/lib/psiphon-autopin/settings.json
/var/lib/psiphon-autopin/state.json
/etc/systemd/system/psiphon-autopin.service
```

## 📄 مجوز و منابع

[GPL-3.0](LICENSE) · [Forcus356](https://github.com/Forcus356) · [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) · [ipregion](https://github.com/Davoyan/ipregion) · [bbolt](https://github.com/etcd-io/bbolt). Independent project; not officially affiliated with Psiphon.
