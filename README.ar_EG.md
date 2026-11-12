<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**تدوير خوادم Psiphon تلقائيًا وتثبيت عنوان الخروج حسب موقع Google**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

أداة Linux تختار خوادم Psiphon واحدًا تلو الآخر، وتتحقق من عنوان IP الخارج وبلد Google **عبر SOCKS5h المحلي فقط**، ثم تثبّت اتصالًا مناسبًا. إذا صُنّف العنوان RU تبدأ عملية بحث جديدة.

## ✨ الميزات

- اختيار خوادم Psiphon واحدًا تلو الآخر باستخدام `TargetServerEntry`
- قراءة قاعدة BoltDB دون تعديلها
- فحص عنوان الخروج وبلد Google عبر SOCKS5h دون اتصال مباشر احتياطي
- تثبيت الاتصال بعد التأكد والمراقبة الدورية والتبديل التلقائي
- إمكانية اختيار البلد والمنفذ والفواصل الزمنية
- دعم Docker CE أو `docker.io` الموجود مسبقًا

## 📋 المتطلبات

Ubuntu أو Debian بمعمارية **x86_64** مع صلاحيات root وsystemd واتصال إنترنت. تحقق من شروط الاستضافة بشأن VPN والبروكسي.

## 🚀 البدء السريع

اختيار البلد والمنفذ تفاعليًا:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### أمثلة بدون أسئلة

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ خيارات التثبيت

| الخيار | الافتراضي | الوصف |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | بلد خادم Psiphon (رمز من حرفين) أو `AUTO`. |
| `--port 40000` | Prompt; `40000` | منفذ SOCKS5 محلي من 1024 إلى 65534؛ منفذ HTTP هو التالي. |
| `--interval 3600` | `3600` | فترة المراقبة بالثواني، الحد الأدنى 60. |
| `--wait 75` | `75` | مهلة الاتصال بالثواني، الحد الأدنى 20. |
| `--delay 12` | `12` | التأخير بين المحاولات بالثواني، الحد الأدنى 2. |
| `--help` | — | عرض المساعدة. |

## 🧰 أوامر المدير

| Command | Description |
|---|---|
| `status` | عرض الحالة وعنوان الخروج المحفوظ |
| `check` | فحص IP وGoogle عبر SOCKS5h؛ 0=ليس RU و2=RU |
| `search` | البحث عن خادم؛ أوقف خدمة المراقبة أولًا |
| `monitor` | مراقبة مستمرة عبر systemd |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

`--region`, `--port`, `--interval`, `--wait`, `--delay` — الوصف.

## 🛠️ إدارة الخدمة والتشخيص

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

## 📌 أمثلة

```bash
# Exit IP through Psiphon
curl -4 -fsS --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search; monitor must not be running
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin
```

## 🔄 آلية العمل

يقرأ المدير قائمة خوادم Psiphon من BoltDB بوضع القراءة فقط، ويختار خادمًا بواسطة `TargetServerEntry`، ثم يفحص IP الخارج وتصنيف Google عبر SOCKS5h. يُثبَّت الاتصال بعد التحقق مرتين.

## ⚠️ ملاحظات مهمة

`--region PL` لا يضمن `Google=PL`؛ الشرط الحالي هو `Google != RU`. قد يختلف عنوان الخادم عن عنوان الخروج، ويقطع تبديل الخادم الاتصالات الحالية.

تستمع منافذ SOCKS5 وHTTP على `127.0.0.1` فقط؛ منفذ HTTP يساوي منفذ SOCKS + 1. تنزيلات التثبيت تستخدم اتصال VPS المباشر. راجع الشيفرة قبل تشغيلها بصلاحيات root.

## 🩺 حل المشكلات

| Error | Solution |
|---|---|
| `containerd.io : Conflicts: containerd` | تعارض حزم Docker CE وdocker.io؛ لا تحذف Docker دون فحص. |
| `Config exists but container missing` | احتفظ بالإعدادات القديمة وحدد الخدمة التي أنشأتها. |
| `SOCKS/HTTP port ... occupied` | افحص المنفذ باستخدام `ss -lntp` ثم غيّر `--port`. |
| `No known servers in region` | افحص سجل Docker؛ ربما لم تُملأ قاعدة الخوادم بعد. |
| `Another search/monitor is running` | أوقف خدمة المراقبة قبل تشغيل `search`. |

## 📂 مسارات التثبيت

```text
/opt/vps-psiphon/config/psiphon.config
/opt/psiphon-autopin/psiphon_autopin.py
/opt/psiphon-autopin/psiphon-server-export
/opt/psiphon-autopin/ipregion.sh
/var/lib/psiphon-autopin/settings.json
/var/lib/psiphon-autopin/state.json
/etc/systemd/system/psiphon-autopin.service
```

## 📄 الترخيص والاعتمادات

[GPL-3.0](LICENSE) · [Forcus356](https://github.com/Forcus356) · [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) · [ipregion](https://github.com/Davoyan/ipregion) · [bbolt](https://github.com/etcd-io/bbolt). Independent project; not officially affiliated with Psiphon.
