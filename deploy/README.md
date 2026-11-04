# deploy/

## `unbound-upstream-check` — the hourly trigger of the update monitor

The update monitor (`.github/workflows/upstream-check.yml`) has no GitHub
`schedule`: this script, run hourly from cron on an ESITC host, dispatches it
through the GitHub API. It dispatches, **waits for the run to actually
start**, reports to a Healthchecks.io check (so a host or cron that goes
quiet raises an alert — the only way to notice that runs have *stopped*),
and warns ahead of the token's expiry. Installation, cron line and
supervision are in [docs/operations.md](../docs/operations.md); every
setting is documented at the top of the script; `tests/trigger.sh` covers it
without network.

## Removed: the host-side updater that used to live here did not update anything

The `unbound-autoupdate` script, its systemd timer and `install.sh` have been
removed from this directory. Read against the code, the script could not
update a deployment that follows the `:latest` tag this repository's own
`docker-compose.yml` declares:

- it pulled `esitcparis/unbound-distroless:1` and compared image IDs;
- it then swapped with `docker compose up -d`, which deploys the image
  written in the compose file — `:latest` — and Compose does not re-pull an
  image that is already present locally;
- the container therefore stayed on the old image, the post-swap checks
  validated that untouched old container, and the run logged
  "production updated", sent a success e-mail and pinged Healthchecks;
- an hour later the image IDs still differed and the same sequence ran
  again, indefinitely.

Its rollback also rewrote the local `:1` tag with `docker tag`, and
`install.sh` passed the raw `config_files` container label (which may be
relative, or list several files) straight to `docker compose -f`.

If you installed it, your resolver was very likely never actually updated:

```bash
systemctl disable --now unbound-autoupdate.timer
rm -f /usr/local/bin/unbound-autoupdate \
      /etc/systemd/system/unbound-autoupdate.service \
      /etc/systemd/system/unbound-autoupdate.timer \
      /etc/unbound-autoupdate.conf
systemctl daemon-reload
```

Its replacement is the **[`updater/`](../updater/) sidecar**, which swaps
through Compose itself (`compose pull` + `compose up -d` on the declared
service, so the tag it validates is the tag it deploys), verifies the
container really ends up on the declared image after the swap, and is
covered by an integration suite (`tests/updater.sh`) that asserts exactly
that.
