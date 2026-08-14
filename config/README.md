# config/ — the single source of truth

Everything that differs between machines, deployments or recording sessions lives
here. Nothing in `scripts/` hardcodes any of it; each script reads these files, so
changing a value here changes it for every consumer on both hosts.

| File | Format | What it decides |
|---|---|---|
| `host` | one word (`master` or `orin`) | which machine this checkout is on. Selects the DDS profile. **Gitignored** — it is a property of the machine, not the branch |
| `multi_machine.conf` | shell assignments | the other host's `user@addr`, its repo path, the ssh key, the master's IP |
| `recording/master_topics.txt`<br>`recording/orin_topics.txt` | one topic per line, `#` comments | what each host records |
| `cyclonedds/{master,orin,loopback}.xml` | CycloneDDS XML | DDS network profiles, one per role |

Formats are deliberately unlike each other: the topic lists are edited by hand and
diffed per line, so a flat list beats YAML; `multi_machine.conf` is sourced by
shell scripts, so it is shell; the DDS profiles are XML because CycloneDDS reads
them directly and we do not want to generate them.

## Setting the host marker

```bash
echo master > config/host      # or: orin
just doctor                    # confirms what resolved, and from where
```

Precedence, highest first: `GOLFCART_ENV_ROLE` (how the systemd units state their
role), then an exported `GOLFCART_DDS_PROFILE`, then this file, then `loopback`.
A marker naming a profile with no `cyclonedds/<name>.xml` is reported loudly and
falls back to `loopback` — silently running the wrong profile is the failure this
machinery exists to prevent.

The older location `.golfcart-host` in the repo root is still read when
`config/host` is absent, so an existing checkout keeps working after a pull.

## Changing the other host

`multi_machine.conf` keys take their value from the `GOLFCART_`-prefixed
environment variable of the same name when it is set, so an override still wins
for one shell or one unit:

```sh
ORIN_SSH="${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}"
```

`ORIN_WORKSPACE` accepts `~/path` or an absolute path; the tilde is expanded by
the *remote* shell, since this machine's `$HOME` is the wrong answer.

## Changing what is recorded

Edit the topic lists — not any script. Audit them against a running stack:

```bash
ros2 topic list > /tmp/live.txt
grep -vE '^\s*(#|$)' config/recording/master_topics.txt | tr -d ' ' \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

A stale entry records zero messages while still appearing in `ros2 bag info`,
which reads as "the sensor was quiet" rather than "the name is wrong".
