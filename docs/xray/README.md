# YouTube + Gemini routing (Xray)

This is an explicit export, not an installer for Xray or 3x-ui. It reads the two saved Auto-Pin instance settings and never modifies your panel, inbounds, outbounds or routes.

```bash
psiphon-autopin xray-routing --youtube-instance 2 --gemini-instance 1
```

The YouTube instance must enable `youtube_mode`, disable `gemini_check`, use one tunnel and bind to loopback. The Gemini instance must enable `gemini_check` and disable YouTube mode. The exporter refuses the same instance twice and overlapping SOCKS/HTTP ports. It exports the configured ports, not fixed example values.

[Example fragment](youtube-gemini.fragment.json): YouTube instance 2 uses 40002; Gemini instance 1 uses 40000. With other assignments, use the command rather than editing a working configuration blindly.

1. Back up the Xray configuration using your usual panel workflow.
2. Append the exported `outbounds` to the existing array **after the current default outbound**. Preserve your existing direct/block outbounds and routing. The example alone is not a complete Xray configuration; its first outbound must not accidentally become the default for unrelated traffic.
3. Place the three exported domain rules before broad matching rules. Review their order against existing routing. `domain:youtube.com` matches the domain and its subdomains; `full:youtubei.googleapis.com` matches the exact API host. The rules do not capture all of `google.com` or `googleapis.com`.
4. Ensure Xray knows the requested domain: send domain destinations in the inbound protocol, or enable the [sniffing fragment](inbound-sniffing.fragment.json) **inside the actual traffic-receiving inbound**. Do not add it as a separate fake inbound. `routeOnly: true` allows sniffed names to guide routing while retaining the original connection destination. An IP-only connection with no visible hostname, or a hidden name such as ECH, cannot be reliably assigned to a domain rule.
5. Psiphon SOCKS is used for TCP. The first rule blocks UDP/443 only for the listed service domains, so a compatible client can fall back from HTTP/3/QUIC to TCP. Domain identification is still required for that UDP rule; test the real client. It is not a guarantee that every client retries or that every dependency belongs to those domains.
6. With Xray in a bridge container, `127.0.0.1` is its own container. Use host networking to reach the loopback Psiphon instances. YouTube mode intentionally requires loopback. For unrelated ordinary instances, an explicit private `--bind` remains available.
7. Validate and apply the reviewed configuration explicitly through your panel or Xray tooling. Check access logs for outbound tags `psiphon-youtube` and `psiphon-gemini`, then check each instance with `psiphon-autopin[-N] status`. Authentication and shared Google assets are left to your existing routing; extend only specific hosts when needed.

The confirmed YouTube condition is Google GeoIP RU. Neither this exporter nor sniffing checks advertisements. Gemini's existing `SERVING`, `REFUSED`, `INCONCLUSIVE` and CAPTCHA behavior is preserved.

References: [Xray routing](https://xtls.github.io/en/config/routing.html), [inbound sniffing](https://xtls.github.io/en/config/inbound.html#sniffingobject).

## По-русски

Команда экспортирует только JSON. Вставляйте outbounds после существующего outbound по умолчанию, а доменные правила — перед общими правилами. Sniffing нужно включить на реально используемом inbound: `enabled: true`, `destOverride: ["http", "tls", "quic"]`, `routeOnly: true`. Пример не является полным конфигом Xray и не применяется автоматически.

Для Docker используйте host-сеть: loopback хоста из обычного bridge-контейнера недоступен. Psiphon используется для TCP; UDP/443 выбранных доменов блокируется для возможного перехода клиента с QUIC на TCP. Без доступного имени домена корректность доменного правила не гарантируется. Проверяйте реальные access-логи Xray и отдельные статусы экземпляров.
