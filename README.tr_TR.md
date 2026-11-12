<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**Otomatik Psiphon sunucu değiştirme ve Google konumuna göre çıkış IP sabitleme**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

Linux aracı: Psiphon sunucularını tek tek seçer, çıkış IP’sini ve Google ülkesini **yalnızca yerel SOCKS5h üzerinden** kontrol eder ve uygun çıkışı sabitler. Google çıkışı RU olarak görürse yeniden arar.

## ✨ Özellikler

- `TargetServerEntry` ile tek tek Psiphon sunucusu seçimi
- Salt okunur BoltDB sunucu listesi
- SOCKS5h üzerinden çıkış IP ve Google ülke kontrolü; doğrudan bağlantıya geri dönüş yok
- Doğrulanmış çıkışı sabitleme, düzenli izleme ve otomatik değiştirme
- Ülke, port ve aralık ayarları
- Mevcut Docker CE veya `docker.io` ile uyumluluk

## 📋 Gereksinimler

Ubuntu veya Debian **x86_64**, root, systemd ve internet erişimi gerekir. Barındırma sağlayıcınızın VPN/proxy kurallarını kontrol edin.

## 🚀 Hızlı başlangıç

Ülke ve bağlantı noktası için etkileşimli kurulum:

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### Etkileşimsiz örnekler

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ Kurulum seçenekleri

| Seçenek | Varsayılan | Açıklama |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | Psiphon sunucusu ülke kodu (iki harf) veya `AUTO`. |
| `--port 40000` | Prompt; `40000` | Yerel SOCKS5 portu 1024–65534; HTTP bir sonraki portu kullanır. |
| `--interval 3600` | `3600` | Saniye cinsinden izleme aralığı; en az 60. |
| `--wait 75` | `75` | Saniye cinsinden bağlantı bekleme süresi; en az 20. |
| `--delay 12` | `12` | Saniye cinsinden denemeler arası bekleme; en az 2. |
| `--help` | — | Yardımı göster. |

## 🧰 Yönetici komutları

| Command | Description |
|---|---|
| `status` | Kayıtlı sabit çıkışı ve durumu göster |
| `check` | SOCKS5h ile IP/Google denetimi; çıkış 0=RU değil, 2=RU |
| `search` | Sunucu ara; önce izleme servisini durdur |
| `monitor` | Sürekli izleme; normalde systemd çalıştırır |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

`--region`, `--port`, `--interval`, `--wait`, `--delay` — Açıklama.

## 🛠️ Servis ve tanılama

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

## 📌 Örnekler

```bash
# Exit IP through Psiphon
curl -4 -fsS --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search; monitor must not be running
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin
```

## 🔄 Nasıl çalışır?

Yönetici Psiphon sunucu listesini BoltDB’den salt okunur biçimde alır, `TargetServerEntry` ile belirli sunucuyu seçer ve çıkış IP’si ile Google ülkesini SOCKS5h üzerinden doğrular. İki kontrolden sonra uygun çıkış kaydedilir.

## ⚠️ Önemli notlar

`--region PL`, `Google=PL` anlamına gelmez; mevcut koşul `Google != RU` şeklindedir. Sunucu IP’si ve çıkış IP’si farklı olabilir. Sunucu değişimi aktif bağlantıları keser.

SOCKS5 ve HTTP yalnızca `127.0.0.1` üzerinde dinler; HTTP portu SOCKS + 1 olur. Kurulum indirmeleri doğrudan VPS bağlantısını kullanır. Root olarak çalıştırmadan önce kodu inceleyin.

## 🩺 Sorun giderme

| Error | Solution |
|---|---|
| `containerd.io : Conflicts: containerd` | Docker CE ve docker.io paket çakışması; Docker’ı kontrol etmeden kaldırmayın. |
| `Config exists but container missing` | Eski yapılandırmayı yedekleyin ve hangi servise ait olduğunu belirleyin. |
| `SOCKS/HTTP port ... occupied` | `ss -lntp` ile kontrol edin ve farklı `--port` kullanın. |
| `No known servers in region` | Docker günlüklerini kontrol edin; sunucu listesi henüz dolmamış olabilir. |
| `Another search/monitor is running` | `search` öncesi izleme servisini durdurun. |

## 📂 Kurulum yolları

```text
/opt/vps-psiphon/config/psiphon.config
/opt/psiphon-autopin/psiphon_autopin.py
/opt/psiphon-autopin/psiphon-server-export
/opt/psiphon-autopin/ipregion.sh
/var/lib/psiphon-autopin/settings.json
/var/lib/psiphon-autopin/state.json
/etc/systemd/system/psiphon-autopin.service
```

## 📄 Lisans ve teşekkürler

[GPL-3.0](LICENSE) · [Forcus356](https://github.com/Forcus356) · [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) · [ipregion](https://github.com/Davoyan/ipregion) · [bbolt](https://github.com/etcd-io/bbolt). Independent project; not officially affiliated with Psiphon.
