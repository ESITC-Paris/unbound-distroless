# Contributing

Issues and pull requests are welcome. The repository has one maintainer and
support is best effort; small, focused pull requests with a test are the
ones that get merged. Security problems go to
[private reporting](SECURITY.md), not to an issue.

## Building and testing locally

Requirements: Docker with Compose v2, `dig` (`dnsutils` / `bind9-dnsutils`),
bash, `git`, `python3`.

```bash
scripts/build.sh                                   # the resolver, as CI pins it -> unbound-distroless:test
bash tests/structure.sh unbound-distroless:test    # image invariants
bash tests/functional.sh unbound-distroless:test   # DNS, DNSSEC, features, port 53 (tests/port53.sh)
bash tests/quickstart.sh unbound-distroless:test   # the README's two quick starts, as written
bash tests/docs.sh                                 # every relative link and anchor in the Markdown files
bash tests/monitor.sh                              # the monitor's decisions, no network
bash tests/trigger.sh                              # deploy/unbound-upstream-check, no network
```

The sidecar: build `updater/` and run `bash tests/updater.sh <image>`; the
`updater` job of [`ci.yml`](.github/workflows/ci.yml) shows the build
arguments. Its suite drives real containers and pulls published images.

[`ci.yml`](.github/workflows/ci.yml) runs all of this on every pull request,
plus hadolint, shellcheck, actionlint, promtool and the Trivy gates; its
`lint`, `build-and-test` and `updater` jobs (the last one on both Docker
image stores) must pass before a merge.

## What a pull request must respect

- **Actions pinned by full commit SHA**, with the tag in a trailing comment
  (`uses: owner/action@<sha> # vX.Y.Z`). Dependabot keeps them current.
- **No `${{ }}` inside a `run:` body.** Pass values through `env:` and use
  them as shell variables.
- **Images pinned by digest**: the base images through `.build-state.json`,
  the lint and test tool images inline. `versions.env` and
  `.build-state.json` are written by the monitor; edit them by hand only to
  fix the monitor.
- **No `schedule:` trigger** on anything on the release path (Scorecard is
  the one exception, see its header). No hand-written `X.Y.Z-rN` anywhere in
  the repository: it goes stale at the next automatic revision.
- **A test for every behaviour**: a change in what the image, the sidecar or a
  workflow script does comes with the test that shows it. Shell scripts pass
  `shellcheck -S warning` (add new ones to the list in `ci.yml`).
- **Documentation true to the code.** Every statement must hold for the code
  in the same pull request; one file owns each topic and the others link to
  it (the map is in the [README](README.md#documentation)).
