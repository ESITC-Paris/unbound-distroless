# Usage guide

Everything beyond the [quick start](../README.md): run recipes, Kubernetes,
advanced configuration, tuning, and troubleshooting.

## Docker run recipes

**LAN / homelab resolver** (answers RFC 1918, loopback, and IPv6
ULA/link-local clients; refuses everything else by default):

```bash
docker run -d --name unbound --restart unless-stopped \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  -p 53:53/udp -p 53:53/tcp \
  -v unbound-data:/var/lib/unbound \
  esitcparis/unbound-distroless:latest
```

**Localhost-only** (a resolver for the host itself):

```bash
docker run -d --name unbound --restart unless-stopped \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  -p 127.0.0.1:53:53/udp -p 127.0.0.1:53:53/tcp \
  -v unbound-data:/var/lib/unbound \
  esitcparis/unbound-distroless:latest
```

**Read-only root filesystem** (maximum hardening — the two writable paths get
a tmpfs and a volume):

```bash
docker run -d --name unbound --restart unless-stopped \
  --read-only \
  --tmpfs /run/unbound:uid=65532,gid=65532 \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  -p 53:53/udp -p 53:53/tcp \
  -v unbound-data:/var/lib/unbound \
  esitcparis/unbound-distroless:latest
```

## Kubernetes

```yaml
containers:
  - name: unbound
    image: esitcparis/unbound-distroless:latest
    ports:
      - containerPort: 53
        protocol: UDP
      - containerPort: 53
        protocol: TCP
    securityContext:
      runAsUser: 65532
      runAsGroup: 65532
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
    readinessProbe:
      exec:
        command: ["/usr/local/sbin/unbound-control", "-c", "/etc/unbound/unbound.conf", "status"]
      periodSeconds: 30
    livenessProbe:
      tcpSocket:
        port: 53
      periodSeconds: 30
    volumeMounts:
      - name: unbound-data
        mountPath: /var/lib/unbound
volumes:
  - name: unbound-data
    persistentVolumeClaim:
      claimName: unbound-data
```

## Configuration reference

The shipped [`unbound.conf`](../unbound.conf) is fully annotated and contains
commented, copy-ready examples for all of the following — open it first:

- **Internal zones** — `local-zone`/`local-data` for static names, or a
  `stub-zone` to delegate to an existing DNS server (AD, Pi-hole)
- **Forwarding over DoT** — send all queries to Quad9/Cloudflare TLS-encrypted
  instead of full recursion
- **Serving DoT (:853) and DoH (:443)** to your clients — mount your TLS
  certificate and publish the port; the image is built with libnghttp2
- **Shared cache with Valkey/Redis** — `cachedb` for multi-replica
  deployments: one cache miss warms the whole fleet

Paths that must not change (they match the image layout):

| Path | Purpose |
|---|---|
| `/etc/unbound/root.hints` | Root server hints (baked at build) |
| `/var/lib/unbound/root.key` | DNSSEC trust anchor (auto-updated; volume) |
| `/var/lib/unbound/root.zone` | Hyperlocal root zone copy (auto-updated; volume) |
| `/run/unbound/unbound.ctl` | Control socket (used by the healthcheck) |
| `/run/unbound/unbound.pid` | PID file |

Always validate a config before deploying it:

```bash
docker run --rm -v "$PWD/unbound.conf:/etc/unbound/unbound.conf:ro" \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:latest /etc/unbound/unbound.conf
```

## Tuning for larger deployments

Defaults are safe for small hosts; scale these in a custom config:

| Setting | Default | Guidance |
|---|---|---|
| `num-threads` | 2 | Set to the number of CPU cores |
| `*-slabs` | 4 | Nearest power of two ≥ num-threads |
| `msg-cache-size` | 64m | Scale with RAM; rrset should be ~2× msg |
| `rrset-cache-size` | 128m | e.g. 1g on an 8 GB dedicated host |
| `so-rcvbuf` / `so-sndbuf` | 4m | Needs host `net.core.rmem_max` / `wmem_max` raised |

Raise the container's `nofile` ulimit for high-traffic use
(`--ulimit nofile=65535:65535`), or Unbound will log that it reduced its
outgoing port pool.

## Health checks and statistics

The image ships a Docker `HEALTHCHECK` (`unbound-control status` over the
local Unix socket) — `docker ps` shows `healthy` when the daemon answers.
Kubernetes probes: see the manifest above. DNS-level check from outside:
`dig @<ip> +time=2 . SOA`.

Runtime statistics (cache hit rate, query types, response codes):

```bash
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf stats_noreset
```

Confirm the hyperlocal root zone is live:

```bash
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf list_auth_zones
```

## Troubleshooting

- **`so-rcvbuf ... was not granted` at startup** — harmless warning:
  `net.core.rmem_max`/`wmem_max` are not namespaced in containers. Raise them
  on the host or ignore.
- **Low `nofile` ulimit** — Unbound logs that it reduced outgoing
  ports/queries; raise the container ulimit for high traffic.
- **IPv6 `network unreachable` retries** — Docker's default bridge has no
  IPv6; set `do-ip6: no` in a custom config to silence them.
- **Specific domains SERVFAIL** — try `use-caps-for-id: no` first (DNS 0x20
  hardening trips some non-compliant authoritative servers).
- **Access control behind Docker's userland proxy** — with `-p 53:53` on all
  interfaces, client source IPs can be rewritten to the bridge gateway (which
  the default ACL allows). Bind `127.0.0.1:53:53` or a specific LAN IP for
  host-level scoping.
- **First queries slow/SERVFAIL right after start** — a cold resolver is
  still priming; give it a few seconds (the healthcheck turning `healthy` is
  the ready signal).

## Building and testing locally

```bash
. ./versions.env
docker build \
  --build-arg UNBOUND_VERSION="$UNBOUND_VERSION" \
  --build-arg UNBOUND_SHA256="$UNBOUND_SHA256" \
  -t unbound-distroless:test .
bash tests/structure.sh && bash tests/functional.sh
```

The same two test scripts are the pipeline's publish gate — what you run
locally is what CI enforces.
