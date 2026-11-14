<div align="center">

<img src="docs/assets/banner.svg" alt="Forcus Auto-Pin — Psiphon Manager" width="100%">

# Forcus Auto-Pin

**本地 SOCKS5 · 自动固定服务器 · Google/Gemini 检查 · 自动恢复**

![Version](https://img.shields.io/badge/version-4.2.0-32b98b?style=flat-square)
![Platform](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-x86__64-2496ed?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

[English](README.md) · [فارسی](README.fa_IR.md) · [العربية](README.ar_EG.md) · **中文** · [Español](README.es_ES.md) · [Русский](README.ru_RU.md) · [Türkçe](README.tr_TR.md)

</div>

面向 Linux VPS 的 Psiphon 管理器。安装后选择 Easy 或 Advanced，在控制台管理独立代理实例。Xray 可通过生成的 outbound JSON 使用同一个 SOCKS5 端点。

[快速开始](#quick-start) · [功能](#features) · [控制台菜单](#menu) · [命令参考](#commands) · [Xray 集成](#xray) · [更新与维护](#operations) · [卸载](#uninstall) · [常见问题](#faq)

<a id="quick-start"></a>

## 快速开始

请在 Bash 中以 root 身份运行。支持使用 systemd 的 Ubuntu/Debian x86_64，需要网络连接和 curl。安装器会补装缺少的 Docker/Go，并保留已有安装。

下载并运行安装器。在终端中不带参数运行时，会打开设置菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh -o /tmp/install_psiphon_autopin.sh && bash /tmp/install_psiphon_autopin.sh
```

安装后可随时重新打开菜单：

```bash
auto-pin
```

**SOCKS5:** `127.0.0.1:40000` → `1080`  ·  **HTTP:** `127.0.0.1:40001` → `8080`

文档提供七种语言。控制台菜单目前使用俄语；各语言文档中的命令和参数完全相同。

<a id="features"></a>

## 功能

- 首次自动 PIN：创建缓存，重连所选服务器，验证成功后才标记为已固定。
- 单隧道支持已验证的服务器 PIN；2–32 条隧道组成池并进行抽样检查。
- 最多 99 个独立实例，各自拥有端口、文件、数据库、锁和服务。
- 国家池、Google 国家拒绝列表，以及可选的严格地区匹配。
- 可选 Gemini 可用性检查及用于识别 CAPTCHA 的浏览器 TLS 配置。
- 连续测量确认速度阈值，自动恢复异常连接。
- 本地 SOCKS5、可选 HTTP、私有 IPv4 绑定及 Xray outbound JSON。
- 卸载时保留预先安装或仍被其他应用使用的 Docker/Go。

<a id="menu"></a>

## 控制台菜单

**Easy：**地区、连接输出格式、Gemini、SOCKS 端口及以分钟计的 watchdog。**Advanced：**所有安装参数。主菜单第 3、4 项分别用于维护和选择实例。

Enter 保留当前值；`-` 清空国家列表。输入拉丁字母 `y` 查看设置，再通过 `y/n` 确认应用。取消保留原配置；应用可能重新连接所选隧道。Easy 会保留隐藏的 Advanced 设置。

页脚显示已保存的监控结果，打开菜单不会进行新的网络检查，请使用 `check`。`NO_COLOR=1 auto-pin` 禁用颜色；`TERM=dumb auto-pin` 使用 ASCII 边框。

<details>
<summary>菜单预览</summary>

由当前菜单渲染器生成的示例；图中的地址和状态均为演示数据。

![菜单预览](docs/assets/menu-preview.png)

[菜单预览 (.txt)](docs/assets/menu-demo.txt)

</details>

<a id="examples"></a>

## 安装示例

每个示例都会下载并以非交互方式运行安装器。显式参数覆盖已保存的值；更新时保留未指定的设置。

<details>
<summary>安装示例</summary>

### 不检查 Gemini

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --no-gemini-check
```

### 国家池与最低速度

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL,DE,PL --min-speed 1000
```

### 第二个独立实例

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --instance 2 --region DE --port 40002
```

### 只提供 SOCKS5

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --no-http
```

### 生成 Xray 连接文件

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --connection xray
```

### 三条隧道与 10 分钟 watchdog

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --tunnel-pool 3 --interval 600
```

### 使用浏览器 TLS 配置检查 Gemini

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh) --region NL --gemini-check --impersonate
```

</details>

<a id="commands"></a>

## 命令参考

| 命令 | 用途 |
| --- | --- |
| `auto-pin` | 打开设置和维护菜单。 |
| `auto-pin --instance 2` | 打开实例 2 的菜单。 |
| `psiphon-autopin status` | 显示已保存配置和最近结果。 |
| `psiphon-autopin check` | 重新检查连接及策略。 |
| `psiphon-autopin rotate` | 请求轮换服务器。 |
| `psiphon-autopin region NL` | 切换到 NL 并清空旧国家池。 |
| `psiphon-autopin pool NL,DE,PL` | 设置候选国家池。 |
| `psiphon-autopin pool ''` | 清空国家池。 |
| `psiphon-autopin speed` | 测量 Psiphon 吞吐量。 |
| `psiphon-autopin logs 100` | 显示监控器和隧道的近期日志。 |
| `psiphon-autopin start` | 启动所选实例。 |
| `psiphon-autopin stop` | 停止所选实例。 |
| `psiphon-autopin restart` | 重启所选实例。 |
| `psiphon-autopin xray` | 输出 Xray SOCKS outbound JSON。 |
| `psiphon-autopin-2 status` | 显示实例 2 的状态。 |
| `psiphon-autopin menu` | 通过原 CLI 打开菜单。 |
| `vps-psiphon status` | 同一管理器的兼容别名。 |
| `psiphon-autopin refresh-cache --allow-interruption` | 刷新数据库缓存；会中断隧道。 |
| `psiphon-autopin prepare-pin` | 准备在后续重启时使用的 PIN。 |
| `psiphon-autopin search` | 搜索合适的服务器。 |
| `psiphon-autopin monitor` | 内部监控入口，通常由 systemd 启动。 |

`set-region --region NL` 和 `set-pool --region-pool NL,DE` 分别是 `region NL` 和 `pool NL,DE` 的完整形式。运行参数可覆盖单次命令的策略；请使用菜单或安装器持久保存完整服务配置。

```bash
psiphon-autopin set-region --region NL
psiphon-autopin set-pool --region-pool NL,DE
```

`check` 退出码：**0** 结果被接受，**2** 策略拒绝（包括低速），**1** 探测或运行错误。被接受的结果仍可能包含 Gemini `INCONCLUSIVE`。

<a id="xray"></a>

## Xray 集成

连接路径为 **Xray → SOCKS5 → Psiphon → Internet**。xray 输出 outbound；--connection xray 还会保存 xray-outbound.json。请自行将 outbound 和路由加入 Xray 配置。这里使用的是同一个 SOCKS5 端点，没有额外传输协议。

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

Xray 位于 Docker bridge 网络时，127.0.0.1 指向 Xray 容器自身。请使用 host 网络，或通过 --bind 绑定 VPS 已有的私有 IPv4。不允许绑定公网地址。此代理用于 TCP。

<a id="options"></a>

## 安装参数

菜单中的 watchdog 使用分钟；CLI --interval 和 JSON interval 始终使用秒。示例中的地区和端口可按需替换。

全新安装选择 `auto` 时使用 `vps-psiphon`，可识别的现有后端会保留。`console` 必须绑定 loopback。`--no-gemini-check` 仍保留国家、速度和恢复检查。

<details>
<summary>安装参数</summary>

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `--region NL / --region AUTO / --region NL,DE` | 菜单选择／无人值守安装必填 (NL) | 两字母 Psiphon 国家码、AUTO 或逗号分隔的国家池。 |
| `--instance N` | 1 | 选择实例 1–99。 |
| `--port N` | 40000 + 2 × (N−1) | SOCKS 端口 1024–65534；HTTP 使用下一端口。 |
| `--connection socks5\|xray` | socks5 | 保存 SOCKS5 地址或 Xray JSON 输出。 |
| `--menu / --interactive` | TTY / 0 args | 显式打开向导，可加 --instance N。 |
| `--menu-mode easy\|advanced` | easy | 记住 Easy 或 Advanced 模式。 |
| `--region-pool NL,DE` | 空 | 候选国家列表。 |
| `--bind ADDR` | 127.0.0.1 | 绑定 loopback 或已有私有 IPv4。 |
| `--bind-loopback` | 127.0.0.1 | 恢复绑定至 127.0.0.1。 |
| `--http / --no-http` | 启用 | 启用／禁用 HTTP 端口。 |
| `--gemini-check / --no-gemini-check` | 启用 | 启用／禁用 Gemini 检查。 |
| `--impersonate / --no-impersonate` | 禁用 | 启用／禁用 Gemini 页面检查的浏览器 TLS 配置。 |
| `--strict-region / --no-strict-region` | 禁用 | 启用／禁用 Google 国家严格匹配。 |
| `--interval N` | 300 s | 正常检查间隔，单位秒，最少 60。 |
| `--wait N` | 75 s | 等待连接就绪，单位秒，最少 20。 |
| `--delay N` | 12 s | 搜索尝试间隔，单位秒，最少 2。 |
| `--min-speed N` | 800 KiB/s | 速度下限，KiB/s；0 禁用速度轮换。 |
| `--probe-mb N` | 4 MiB | 采样量 0–10 MiB；设为 0 且阈值启用时仍测量页面。 |
| `--slow-threshold N` | 2 | 轮换前连续低速样本数，2–20。 |
| `--fail-threshold N` | 3 | 恢复前连续失败次数，2–20。 |
| `--deny-regions 'RU BY IR SY CU KP CN VE'` | RU BY IR SY CU KP CN VE | 拒绝的 Google 国家；空字符串清空列表。 |
| `--tunnel-pool N` | 1 | 1 使用 PIN；2–32 使用没有单一固定 PIN 的池。 |
| `--backend auto\|console\|vps-psiphon` | auto | 保留／检测现有后端，或显式选择。 |
| `--help` | — | 显示安装器帮助。 |

</details>

<a id="operations"></a>

## 更新与维护

### 更新现有实例

再次下载最新安装器并应用到该实例。未明确覆盖的设置会保留。仅打开 auto-pin 不会下载新版本。

```bash
curl -fsSL https://raw.githubusercontent.com/Forcus356/Psiphon-Auto-Pin-Manager/main/install_psiphon_autopin.sh -o /tmp/install_psiphon_autopin.sh && bash /tmp/install_psiphon_autopin.sh --instance 1
```

### 诊断

查看状态、跟踪监控器日志，并测试已配置的两个代理：

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

连接、IP、国家、Gemini 和速度检查均使用带远程 DNS 的 SOCKS，不回退到直连。安装器下载可能使用 VPS 自身网络。不会自动移除 WARP。

### 独立实例

使用 psiphon-autopin-N 或 auto-pin --instance N。默认主机端口如下，可用 --port 修改。99 个实例和 32 条隧道是配置上限，不代表 VPS 的实际承载能力。

| # | SOCKS5 | HTTP | CLI |
| --- | --- | --- | --- |
| 1 | `40000` | `40001` | `psiphon-autopin` |
| 2 | `40002` | `40003` | `psiphon-autopin-2` |
| 3 | `40004` | `40005` | `psiphon-autopin-3` |

### Watchdog 与流量

Easy 第 5 项与 Advanced 可设置内置监控器的分钟间隔：最少 1，默认 5。支持能换算为整数秒的 1.5 等小数。故障重试可能更频繁。不会另外运行 Chara watchdog。

默认策略：启用 Gemini、单隧道、800 KiB/s、连续两次低速、4 MiB 采样、三次失败后恢复。每五分钟采样 4 MiB，30 天约消耗 34 GiB，尚不包括搜索流量。--min-speed 0 禁用速度轮换；仅 --probe-mb 0 仍可能测量页面。

<a id="uninstall"></a>

## 卸载

移除所选实例，保留 Docker/Go：

```bash
psiphon-autopin uninstall
```

移除实例及由本管理器安装且可安全移除的 Docker/Go 软件包：

```bash
psiphon-autopin uninstall --purge-deps
```

```bash
psiphon-autopin-2 uninstall --purge-deps
```

4.2 起按组件记录安装来源。预先安装或来源不明的软件包会保留。其他 Auto-Pin 实例会保留共享依赖；其他运行中或已停止的容器、或无法确定的 Docker 使用情况会保留 Docker。APT 模拟检查会阻止移除无关软件包。

没有来源记录的旧安装会保留依赖。不会执行 autoremove 或任意删除 Docker 数据。Python、curl、GCC 和迁移备份会保留。菜单第 13、14 项提供两种卸载模式。

普通卸载移除最后一个实例后会放弃来源记录并保留依赖。如需移除符合条件的自有依赖，请在卸载时选择 `--purge-deps`。

APT 清理失败时会报错并保留来源记录。修复 APT 后，在下载的项目目录中重试：

```bash
python3 autopin_system.py cleanup --purge
```

<a id="faq"></a>

## 常见问题

<details>
<summary>如何确认 PIN 已验证？</summary>

查看 INITIAL PIN VERIFIED 和 adopted_unpinned: false。pin_prepared: true 仅表示已准备，尚未验证。首次 PIN 会受控重连；验证失败时回滚，并在后续健康检查中重试。

</details>

<details>
<summary>INCONCLUSIVE 表示 Gemini 可用吗？</summary>

未确认模型回复。SERVING 表示匿名探测成功；INCONCLUSIVE 表示未确定，单独出现不会触发轮换。当前策略允许在 Gemini 未确定时验证服务器 PIN。不会检查你的浏览器登录账号。

</details>

<details>
<summary>为什么 ip 和 server_ip 不同？</summary>

ip 是公共代理出口，server_ip 是 Psiphon 服务器地址。固定同一服务器后，重连也可能更换公共出口，因此不保证 IP 不变。

</details>

<details>
<summary>为什么 y 有时要求重输？</summary>

错误的 UTF-8 输入会被拒绝，以避免应用损坏数据或退出菜单。请重新输入拉丁字母 y，再用 y/n 确认。

</details>

<details>
<summary>为什么 Google 显示不同国家？</summary>

EgressRegion 是向 Psiphon 请求的地区，Google 可能采用其他分类。拒绝列表和 strict-region 决定是否接受。无法保证特定国家或服务访问。

</details>

<a id="files"></a>

## 文件与配置

以下为实例 1 的路径。其他实例的应用、数据和配置目录带 -N 后缀；来源记录和备份目录为共享目录。连接及服务器条目文件包含私有配置数据。

| 路径 | 用途 |
| --- | --- |
| `/var/lib/psiphon-autopin/settings.json` | 生效设置和菜单偏好。 |
| `/var/lib/psiphon-autopin/state.json` | 最近监控结果和 PIN 状态。 |
| `/opt/vps-psiphon/config/psiphon.config` | 私有 Psiphon 配置和目标服务器条目。 |
| `/var/lib/psiphon-autopin/server-entry-cache.json` | 私有服务器条目缓存。 |
| `/var/lib/psiphon-autopin/connection.json` | 所选连接输出。 |
| `/var/lib/psiphon-autopin/xray-outbound.json` | 选择该格式时生成的 Xray outbound。 |
| `/var/lib/psiphon-autopin-system/dependencies.json` | Docker/Go 来源记录，权限 0600。 |
| `/var/backups/psiphon-autopin` | 迁移和恢复备份。 |

<a id="development"></a>

## 开发与致谢

在本地项目副本中执行：

```bash
python3 -m unittest discover -s tests -v
bash -n install_psiphon_autopin.sh
```

[CHANGELOG](CHANGELOG.md) · [tests](tests)

使用的组件: [Psiphon Tunnel Core](https://github.com/Psiphon-Labs/psiphon-tunnel-core), [psiphon-docker](https://github.com/swarupsengupta2007/psiphon-docker), [bbolt](https://github.com/etcd-io/bbolt), [curl-impersonate](https://github.com/lexiforest/curl-impersonate).

许可证：[GPL-3.0](LICENSE)。参考研究了 [Chara vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon) 的运维思路，其安装器和 watchdog 不属于本项目运行时。README 结构参考了 [3x-ui](https://github.com/MHSanaei/3x-ui)。
