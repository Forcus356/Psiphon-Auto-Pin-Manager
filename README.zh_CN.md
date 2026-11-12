<div align="center">

# 🛡️ Forcus Psiphon Auto-Pin Manager

**Psiphon 服务器自动轮换与 Google 出口 IP 固定**

![Version](https://img.shields.io/badge/version-3.3-blue) ![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-informational) [![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

[English](README.md) | [Русский](README.ru_RU.md) | [فارسی](README.fa_IR.md) | [العربية](README.ar_EG.md) | [中文](README.zh_CN.md) | [Español](README.es_ES.md) | [Türkçe](README.tr_TR.md)

</div>

适用于 Linux 的管理工具：逐一选择 Psiphon 服务器，通过本地 **SOCKS5h** 检测出口 IP 和 Google 所识别的国家，固定符合条件的出口。如果 Google 将出口识别为 RU，则重新搜索。

## ✨ 主要功能

- 使用 `TargetServerEntry` 逐个选择 Psiphon 服务器
- 只读访问 BoltDB 服务器数据库
- 通过 SOCKS5h 检测出口 IP 与 Google 国家；不回退到直连
- 验证固定出口、定期监控与自动切换
- 可配置国家、端口和检查间隔
- 兼容已安装的 Docker CE 与 `docker.io`

## 📋 运行要求

Ubuntu 或 Debian **x86_64**、root 权限、systemd 和互联网连接。请确认托管服务商允许 VPN/代理。

## 🚀 快速开始

交互式选择国家和端口：

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash
```

### 无人值守安装示例

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region PL --port 40000
```

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh | sudo bash -s -- --region DE --port 41000 --interval 1800 --wait 90 --delay 15
```

## ⚙️ 安装参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--region DE` | Prompt; `[DE]` | Psiphon 服务器国家代码（两个字母），或 `AUTO`。 |
| `--port 40000` | Prompt; `40000` | 本地 SOCKS5 端口 1024–65534；HTTP 使用下一端口。 |
| `--interval 3600` | `3600` | 监控间隔（秒），最少 60。 |
| `--wait 75` | `75` | 连接等待时间（秒），最少 20。 |
| `--delay 12` | `12` | 尝试间隔（秒），最少 2。 |
| `--help` | — | 显示帮助。 |

## 🧰 管理器命令

| Command | Description |
|---|---|
| `status` | 查看已保存的固定出口状态 |
| `check` | 通过 SOCKS5h 检查 IP 与 Google；退出码 0=非 RU，2=RU |
| `search` | 搜索服务器；需先停止监控服务 |
| `monitor` | 持续监控；通常由 systemd 启动 |

```bash
python3 /opt/psiphon-autopin/psiphon_autopin.py status
python3 /opt/psiphon-autopin/psiphon_autopin.py check
```

`--region`, `--port`, `--interval`, `--wait`, `--delay` — 说明.

## 🛠️ 服务管理与诊断

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

## 📌 使用示例

```bash
# Exit IP through Psiphon
curl -4 -fsS --noproxy '' \
  --proxy socks5h://127.0.0.1:40000 https://api.ipify.org

# Manual search; monitor must not be running
systemctl stop psiphon-autopin
python3 /opt/psiphon-autopin/psiphon_autopin.py search --region PL --port 40000
systemctl start psiphon-autopin
```

## 🔄 工作原理

管理器以只读方式读取 Psiphon BoltDB 服务器列表，通过 `TargetServerEntry` 指定服务器，再经 SOCKS5h 检查出口 IP 和 Google 国家。两次验证通过后保存固定连接。

## ⚠️ 注意事项

`--region PL` 不保证 `Google=PL`；当前通过标准是 `Google != RU`。入口服务器 IP 与出口 IP 可能不同。切换服务器会中断现有连接。

SOCKS5 和 HTTP 只监听 `127.0.0.1`，HTTP 端口为 SOCKS 端口加 1。安装依赖时可能使用 VPS 直连。以 root 运行前请审查脚本。

## 🩺 故障排查

| Error | Solution |
|---|---|
| `containerd.io : Conflicts: containerd` | Docker CE 与 docker.io 包冲突；请勿直接卸载现有 Docker。 |
| `Config exists but container missing` | 先备份旧配置并确认它由哪个服务使用。 |
| `SOCKS/HTTP port ... occupied` | 使用 `ss -lntp` 检查并更换 `--port`。 |
| `No known servers in region` | 查看 Docker 日志；服务器库可能还未填充。 |
| `Another search/monitor is running` | 运行 `search` 前停止监控服务。 |

## 📂 安装路径

```text
/opt/vps-psiphon/config/psiphon.config
/opt/psiphon-autopin/psiphon_autopin.py
/opt/psiphon-autopin/psiphon-server-export
/opt/psiphon-autopin/ipregion.sh
/var/lib/psiphon-autopin/settings.json
/var/lib/psiphon-autopin/state.json
/etc/systemd/system/psiphon-autopin.service
```

## 📄 许可证与致谢

[GPL-3.0](LICENSE) · [Forcus356](https://github.com/Forcus356) · [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core) · [ipregion](https://github.com/Davoyan/ipregion) · [bbolt](https://github.com/etcd-io/bbolt). Independent project; not officially affiliated with Psiphon.
