# Implementation Plan — Orin Provisioning + Systemd Promotion

**Status**: Working plan (2026-08-14)
**Plans**: [orin_provisioning_and_systemd_promotion.md](orin_provisioning_and_systemd_promotion.md) — the
design this sequences. Read that first; this document records what a review of
the codebase changed about it, and the order the work should land in.

---

## 1. What the codebase check confirmed

| Design claim | Verified |
|---|---|
| §2.1 `install-zed-sdk.sh` missing; build gates on `/usr/local/zed` | Yes — `justfile:31-33`, `zed-ros2-wrapper` present in `src/` |
| §2.4 units hardcode `%h/2026-golf-cart`, installer only warns | Yes — `install-orin-host.sh:18-22`; both units affected |
| §3.1 master runs from a shell trap, not systemd | Yes — `justfile:119-125`; master has `Linger=no` and no golfcart units |
| §3.2 systemd units get no direnv, so `GOLFCART_BAG_DIR` must be set explicitly | Yes — `record_master.sh` reads it, falling back to `~/rosbags` |

## 2. What the check changed

### 2.1 `./setup.sh orin` needs no change to `setup.sh`

`setup.sh:296` already ends in `just "$@"` executed inside `setup/`. Any recipe
added to `setup/justfile` is reachable as `./setup.sh <recipe>` immediately.
Design §2.3 is therefore a *recipe*, not an entry point.

One wrinkle: §2.3 steps 1 and 4 (`git submodule update`, `just build`) live in
the **root** justfile, which `setup/justfile` has no access to. The `orin`
recipe must shell out with an explicit working directory.

### 2.2 The sysctl ordering trap is already mostly closed

Design §2.1 and §2.5 treat the ZED SDK stomping `net.core.rmem_max` as an open
ordering hazard requiring `configure-cyclonedds-sysctl.sh` to re-run after every
SDK install. But that script already writes `99-cyclonedds-max.conf` — which
sorts *after* the SDK's `60-zed-buffers.conf` — and deletes the superseded
`10-cyclone-max.conf` so the two cannot disagree.

Persistence across reboot is solved. What remains is only the **running** value
in the same session as an SDK install, since dropping a file into
`/etc/sysctl.d` does not apply it. The post-SDK step is therefore
`sudo sysctl --system`, not a full re-run, and `orin-setup`'s hard ordering
constraint between `zed-sdk` and `cyclonedds-sysctl` largely dissolves.

The `orin-check` item (§2.5) stays as-is regardless: it verifies the running
value, which is exactly the thing that can still be wrong.

### 2.3 §3.1's headline justification is unverified — settle it before building on it

Design §3.1 presents `TimeoutStopSec=180` as *the fix* for the 0-byte
`metadata.yaml` roadblock. `docs/roadblocks.md:121` states the cause is
**play_launch's** shutdown grace, not the supervisor's. If roadblocks.md is
right, the systemd timeout is inert: systemd sends SIGINT to play_launch, and
play_launch still kills the recorder on its own schedule.

Neither claim is currently established, because the two hypotheses fit every
observation we have:

- *Size*: master bags (2.2 GB, 2.5 GB) fail; orin bags (~300 MB) do not.
- *Supervision*: the master runs play_launch in the foreground; the orin runs it
  under systemd with `KillSignal=SIGINT` and `TimeoutStopSec=30`.

The only systemd-supervised host never writes a large bag, so the variables have
never been separated. play_launch 0.5.1 exposes no CLI grace flag; its
`-c/--config` YAML advertises "process control", but no shutdown-timeout key
could be confirmed in the shipped binary.

This matters because §3.3 (justfile rewire) and §3.4 (installer) inherit §3.1's
justification. **Phase 0 below separates the variables before anything depends
on the answer.**

### 2.4 Stray user units on the master

`box-ddspong.service` is enabled via `default.target.wants` and running — a
leftover ROS 2 node from `~/systemd-user-test` that joins the DDS domain. Five
further `box-*` units are installed but inactive. Removing them belongs in the
phase that touches the master's user manager (Phase 2).

---

## 3. Phases

### Phase 0 — separate size from supervision — RUN 2026-08-14

Master unit (`setup/files/systemd/golfcart-master.service`) and exec script
(`scripts/multi_machine/master_unit_exec.sh`) written; justfile untouched, so
the existing launch path kept working throughout.

**Result: the bag finalized.** 3.2 GiB written to the SSD — above both previously
reproduced failures (2.2 GB, 2.5 GB) — then stopped with
`systemctl --user stop`:

```
metadata.yaml   10530 bytes (was 0 on every previous multi-GB bag)
ros2 bag info   213.9s duration, 94444 messages
PRAGMA quick_check  ok
SELECT count(*)     94444   (matches metadata exactly)
```

**But the design's stated mechanism is not what produced this.** `stop` returned
in ~1 s, so `TimeoutStopSec=180` was never approached, let alone exercised. Any
value ≥2 s would have given the same result. Whatever distinguishes the systemd
path from the foreground path, it is not the length of the grace period, and
§3.1's comment sizing the timeout "for a multi-gigabyte bag flush" describes a
mechanism that did not engage.

The obvious candidate — systemd delivering SIGINT where the foreground path did
not — does not survive scrutiny either: Ctrl-C also sends SIGINT, and
`KillMode=control-group` signals the whole cgroup much as a terminal signals the
foreground process group.

#### Control arm — same size, foreground path

Run immediately afterwards with every variable held constant except the
supervision path: same `record:=true use_gnss:=false`, no orin, same SSD
directory, same session. Started through the old `just launch-master` under
`setsid`, then stopped with `kill -INT -<pgid>` — SIGINT to the whole process
group, which is what a terminal does on Ctrl-C.

```
bag size            3.3 GB   (vs 3.2 GiB for the systemd arm)
metadata.yaml       absent
PRAGMA quick_check  ok
SELECT count(*)     100646   (data intact; only finalization was lost)
stack exit          still running after 240s (systemd arm: ~1s)
```

**Conclusion: supervision is the variable, not bag size.** Two bags of the same
size, minutes apart, same disk and same arguments: the systemd path finalized,
the foreground path did not. The design's promotion is therefore justified —
but *not* by the reason §3.1 gives, since `TimeoutStopSec` was never approached
in the arm that worked.

The mechanism remains unidentified, and the obvious candidate is now ruled out:
both paths deliver SIGINT to every process (`KillMode=control-group` signals the
whole cgroup, exactly as a terminal signals the process group). The unexplained
asymmetry is the shutdown *duration* — ~1 s under systemd versus >240 s in the
foreground arm, where play_launch was still alive when the wait expired. The
extra `just`→bash→`just`→bash layers between the signal and play_launch are the
place to look next.

Caveat: the control used `setsid` + `kill -INT -<pgid>`, not a real terminal —
faithful in signal delivery, but with no controlling tty.

**Actions taken**: `docs/roadblocks.md` corrected — its root-cause sentence
attributed the failure to a shutdown grace shorter than a multi-gigabyte flush,
which the control arm disproves at equal size. §3.1's `TimeoutStopSec` comment
should be reworded before Phase 1 lands, since it claims a mechanism that never
engaged.

### Phase 1 — master unit

Design §3.1–3.2, plus `orin_start_if_enabled.sh`. Justified by Phase 0's result.

### Phase 2 — justfile rewire + installer

Design §3.3–3.4. Blocked on the Ctrl-C decision (§4 below). Fold in
`loginctl enable-linger` for the master and the `box-*` cleanup from §2.4.

### Phase 3 — orin provisioning

Design §2.1–2.4, revised per §2.2 above. Independent of Phases 0–2 and can run
in parallel. The `orin` recipe must shell out to the root justfile for `build`.

### Phase 4 — `orin-check`

Design §2.5. The table is sound as written: all five checks map to failures that
have actually occurred on this hardware.

### Phase 5 — docs

Design §2.6/§3.5, plus the stale "Systemd Service Integration" section of
CLAUDE.md, which documents a `golfcart` CLI inherited from AutoSDV that does not
exist in this repository.

---

## 4. Decisions still open

Both carried from design §6:

1. **Ctrl-C semantics.** Full promotion (§3.3) means Ctrl-C on the journal no
   longer stops the stack; `just stop-master` becomes the stop verb. That is the
   point — it is what makes the master survive a dropped ssh session — but it
   changes the daily driving workflow. Blocks Phase 2.
2. **ZED SDK delivery.** Pinned download at install time vs. staging the ~1.5 GB
   `.run` locally. Blocks Phase 3.
