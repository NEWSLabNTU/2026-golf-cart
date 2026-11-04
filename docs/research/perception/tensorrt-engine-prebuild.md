# Prebuilding TensorRT engines for the Orin fleet

Status: study, 2026-11-05. Nothing is built yet. The Orins were offline, so
no fleet inventory was taken and nothing here was measured on an Orin.

## The problem

Every Autoware perception node that runs an ML model compiles its ONNX file
into a TensorRT engine on first launch. On the Orin, CenterPoint alone takes
more than thirty minutes, and with every model the stack uses it adds up to
hours before a fresh vehicle, or one with new models, can drive. An engine is
bound to the hardware and software it was built on, so it cannot simply be
copied to an arbitrary other host.

The question was whether the engines can be prebuilt, ideally on the
workstation, for the platforms we deploy.

## What an engine is tied to

From NVIDIA's [Engine Compatibility] page:

- **TensorRT version.** "By default, TensorRT engines are compatible only with
  the version of TensorRT used to build them." Major, minor and patch must
  match.
- **Device type.** "By default, TensorRT engines are only compatible with the
  type of device where they were built." The plan records the compute
  capability, and deserialization fails if the loading GPU differs.
- **Platform.** The same OS and CPU architecture.

What Autoware adds on top, read from `autoware_tensorrt_common`
(`src/tensorrt_common.cpp`, identical in 1.5.0, 1.7.1 and 1.9.0):

- The engine path defaults to the ONNX path with `.engine`; the node writes
  `<stem>.engine` and `<stem>.json` next to the model, in `data_path`
  (`~/autoware_data` by default). The directory must be writable by the user
  who launches Autoware.
- `validateEngine()` compares only the TensorRT version recorded in the plan
  with the running one, and rebuilds on a mismatch.
- `validateNetworkIO()` and `validateProfileDims()` then check tensor shapes
  and the optimization profile, and rebuild on a mismatch. So an engine built
  for other input sizes or another precision is rebuilt, not misused.
- The builder sets only precision (`kFP16`/`kINT8`), DLA and the workspace
  limit. It sets no hardware compatibility level, no timing cache and no
  builder optimization level.

## Why the workstation cannot build Orin engines

Building an engine benchmarks candidate kernels on the GPU it runs on and
keeps the fastest. The Orin's GPU, compute capability 8.7, exists only on
Orin, so no other machine can do that timing.

TensorRT's two escape hatches do not cover this:

- **Hardware compatibility** (`kAMPERE_PLUS`, `kSAME_COMPUTE_CAPABILITY`)
  builds one engine for a class of GPUs, at some cost in speed. The page says
  "Currently, hardware compatibility is not supported on NVIDIA DriveOS or
  NVIDIA JetPack", and Autoware does not set it anyway.
- **Cross-platform builds** (`setRuntimePlatform`, TensorRT 10.3) support
  exactly one pair: build on Linux x86_64, run on Windows x86_64
  ([TensorRT 10.3 release notes], [RuntimePlatform]). There is no Jetson
  target.

Engines built on the workstation therefore run only on GPUs of the
workstation's type. That still has uses (a lab of identical desktops), but not
for the vehicles.

## What does work: build on one Orin, ship to the identical ones

An engine runs on another device of the same type. NVIDIA staff describe the
"plan file across devices" warning as a catch-all, and fine for the same GPU
type ([forum: same type]); it even appears on the device that built the engine
([forum: same Jetson]). Across Orin models (AGX, NX, Nano, all sm_87 but with
different SM counts and memory) NVIDIA's advice is to build on each device
type ([forum: Orin Nano]).

So one Orin can build for every Orin that matches it in:

- the Orin model (for example AGX Orin 64GB);
- the TensorRT version, which follows from the JetPack;
- the Autoware release, which fixes the ONNX files, precisions, input shapes
  and the plugin libraries the engines reference.

## The fleet runs several JetPacks

What matters is the TensorRT version, not the JetPack number. The table is
from memory and needs checking against NVIDIA's release tables and the boards
themselves:

| JetPack | Ubuntu | TensorRT | autoware-localrepo `jetpack62` |
|---|---|---|---|
| 5.x | 20.04 | 8.5 | cannot install: built for 22.04 |
| 6.0 | 22.04 | 8.6 | not supported: the builds need TensorRT 10 |
| 6.1 | 22.04 | 10.3 | untested |
| 6.2 | 22.04 | 10.3 | supported |

If that holds, 6.1 and 6.2 share TensorRT 10.3 and could share packs (two
things to verify: that a 6.1 board installs the localrepo, and that it loads
engines built on 6.2). Orins on 5.x or 6.0 cannot run our Autoware builds at
all and need upgrading first.

To take the inventory once the Orins are online, run on each:

```bash
printf '%s | %s | TensorRT %s | Autoware %s\n' \
  "$(tr -d '\0' </proc/device-tree/model)" \
  "$(dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null || head -1 /etc/nv_tegra_release)" \
  "$(dpkg-query -W -f='${Version}' libnvinfer10 libnvinfer8 2>/dev/null | head -1)" \
  "$(ls /opt/autoware 2>/dev/null | tr '\n' ' ')"
```

## Proposed design: engine packs

A pack is the engines for one key: (Autoware version, TensorRT version, GPU
model). It is built once per release on one Orin of each group and shipped to
the rest.

1. **Build.** Start each perception node that has a model, through Autoware's
   own code, and wait for "Engine setup completed"; then collect the
   `.engine` files. Not `trtexec`: each node sets its own shapes, precision
   and custom plugins, and a mismatch would make Autoware reject the engine
   and rebuild it on the vehicle anyway.
2. **Manifest.** Record the key, the JetPack, and for every engine the sha256
   of the ONNX file it was built from. Name the pack after the key, e.g.
   `engines-1.5.0-trt10.3-orin-agx-64gb.tar`.
3. **Install.** On the vehicle, refuse a pack whose key does not match the
   machine. Otherwise put each engine next to its model only if the model's
   sha256 matches the manifest. Anything left out is built on first launch,
   as today. A wrong engine is never installed, so this can only save time.
4. **Key.** A command that prints the machine's key, so an operator can see
   which pack an Orin needs.

Where it lives: **not in autoware-localrepo.** That repository packages
Autoware releases and carries patches only for bugs and friction. The tool
gets its own project (a new repository is the likely home, so it serves any
Autoware fleet; undecided).

The mechanism is GPU-independent, so it can be developed and tested end to
end on a desktop or server GPU (the arm64 build server `arm-a100` has two
A100s): build a pack, install it into a fresh `~/autoware_data`, and confirm
that the node logs "Loading engine" and no build. Start with Autoware 1.5.0
and CenterPoint, the cart's version and detector.

## Faster builds (separate, later)

Two TensorRT features would shorten the builds themselves. Autoware does not
expose either, so both would be a patch to `autoware_tensorrt_common` in our
fork, behind an opt-in switch, and neither is measured:

- **Timing cache:** reuse kernel timings between builds on the same device
  type, so later builds (other models, new releases) repeat less benchmarking.
- **Builder optimization level:** a lower level builds faster, at some cost in
  runtime speed, which would need measuring on the Orin.

Before either, it is worth confirming the Orin builds at full speed: maximum
power mode (`sudo nvpmodel -q`, `sudo jetson_clocks`), and no several nodes
building at once and competing for the GPU.

## Open questions

- Which Orin models and JetPacks the fleet runs (the inventory above).
- Whether JetPack 6.1 boards install the `jetpack62` localrepo and load
  engines built on 6.2.
- Whether an engine built on one AGX Orin loads on another of the same SKU
  without a rebuild; expected yes, unverified on our boards.
- Where the engine-pack tool lives.

[Engine Compatibility]: https://docs.nvidia.com/deeplearning/tensorrt/latest/inference-library/engine-compatibility.html
[TensorRT 10.3 release notes]: https://docs.nvidia.com/deeplearning/tensorrt/archives/tensorrt-1030/pdf/TensorRT-Release-Notes.pdf
[RuntimePlatform]: https://docs.rs/trtx-sys/latest/trtx_sys/real_bindings/nvinfer1/enum.RuntimePlatform.html
[forum: same type]: https://forums.developer.nvidia.com/t/do-tensorrt-plan-files-are-portable-across-different-gpus-which-have-the-same-type/72756
[forum: same Jetson]: https://forums.developer.nvidia.com/t/tensorrt-warning-using-engine-plan-file-across-devices-seen-even-when-engine-generated-on-same-jetson/331064
[forum: Orin Nano]: https://forums.developer.nvidia.com/t/issues-with-using-tensorrt-on-jetson-orin-nano/363072
