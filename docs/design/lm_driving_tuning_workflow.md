# LM Integration for Driving: Modular Architecture and Tuning Workflow

**Status**: Design proposal (2026-07-08)
**Depends on**: [docs/research/safety/assurance-2.0-for-autoware-llm.md](../research/safety/assurance-2.0-for-autoware-llm.md)
(tier model: this design targets tier 1 → tier 2; tier 3 evidence collection only)

**Goal**: A workflow to tune a language model that
1. accepts fused multimodal vision input (BEV) through new tokens/adapters,
2. learns driving skills — text-prompt understanding (vision → text) and spatial generation
   (e.g., drawing zones in the output), and
3. operates behind runtime safety measures.

---

## 1. Reference designs from the literature

| System | What we take from it |
|---|---|
| [BEVDriver (arXiv 2503.03074)](https://arxiv.org/abs/2503.03074) | The overall recipe: camera+LiDAR → latent BEV → Q-Former projector → LoRA-tuned Llama; frozen 5.37M-param perception at 18 Hz; two-stage training |
| [LMDrive](https://www.researchgate.net/publication/384220970_LMDrive_Closed-Loop_End-to-End_Driving_with_Large_Language_Models) | Closed-loop CARLA training/eval harness, 15k instruction-following sequences, completion-flag head |
| [Talk2BEV (arXiv 2310.02251)](https://arxiv.org/abs/2310.02251) | Zero-training alternative: language-enhanced BEV map as JSON/object context — our tier-1 fast path |
| [OmniDrive](https://arxiv.org/abs/2405.01533) | 3D tokenization for spatial understanding; counterfactual reasoning data |
| LISA / LISA++ / PixelLM / GSVA ([survey](https://arxiv.org/abs/2505.18816)) | **Embedding-as-mask**: `<SEG>`-style tokens whose hidden states drive a mask decoder; `<REJ>` token for empty targets; segmentation codebook for multi-mask output |
| [DriveMA (arXiv 2605.31271)](https://arxiv.org/abs/2605.31271) | **Verifiable meta-actions**: LM emits symbolic actions checked against formal specification before execution; verifier feedback used in training |
| [SimLingo (CVPR 2025)](https://openaccess.thecvf.com/content/CVPR2025/papers/Renz_SimLingo_Vision-Only_Closed-Loop_Autonomous_Driving_with_Language-Action_Alignment_CVPR_2025_paper.pdf) | Action Dreaming (instruction-conditioned counterfactual actions) for language-action alignment; safety-case patterns exist for it (arXiv 2603.16013) |
| [Senna-2 (arXiv 2603.11219)](https://arxiv.org/abs/2603.11219) | VLM decides, e2e policy executes — decision/execution split matching our safety tiers |
| [DriveLM](https://arxiv.org/abs/2312.14150) | Graph-VQA driving instruction data; staged perception→prediction→planning QA |

---

## 2. Architecture: modular parts attached to a frozen-ish LM

```
                       ┌────────────────────────────────────────────┐
 cameras ──┐           │                LM core (7–8B, LoRA)        │
           ▼           │                                            │
   ┌───────────────┐   │  text tokens ─────────────┐                │
   │  BEV encoder  │   │  <BEV_1..N> tokens ───────┤ transformer    │
   │ (cam ⊕ LiDAR) │──▶│  (from projector)         │ decoder        │
   └───────────────┘   │                           ▼                │
 VLP-32C ──┘           │        output stream: text ∪ special tokens│
                       └───────┬──────────┬───────────┬─────────────┘
                               │          │           │
                        <ZONE_k> hidden   │      <META_*> tokens
                               ▼          │           ▼
                       ┌──────────────┐   │   ┌──────────────────┐
                       │ mask decoder │   │   │ meta-action      │
                       │ over BEV grid│   │   │ verifier (formal │
                       └──────┬───────┘   │   │ spec, determin.) │
                              ▼           ▼   └────────┬─────────┘
                        zone polygons   text      pass/reject
                        (drivable, risk,  (explanations,   │
                         attention)        answers)        ▼
                                                   Autoware planner /
                                                   executor (tier-gated)
```

### 2.1 Input side: BEV tokens

- **BEV encoder**: fuse multi-view USB cameras + VLP-32C point cloud into a latent BEV grid.
  Two options:
  - *Reuse Autoware perception*: tap the intermediate BEV feature map of the existing
    CenterPoint pipeline (already computed on the cart) plus a lightweight camera lift-splat
    branch. Cheapest; shares compute with perception.
  - *Dedicated encoder* (BEVDriver-style): ResNet-50 (images) + ResNet-18 (LiDAR) →
    transformer encoder → 256-d BEV embeddings, trained with auxiliary losses (detection L1,
    traffic-light CE, segmentation focal, temporal contrastive). ~5M params, real-time.
- **Projector**: BLIP-2-style **Q-Former with 32 learnable query tokens** (768-d) cross-attends
  into the BEV feature map and emits a fixed budget of `<BEV_1..32>` soft tokens into the LM
  input. MLP projector is the simpler fallback (LLaVA-style) if Q-Former training is unstable.
- **New input tokens**: `<BEV>` span markers, `<EGO>` (ego state: speed, yaw rate from vehicle
  interface), `<NAV>` (route/goal from mission planner), optional `<MAP>` (Lanelet2 crop
  serialized as polylines). Ego/nav enter as text or learned scalar embeddings — text is
  simpler and auditable.
- **Temporal context**: ring buffer of BEV frames (BEVDriver uses up to 40); start with 4–8
  frames to fit Orin memory.

### 2.2 Output side: three heads

1. **Text** — native decoding: scene description, hazard explanation, VQA answers,
   chain-of-thought. This alone covers tier 1 (advisory).
2. **Zones (vision output)** — LISA-style *embedding-as-mask*:
   - Add a small codebook of special tokens `<ZONE_1..K>` (+ `<REJ>` for "no such zone",
     following GSVA). When the LM emits `<ZONE_k>`, its last-layer hidden state is projected
     and fed as a query to a lightweight **mask decoder over the BEV grid** (2–4 layer
     pixel decoder à la PixelLM; SAM-style decoder if masks are wanted in camera view too).
   - Output = polygons/masks in BEV frame: drivable corridor, risk zone around a pedestrian,
     stopping envelope, attention region. BEV frame → metric campus coordinates is a fixed
     transform, so zones are directly consumable by the planner and RViz.
3. **Meta-actions / trajectory** —
   - *Meta-actions* (DriveMA): closed vocabulary `<META_STOP>`, `<META_FOLLOW_LANE>`,
     `<META_YIELD>`, `<META_PULL_OVER>`, `<META_SLOW dv>`, … Symbolic, human-readable,
     formally checkable. **Preferred for tier 2.**
   - *Waypoints* (only for tier-3 research): either GRU adapter on final hidden state
     (BEVDriver/LMDrive) or discretized coordinate-bin tokens (SimLingo-style, e.g. 0.05 m
     bins). Never wired to actuation on the cart.

### 2.3 Runtime safety measures (tier 2 gate)

- **Deterministic verifier** (DriveMA pattern): meta-action + current zones checked against a
  formal spec — speed limits per campus zone, minimum clearances, geofence, traffic rules,
  kinematic feasibility. Rejected proposals never reach the planner; rejection is logged as
  assurance evidence.
- **Envelope containment**: whatever the LM proposes, Autoware's planner + MRM remain the
  actuation authority; LM output enters as *constraints/suggestions* (e.g., risk zone →
  virtual obstacle; meta-action → behavior request), never as raw control.
- **Completion/abstention head**: 2-layer MLP on the final hidden state (LMDrive/BEVDriver
  completion flag) generalized to an *abstain* signal: low confidence → output discarded,
  supervisor notified. Pair with `<REJ>` token semantics.
- **Consistency checks**: sample-k self-consistency on meta-actions at low temperature;
  disagreement → abstain. Cross-check LM zones against CenterPoint detections (an LM risk
  zone that contains no detected object is advisory-only; a detected object outside all LM
  zones raises a monitor flag).
- **Prompt-injection surface**: scene text (signs, clothing) can steer VLMs (SimLingo safety
  patterns, arXiv 2603.16013). Mitigation: no free-form OCR text in the prompt at tier 2;
  BEV input carries no readable text.

---

## 3. Tuning workflow

Six stages; each stage freezes what the previous one trained unless noted. LoRA (r=16–64) on
the LM throughout — full finetuning is neither affordable nor necessary (BEVDriver: LoRA r=16).

### Stage 0 — Data
- **Sim**: CARLA (LangAuto, Bench2Drive routes) + our COSS Park scenario for domain-matched
  low-speed data. LMDrive's 15k instruction sequences bootstrap instruction following.
- **Real**: `just bag record` campus drives → BEV frames + ego + (later) driver commentary.
- **Auto-labeling**: a large hosted VLM (e.g., Claude with vision) generates scene captions,
  driving QA (DriveLM-style perception→prediction→planning chains), risk-zone polygon labels
  over rendered BEV images, and counterfactuals ("what if the pedestrian steps out") —
  human-spot-checked. This is the tier-0 LM use from the assurance doc.
- **Zone ground truth**: derivable programmatically for many classes — drivable corridor from
  Lanelet2 + planner trajectory; stopping envelope from kinematics; object risk zones from
  tracked boxes + velocity extrapolation. Cheap, exact, no annotation bottleneck.

### Stage A — BEV encoder
Pretrain (or adopt) the BEV encoder on perception tasks with auxiliary losses
(detection/segmentation/traffic-light/temporal-contrastive). Freeze afterwards.
Skip if tapping Autoware's existing BEV features.

### Stage B — Modality alignment
Freeze LM + encoder; train **only the Q-Former/projector** on BEV-caption and BEV-QA pairs
(next-token CE loss). Goal: `<BEV_*>` tokens land in the LM's embedding space such that a
frozen LM can already answer coarse questions. Exit criterion: captioning/VQA above
threshold on held-out COSS scenes.

### Stage C — Driving instruction tuning (understanding)
Unfreeze LoRA on the LM (projector keeps training, lower LR). Mixed instruction data:
- driving VQA (DriveLM graph-QA, nuScenes-QA style, our auto-labeled campus QA),
- scene description / hazard identification (vision → text),
- ego-state + nav-conditioned reasoning ("you are at 2 m/s approaching a crosswalk…"),
- counterfactual QA (OmniDrive) and Action-Dreaming-style instruction conditioning (SimLingo),
- retain a general instruction-data replay slice (5–10%) against catastrophic forgetting.

### Stage D — Spatial generation (vision output)
Add `<ZONE_1..K>`, `<REJ>` to the vocabulary + mask decoder. Train decoder + new token
embeddings + LoRA jointly:
`L = L_text(CE) + λ1·L_mask(BCE + Dice over BEV grid) + λ2·L_rej(CE)`
Tasks: "draw the drivable corridor", "mark the zone you would avoid", "highlight what makes
this scene risky, then explain". Interleave with Stage C data (multi-task) so text quality
does not regress. LISA showed this works with modest data when the LM already understands
the scene — Stage C is the prerequisite.

### Stage E — Meta-actions + verifier in the loop
Add `<META_*>` vocabulary. Two phases:
1. **SFT**: imitation of meta-action sequences extracted from expert/planner logs
   (planner behavior states map ~1:1 to meta-actions — free labels from Autoware).
2. **Verifier feedback**: rejection sampling / DPO where the DriveMA-style verifier provides
   the preference signal (verified-safe + matches-expert ≻ rejected). Optionally light RL
   (GRPO) in CARLA closed loop with infraction-shaped reward. The verifier doubles as the
   runtime gate, so training distribution matches deployment gate — a clean assurance story.

### Stage F — Evaluation & staged deployment
- **Open loop**: zone IoU vs. programmatic ground truth; meta-action accuracy/abstention
  calibration; VQA benchmarks; hallucination probes (ask about absent objects — measure
  `<REJ>`/abstain rate); consistency under paraphrase and re-sampling.
- **Closed loop (sim)**: LangAuto (BEVDriver SoTA ≈ 66.7 DS short routes — our bar is not
  driving score but *infraction score* and verifier-rejection rate), Bench2Drive.
- **Cart, shadow mode** (tier 1): LM runs live, outputs displayed to supervisor + logged,
  zero actuation coupling. Collect disagreement stats vs. Autoware planner → assurance
  evidence for the tier-2 case.
- **Cart, gated mode** (tier 2): meta-actions/zones enter planner through verifier. Requires
  the tier-2 subcase from the assurance doc (theory of LM output containment) to be argued.

---

## 4. Compute & deployment notes

- Training: BEVDriver's budget was 8×A40 (encoder, 48 h) + 8×A100 (pipeline, 72 h, 15 epochs,
  AdamW + cosine). Our LoRA-only stages B–E are substantially lighter; a single 8-GPU node or
  cloud burst suffices. CARLA closed-loop eval is the wall-clock bottleneck.
- Inference on AGX Orin (JetPack 6.2): 7–8B LM with LoRA merged, INT4/INT8 (TensorRT-LLM or
  llama.cpp); BEV encoder ~5M params is negligible next to CenterPoint. Advisory tier
  tolerates 1–2 Hz LM output; the verifier and planner run at full rate regardless — LM
  latency is not on the safety path by construction.
- All new modules (projector, mask decoder, verifier, heads) are separate artifacts —
  swappable without retraining the LM core, matching the "theories as reusable modules"
  discipline of the assurance case.

## 5. Assurance hooks (evidence this workflow produces)

- Verifier rejection logs + abstention calibration → evidence for *LM output containment* theory.
- Shadow-mode disagreement statistics → evidence for tier-2 promotion.
- Hallucination/consistency probe results → defeater treatment for "LM misleads supervisor".
- Zone-vs-detection cross-check monitor → runtime safety performance indicator (dynamic case).

## 6. Open questions

1. Tap Autoware BEV features vs. dedicated encoder — decide after profiling Orin headroom.
2. K (zone codebook size) and zone taxonomy — needs the hazard workshop output.
3. Camera-view masks needed, or BEV-only zones sufficient for supervisor UI?
4. Base LM choice: open-weights 7–8B (Llama-3.1-8B, Qwen2.5-VL-7B) — Qwen2.5-VL brings
   pretrained visual grounding, may shortcut Stage B; evaluate both.

---

*References inline; survey context in
[assurance-2.0-for-autoware-llm.md](../research/safety/assurance-2.0-for-autoware-llm.md) §4.3.*
