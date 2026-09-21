# Handover, 2026-09-21: F9P and NTRIP brought into this repo

The `feat/f9p` work now runs from this repository rather than from the standalone
`ublox_f9r_ws` it was developed in. Every piece of the chain is wired and
verified except the one that needs sky: the receiver saw zero satellites in the
garage, so no RTK corrections ever flowed.

The bring-up history of the workspace itself, including the dead ends, is
[`src/sensor_component/external/ublox_f9p_ws/SETUP_LOG.md`](../../src/sensor_component/external/ublox_f9p_ws/SETUP_LOG.md).
This page records what it took to get that workspace working *here*, and what
the next session should do differently.

**Host:** `advantech`, Linux 5.15.148-tegra, ROS 2 Humble
**Receiver:** u-blox ZED-F9P, `EXT CORE 1.00 (61b2dd)`, HW `00190000`, firmware 9

## What was in the way

Four things, none of them the driver.

**The submodule would not clone.** `just checkout` failed on
`ublox_f9p_ws` with `Invalid username or token`. The cause was `gh`, not git:
two accounts were logged in and the *active* one (`jerry73204`) had an invalid
keyring token, which is the token `credential.https://github.com.helper` hands
to git. The other account (`qwaszxallen`) had a valid token all along.
`gh auth switch -h github.com -u qwaszxallen` fixed it outright.

> Worth knowing: `gh auth status` reports a healthy second account cheerfully
> enough that the broken active one is easy to miss. The clone failure names
> neither account.

**The sensor kit pointer was never bumped.** The parent's `feat/f9p` pinned
`golfcart_sensor_kit_launch` at `0a0c021` (its `main`), but the NTRIP work is a
single unmerged commit `e662a5a` on that fork's own `feat/f9p`. It carries
`config/ntrip_client.param.yaml` (a new file), the `use_ntrip` plumbing in
`gnss.launch.xml`, the rover `ublox_f9p.yaml` and the `package.xml` deps. With
the old pointer, `use_ntrip:=true` had nothing to load, and
`check_ntrip_setup.sh` failed on the missing config.

This is the second half of the Submodule Pointer Rule in
[CLAUDE.md](../../CLAUDE.md#submodule-pointer-rule) — pushed to the fork, but
onto a `feat/…` branch, with no parent pointer update. **It is still only on
that feature branch.** Parent commit `f6fcf3b` points at it anyway, so merging
`e662a5a` to the sensor kit's `main` is outstanding work, not a nicety: delete
the feature branch first and `f6fcf3b` becomes unusable.

**The check script never ran.** `scripts/testing/ntrip/check_ntrip_setup.sh`
lives three directories deep but walked up two, landing in `scripts/`. It died
on its own first step, sourcing `scripts/env.sh`. Fixed in `de09103`.

**The account lives outside this repo.** `config/ntrip.param.yaml` is gitignored
and was absent, so the kit's credential-less copy would have loaded and the
client would have exited naming the missing parameter. The e-GNSS account is
hardcoded in the old workspace at
`/mnt/external/ublox_f9r_ws/src/ntrip_client/launch/ntrip_client_launch.py:14-15`.
Copied from there into `config/ntrip.param.yaml`, keeping the example's
`GNSS_Taiwan` mountpoint rather than that file's `Taiwan` — RTCM 3.2 MSM against
3.1, all five constellations against GPS and GLONASS only, per SETUP_LOG §8.

> That workspace also has a commented-out RTK2GO block with a personal Gmail
> account in it. Neither set of credentials belongs in a launch file; this repo
> keeps them in the gitignored config for exactly that reason.

## What was verified, and how

Standalone, no Autoware stack — the lightest path that exercises the whole
chain. This is now a recipe, `just gnss test`, which starts that launch,
measures it and tears it down:

```bash
just gnss check     # packages, config, account, device, caster port
just gnss test      # 60s measurement, then a verdict naming the broken link
just gnss attach    # same measurement against an already-running full stack
just gnss kill      # free /dev/ttyACM0 after an interrupted run
```

Topics come up under `/gnss` rather than `/sensing/gnss`, since the `sensing`
prefix is added by the chain above. All four remaps land correctly:
`ntrip/rtcm`, `ublox/nav_sat_fix`, `ublox/nmea_sentence`, `ublox/rxmrtcm`.

| Check | Result |
|---|---|
| Driver opens `/dev/ublox-gps`, F9P self-identifies | ✅ |
| NTRIP client subscribes `/gnss/ublox/nmea_sentence`, publishes `/gnss/ntrip/rtcm` | ✅ |
| Caster authenticates | ✅ `Connected to http://210.241.63.193:81/GNSS_Taiwan` |
| NavSatFix publishes | ✅ 57 msgs / 60 s, `status=-1` |
| RTCM arrives | ❌ **0 messages in 60 s** |
| Receiver accepts RTCM (`rxmrtcm`) | ❌ **0 messages** |

Counting is done by `scripts/testing/gnss/gnss_test.py` over a fixed window, not
`ros2 topic hz` — SETUP_LOG §10 is right that a short `hz` window misreads this
stream badly, and it reads 0 Hz identically whether the caster is silent or the
topic is dead.

Three startup NACKs, matching what SETUP_LOG §4 describes for the HPG Reference
product: `0x06 / 0x8a` once (VALSET during the TMODE3 disable) and `0x06 / 0x01`
twice. Expected, not a fault.

## Why there are no corrections

The receiver has no satellites, so it emits a position-less GGA:

```
$GNGGA,031512.00,,,,,0,00,99.99,,,,,,*7C        quality 0, 00 sats, HDOP 99.99
$GNGSA,A,1,,,,,,,,,,,,,99.99,99.99,99.99,1*33   mode 1, no fix
```

Every e-GNSS mountpoint is a network VRS, which cannot place a virtual base
without a rover position. It accepts the connection, reads that GGA, and hangs
up:

```
[gnss.ntrip_client]: Connected to http://210.241.63.193:81/GNSS_Taiwan
[gnss.ntrip_client]: Exception: [Errno 32] Broken pipe
[gnss.ntrip_client]: Unable to send NMEA sentence to server.
```

The client then loops on the dead socket rather than reconnecting, because the
node has not exited and `respawn` only covers exit.

`NavSatFix` reports lat 8.79 / lon 113.59 / alt 495.8 with covariance around
1.8e13 — not a position, an uninitialized one, and a good deal further from
Taipei than the lat 25.0176 / lon 121.5442 SETUP_LOG recorded. That difference
matters for reading the old log: **that session had a rough position and this
one had none**, which is why it saw corrections flow indoors (§10) and this did
not. Nothing regressed between the two; the receiver was simply colder.

This is SETUP_LOG open issue 3, and it needs open sky, not a code change.

## One caveat that did not reproduce

**SETUP_LOG §9 records GGA being dropped ~95% by a driver bug** in
`handle_nmea()` — 3 GGA per minute against an expected 60, because an NMEA
sentence split across a serial read boundary is discarded, and GGA leads each
epoch burst.

Measured here over 60 s:

```
$GNGGA: 57    $GNGLL: 57    $GNRMC: 57    $GNVTG: 57
$GNGSA: 228   $GPGSV: 114   $GLGSV: 114   $GAGSV: 114   $GBGSV: 112
```

**57 of ~60, or 95% delivered** — the inverse of the logged figure, with `GNGLL`
at the same rate rather than 20x higher. A second run over 45 s was cleaner
still: **45 GGA in 45 s, 1.00 Hz, no drops at all.**

The driver is the same commit (`c56b851`), so the code path has not changed.
The likely difference is configuration: this repo's `ublox_f9p.yaml` pins
`rate: 1.0` and `nav_rate: 1`, where the workspace's `zed_f9p.yaml` omits both
and free-runs at roughly 2 Hz, putting twice the traffic across the same read
boundaries.

That is a hypothesis with two supporting measurements, not a fix — the bug in
`handle_nmea()` is still there and a faster stream should still trip it. But
the practical point stands: **do not carry the "GGA is 95% lost" caveat forward
untested.** On this configuration it is not true, and an outdoor run should
confirm it at 1 Hz with a real position in each sentence.

## Things that will bite

- **`pkill -f gnss.launch.xml` orphans both nodes.** SETUP_LOG says this and it
  is still true: the launch parent dies, `ublox_gps_node` keeps `/dev/ttyACM0`,
  and the next launch fails to open the port. `pkill -f ublox_gps_node` did not
  reach it either; killing the PIDs directly did. Check with
  `fuser /dev/ttyACM0` before relaunching, and allow the 15–20 s settle SETUP_LOG
  describes or the driver throws `Failed to read the GNSS config`.
- **The NTRIP node ignores SIGTERM** while blocked on the socket. `kill -9`.
- **apt `ros-humble-ublox-gps` is still installed.** The workspace build shadows
  it, and `check_ntrip_setup.sh` warns about it, but the two disagree on the
  RTCM message type (`rtcm_msgs/Message` against `mavros_msgs/RTCM`), so a
  sourcing accident would be silent and confusing. CLAUDE.md says remove it;
  that has not been done on this host.
- **`gnss_poser` warns about `map_projector_info` forever** on the standalone
  launch. Expected — no map is loaded. It is noise here, not a fault.

## Next

1. **Outdoors, with sky.** `just gnss test`, same 60 s count. Expect RTCM
   in bursts at ~1 Hz epochs (SETUP_LOG measured 7.77 Hz mean over 57 bursts),
   `rxmrtcm` with `flags: 0`, and `NavSatFix.status` climbing from -1 to 2 as
   RTK converges. Confirm the GGA rate holds at ~1 Hz with a real position.
2. **Merge `e662a5a` to the sensor kit's `main`** and re-point the parent, before
   the feature branch is deleted under `f6fcf3b`.
3. **Remove the apt u-blox packages** on this host.
4. Once RTK converges, check `gnss_poser` output against the map frame through
   the full stack rather than standalone.

## Commits

| | |
|---|---|
| `de09103` | `fix(scripts)`: check script walks up three levels, not two |
| `f6fcf3b` | `feat(gnss)`: point the sensor kit at the F9P NTRIP commit `e662a5a` |

Not committed, and correctly so: `config/ntrip.param.yaml` (gitignored, holds
the lab's e-GNSS account).
