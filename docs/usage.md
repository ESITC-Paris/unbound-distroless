# Usage guide

Running and configuring the resolver beyond the [quick start](../README.md):
`docker run`, port 53 and capabilities, health checks, Kubernetes,
configuration, tuning, troubleshooting, building the image yourself, and
updating without the sidecar.

## `docker run`

The same hardening as the root [`docker-compose.yml`](../docker-compose.yml):

```bash
docker run -d --name unbound --restart unless-stopped \
  --read-only --tmpfs /run/unbound:uid=65532,gid=65532 \
  --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  --ulimit nofile=16384:16384 \
  -p 53:53/udp -p 53:53/tcp \
  -v unbound-data:/var/lib/unbound \
  esitcparis/unbound-distroless:1
```

The image writes in exactly two places: `/var/lib/unbound` (the volume: DNSSEC
trust anchor and root zone copy) and `/run/unbound` (control socket and PID
file, a tmpfs here). For a resolver that serves only the host itself, publish
on loopback: `-p 127.0.0.1:53:53/udp -p 127.0.0.1:53:53/tcp`.

The default configuration answers clients from `127.0.0.0/8`, `10.0.0.0/8`,
`172.16.0.0/12`, `192.168.0.0/16`, `::1`, `fd00::/8` and `fe80::/10`, and
refuses everyone else. With `-p 53:53` on all interfaces, Docker's userland
proxy can rewrite client source addresses to the bridge gateway, which that
list allows; publish on a specific address (`-p 192.0.2.10:53:53/udp …`) to
keep `access-control` meaningful.

## Port 53 and capabilities

Unbound runs as UID 65532. The binary `/usr/local/sbin/unbound` carries the
file capability `cap_net_bind_service=+ep`, which is what lets it bind port
53. [`tests/port53.sh`](../tests/port53.sh) pins the behaviour; it runs with
the functional suite in CI (amd64) and in every release (amd64 and arm64):

| Options | Result |
|---|---|
| `--cap-drop=ALL --cap-add=NET_BIND_SERVICE --security-opt no-new-privileges`, bridge network | Binds :53, even with `net.ipv4.ip_unprivileged_port_start` set back to the kernel default 1024 inside the container. The process has exactly `NET_BIND_SERVICE` (effective and permitted), no ambient capabilities, `NoNewPrivs: 1`. |
| `--cap-drop=ALL` without `--cap-add=NET_BIND_SERVICE`, with or without `no-new-privileges` | Does not start: `exec /usr/local/sbin/unbound: operation not permitted`. The kernel refuses to execute a binary whose file capability is outside the bounding set. Add `NET_BIND_SERVICE` back. |
| The first line's options with `--network host` | Binds :53 in the host's namespace. Whether the capability or the host's own `ip_unprivileged_port_start` did it depends on that host's value; the test reports which. |

These results hold for the Docker Engine the tests run on (GitHub's Ubuntu
runners; first observed on Docker Engine 29.9.3). Podman, rootless Docker,
containerd under Kubernetes and older Docker versions are not tested.

## Health checks

The image's `HEALTHCHECK` runs `unbound-control status` over the local
control socket every 30 seconds. It is a liveness check: `healthy` means the
daemon is running and answers its control channel. It does not mean the
resolver can reach the Internet, that DNSSEC validation succeeds, or that the
cache is warm — right after a start, the first queries can still SERVFAIL
while it primes (the test suites retry for that reason). This is deliberate:
restarting the container does not fix a broken upstream or an expired trust
anchor, and a resolution check would restart it in a loop during an Internet
outage.

Watch resolution and validation from outside instead:

- a query from another host: `dig @<resolver-ip> +time=2 . SOA +dnssec`
  (status `NOERROR`, `ad` in the flags);
- the statistics below, or the Prometheus rules in
  [`observability/`](observability/), described in
  [production.md](production.md).

Runtime statistics (cache hit rate, query types, response codes) and the
state of the local root zone:

```bash
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf stats_noreset
docker exec unbound /usr/local/sbin/unbound-control \
  -c /etc/unbound/unbound.conf list_auth_zones
```

## Kubernetes

Not tested by this repository: the manifest below applies the same options as
the first row of the [port 53 table](#port-53-and-capabilities), but on a
container runtime that has not been tested.

```yaml
containers:
  - name: unbound
    image: esitcparis/unbound-distroless:1    # pin X.Y.Z-rN or a digest in production
    ports:
      - containerPort: 53
        protocol: UDP
      - containerPort: 53
        protocol: TCP
    securityContext:
      runAsUser: 65532
      runAsGroup: 65532
      readOnlyRootFilesystem: true
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
        # Required: without it the binary's file capability makes exec fail
        # ("operation not permitted"), see the port 53 table.
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
      - name: unbound-run
        mountPath: /run/unbound
volumes:
  - name: unbound-data
    persistentVolumeClaim:
      claimName: unbound-data
  - name: unbound-run
    emptyDir:
      medium: Memory
```

Set `fsGroup: 65532` in the pod's `securityContext` so the volumes are
writable by the resolver.

Both probes prove the daemon is up, not that it resolves. The image has no
shell, so a probe can only run one of its binaries, and none fits:
`unbound-host` exits 0 even when the answer is `SERVFAIL`. Monitor resolution
as described in [Health checks](#health-checks).

Kubernetes does not seed a PersistentVolume from the image the way Docker
seeds an empty named volume. With an empty `/var/lib/unbound`, Unbound exits
at start with `error reading auto-trust-anchor-file:
/var/lib/unbound/root.key`. Seed the claim before the first start, for
instance with an initContainer on the same image running
`/usr/local/sbin/unbound-anchor -a /var/lib/unbound/root.key`: it exits 1
when it writes the anchor (that is its "anchor updated" code), so the init
container fails once and succeeds on the retry, which exits 0. The root zone
copy is optional: without `root.zone`, Unbound transfers the zone from the
root servers.

## Configuration

The shipped [`unbound.conf`](../unbound.conf) is annotated and has commented,
copy-ready examples for:

- internal zones: `local-zone`/`local-data`, or a `stub-zone` to an existing
  DNS server;
- forwarding everything over DNS over TLS instead of full recursion;
- serving DNS over TLS (:853) and DNS over HTTPS (:443) to clients, with your
  certificate mounted;
- a shared cache in Valkey or Redis (`cachedb`), for several replicas;
- EDNS Client Subnet towards selected authoritative servers (off by default:
  it sends client network prefixes to third parties);
- dnstap query and response logging to a collector.

Paths the configuration must keep (they match the image layout):

| Path | Purpose |
|---|---|
| `/etc/unbound/root.hints` | Root server hints, from the image |
| `/var/lib/unbound/root.key` | DNSSEC trust anchor, updated by Unbound (RFC 5011); on the volume |
| `/var/lib/unbound/root.zone` | Root zone copy, updated by Unbound (zone transfer); on the volume |
| `/run/unbound/unbound.ctl` | Control socket, used by the health check |
| `/run/unbound/unbound.pid` | PID file |

Validate a configuration with the image that will run it:

```bash
docker run --rm -v "$PWD/unbound.conf:/etc/unbound/unbound.conf:ro" \
  --entrypoint /usr/local/sbin/unbound-checkconf \
  esitcparis/unbound-distroless:1 /etc/unbound/unbound.conf
```

The file must be readable by UID 65532.

## Tuning

The defaults suit a small host. For more load, in your own configuration:

| Setting | Default | Guidance |
|---|---|---|
| `num-threads` | 2 | Number of CPU cores |
| `*-slabs` | 4 | Power of two closest to `num-threads` |
| `msg-cache-size` | 64m | Scale with memory; keep `rrset-cache-size` about twice this |
| `rrset-cache-size` | 128m | For example 1g on a dedicated 8 GB host |
| `outgoing-range` | 4096 | Per thread; the file-descriptor limit must cover `outgoing-range` × `num-threads` plus clients |
| `so-rcvbuf` / `so-sndbuf` | 4m | Granted only up to the host's `net.core.rmem_max` / `wmem_max` |

## Troubleshooting

- **`so-rcvbuf ... was not granted`** at start: `net.core.rmem_max` and
  `wmem_max` are not per-container. Raise them on the host, or ignore it.
- **Warnings about the open-files limit** at start: the limit is below what
  `outgoing-range` × `num-threads` needs; raise it
  (`--ulimit nofile=16384:16384`, or `ulimits:` in Compose).
- **IPv6 `network unreachable`** retries: the default Docker bridge has no
  IPv6; set `do-ip6: no` in your configuration.
- **A few domains SERVFAIL**: try `use-caps-for-id: no` first; DNS 0x20
  case randomisation trips some non-compliant authoritative servers.
- **The container does not start, `exec /usr/local/sbin/unbound: operation
  not permitted`**: `NET_BIND_SERVICE` was dropped, see
  [Port 53 and capabilities](#port-53-and-capabilities).
- **`address already in use` on port 53**: see the README, section
  [Run it](../README.md#run-it).

## Building the image yourself

```bash
scripts/build.sh my-unbound:local
```

[`scripts/build.sh`](../scripts/build.sh) builds with the pins CI uses: the
Unbound version and SHA-256 from `versions.env`, the base images by the
digests in `.build-state.json`, and the image revision as a build argument.
A plain `docker build .` uses the floating `debian:trixie` and
`gcr.io/distroless/base-debian13:nonroot` tags, whatever the registry serves
that day: it is not the image CI tested or published. The Debian packages
installed at build time are also whatever Debian serves that day, so two
builds of the same pins are not byte-identical. Testing a local build:
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Updating without the sidecar

The [update sidecar](../updater/README.md) needs the Docker socket. Without
it, pin the image by digest and let your own pipeline move the pin:

1. Reference the image by digest, for example in `docker-compose.yml`:
   `image: esitcparis/unbound-distroless:1@sha256:<digest>` (Docker uses the
   digest; the tag only tells your update tool what to track). Take the
   digest from the [releases page](https://github.com/ESITC-Paris/unbound-distroless/releases).
2. Let a dependency bot propose the new digest when the tag moves: Renovate
   (preset `docker:pinDigests`) or Dependabot (the `docker` and
   `docker-compose` ecosystems) open a pull request per update.
3. In that pull request's checks, verify the signature of the proposed
   digest before it is merged:

   ```bash
   cosign verify esitcparis/unbound-distroless@sha256:<digest> \
     --certificate-identity-regexp '^https://github\.com/ESITC-Paris/unbound-distroless/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com
   ```

4. Deploy the merged change (`docker compose pull && docker compose up -d`).

The resolver then changes only when you merge, only to a signed image, and
the image digest that runs is the one in your repository. What you give up
compared with the sidecar: the canary with your configuration before the
swap, and the automatic rollback. More verification commands:
[trust.md](trust.md#verifying-releases).
