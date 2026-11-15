# Security notes — 4.3.1

## Fixed artifact references

The installer contains the exact references below. It does not resolve `latest` or `master` during installation. Legacy `swarupsengupta2007/psiphon:latest` is recognized only as a migration source; the new runner rejects an env file that selects an unpinned image.

| Artifact | Fixed reference |
| --- | --- |
| Psiphon container, OCI multiarch index | `swarupsengupta2007/psiphon@sha256:ed678abc7145e0fb550eb889a5dfed74bd8495bca16b958d6b7ac582d869bfe6` |
| Debian base for console backend | `debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc` |
| Official ConsoleClient repository commit | `c49818e8b2fe7b64657aea27b53f12d1374d21eb` |
| Official binary path | `linux/psiphon-tunnel-core-x86_64` |
| ConsoleClient SHA-256 | `faf6873ddc1dab6c00e11a090a711fb3a26cfa7dbc1717e0c3b1978dfff4c105` |

Maintainer reference collection: 2026-11-15. Docker registry manifests were retrieved and their digest headers compared with locally computed SHA-256. The 10,512,292-byte official binary was fetched from the fixed commit and hashed. Docker itself verifies content against the selected digest during pull. ConsoleClient is staged privately, hashed **before chmod/build/use**, and rejected on mismatch. The Docker build context excludes all files except Dockerfile and the verified ConsoleClient, so private datastore/configuration files are not sent into the build. The console backend rebuilds during upgrades, so an existing unverified binary is not silently retained. Updating pins requires a reviewed installer release; a new upstream tag does not silently replace an installation's binary.

A digest guarantees content identity; it is not an independent malware audit, provenance signature or guarantee that the selected third-party artifact is trustworthy. The default image is still a third-party build. The console backend's CA packages use signed Debian APT repositories; package versions are not a fully reproducible snapshot. Exporter module downloads force the Go checksum service and a versioned bbolt dependency; Go 1.21+ can select a newer checksum-verified toolchain when the dependency requires it. Older Go is refused before stopping services instead of silently replacing an existing installation. The optional curl-impersonate release retains its existing SHA-256 verification. See [Go toolchain verification](https://go.dev/doc/toolchain).

Primary sources: [upstream container source](https://github.com/swarupsengupta2007/psiphon-docker), [official binary at the pinned commit](https://github.com/Psiphon-Labs/psiphon-tunnel-core-binaries/tree/c49818e8b2fe7b64657aea27b53f12d1374d21eb), [Docker content digests](https://docs.docker.com/reference/cli/docker/image/pull/#pull-an-image-by-digest-immutable-identifier).

## Privilege boundary

Psiphon runs in Docker as numeric UID/GID `1000:1000`, with all Linux capabilities dropped, a read-only root filesystem, a limited writable `/tmp`, a PID limit and `no-new-privileges`. The writable `/config` datastore is owned by that UID. The default runner invokes the pinned Psiphon executable directly, bypassing the image's root user-creation/chown startup script. Bootstrap template extraction has no network, a read-only root and no capabilities. Existing recognized console containers are recreated with the same protections while retaining their datastore and settings.

Installer and host controller still run as root because they install packages, manage systemd and Docker, maintain private configuration, and export the stopped datastore. Adding an unprivileged account to the Docker group would retain root-equivalent Docker authority and is not used as a false isolation claim. The controller has a constrained systemd environment: read-only system filesystem except its instance data/config and the env-file directory needed for atomic replacement; protected home/kernel/cgroups; private devices/tmp; namespace restrictions; a limited capability set; and private umask. The application code is not in its writable paths.

These restrictions reduce exposure but **do not make Docker API access safe against a fully compromised controller**. Docker daemon access remains a root-equivalent boundary. No container is privileged and no Docker socket is mounted inside Psiphon. See [systemd execution sandboxing](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html).

## Proxies and state

Default SOCKS5 and HTTP publication remains `127.0.0.1`. YouTube mode requires loopback and one tunnel. Ordinary modes retain the user's explicit private `--bind` option; its unauthenticated proxy must be treated as accessible to hosts that can reach that address. Public binding is still rejected. The script does not silently enable LAN binding or change a working Gemini instance when configuring a separate YouTube instance.

GeoIP and connectivity checks use the instance's explicit SOCKS5h proxy with remote DNS and no direct fallback. An unavailable classifier is UNKNOWN, never proof of RU. Cached server entries contain connection credentials and stay mode 0600 in private directories. Keep backups on a trusted host and avoid publishing raw Psiphon Docker logs or server-entry files: upstream notices may contain service connection metadata. Controller-only logs are preferred for sharing diagnostics.

YouTube and Gemini have separate ports, settings, files, locks and services. A saved verification is invalidated for status reporting after an OS/container restart or stale interval. Domain routing exports do not modify Xray automatically and do not claim that ads were tested.

## Confirmed menu updates

Menu item 5 and `psiphon-autopin update` resolve the project's own main branch to one GitHub commit, retrieve the installer file by that immutable ref, validate the Git blob SHA-1 against GitHub metadata and check Bash syntax before asking to execute it. The displayed SHA-256 is a locally computed audit identifier, not an independent publisher signature. Downloads are size-limited, staged mode 0600 in a private temporary directory, and redirects outside this repository's GitHub API path are refused. No arbitrary update URL is accepted. Older versions are refused, including when another instance has a newer UI.

This trusts the Forcus356 repository account, GitHub and HTTPS; it does not protect against a malicious authorized maintainer or a compromised repository account. It is distinct from the permanently pinned third-party image/binary references. Applying an update executes the reviewed installer as root and can restart the selected instance. The installer retains saved policy values when only --instance is supplied. Successful source metadata is saved privately in update-source.json; installer failures are reported without falsely claiming a completed update. Existing installer migration backups remain on the VPS.
