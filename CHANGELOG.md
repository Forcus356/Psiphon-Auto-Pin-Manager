# Changelog

## 4.3.2 — 2026-11-15

- Fix Gemini CAPTCHA detection with the default curl probe: a Google `/sorry/` redirect is classified as CAPTCHA before session-field parsing, even without the optional browser TLS profile. Previously it became INCONCLUSIVE and could keep a challenged exit pinned.
- Preserve existing confirmed-CAPTCHA rotation, browser-profile checks and genuinely inconclusive response policy. Add regressions for default/profile CAPTCHA, unknown pages, ordinary redirects, fetch failures, valid model replies, rejected adoption and confirmed monitor rotation.
- Reproduced on the test VPS using the old installed probe and the corrected probe in memory through the same SOCKS5h; no installed files or services were changed by that comparison.

## 4.3.1 — 2026-11-15

- Top-level Templates with three presets: Gemini + YouTube, Gemini only, YouTube only. Clean interactive installs open templates on Enter.
- One reviewed plan and common confirmation installs two independent instances sequentially; both monitors then run concurrently. Regions, ports, watchdog, output format and YouTube speed are editable before installation.
- Allocate unused instance IDs and SOCKS/HTTP pairs; preserve existing instances. Recheck ports at confirmation and refuse to overwrite an instance created concurrently. Report partial installation accurately, retaining successful instances.
- Explicit numeric boolean prompts (1 on / 0 off / Enter keep), validated confirmation prompts and simpler YouTube help.
- Initial installer and installed menu use the same child-install flow, return to the main menu, and show a role/port overview for multiple instances. CLI settings remain unchanged.
- Documented templates in all seven READMEs and added isolated installer/PTY regression tests.

## 4.3.0 — 2026-11-15

- Interactive installation/apply returns to the selected instance status menu, with explicit pending verification, refresh action and no nested installer lock. Updates reopen the newly installed UI.
- Confirmed GitHub updates from main-menu item 5 and the update CLI, with immutable commit/blob verification, syntax checks, downgrade refusal and per-instance settings retention. Mixed-version installations use the newest UI and its installer.
- New YouTube instances use a 1500 KiB/s video floor with the existing 4 MiB sample; saved and explicit thresholds are preserved. Easy adds video speed editing when YouTube is on.
- Optional per-instance YouTube Mode in Easy (item 6), Advanced and installer CLI. Old settings default to off; explicit mode switches preserve ordinary deny/strict policy values.
- Mandatory Google GeoIP RU through the selected SOCKS5h, including adoption, first PIN, rechecks and monitoring. Unknown classifications retry without accepting a candidate. Rejected/duplicate candidates now respect the search delay.
- Independent YouTube/Gemini setup with an explicit menu choice, free instance/port selection and installer reservation checks against stopped instances. No silent changes to another instance.
- YouTube observation states, diagnostic ID, speed, last successful RU check and restart/staleness invalidation. No advertisement verification claim.
- `xray-routing` export for two configured instances, narrow service domain rules, inbound sniffing guidance and scoped QUIC blocking. Xray is never modified automatically.
- Fixed Docker image/base digests and official ConsoleClient commit/SHA-256, including upgrades. Fail closed on binary mismatch.
- Nonroot, capability-free, read-only Psiphon containers and constrained systemd host services. Explicit private binding remains available for ordinary modes; the host Docker controller remains privileged.
- Updated all seven READMEs, Xray examples, security notes and offline regression coverage.

## 4.2.0

Automatic cache creation and first verified PIN; dependency-aware uninstall preserving preexisting Docker/Go and dependencies used by other instances or containers.
