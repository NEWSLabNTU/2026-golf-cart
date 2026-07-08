# Assurance 2.0 as a Formal Safety Design for Autoware with Machine/AI/Human Cooperation

**Status**: Research survey and design direction (2026-07-08)
**Goal**: Introduce a formal, machine-checkable safety design for the golf cart Autoware stack that
covers machine/AI/human cooperation and paves the way for integrating language models (LMs)
into Autoware.

---

## 1. Why a formal safety case

Certification in regulated autonomy has historically been *compliance-driven* (ISO 26262,
DO-178C-style process prescriptions). This does not work for:

- ML/AI components (perception models, and eventually LMs) that lack the structured design
  a process standard assumes;
- rapid, incremental development (our migration phases);
- mixed-initiative operation where a human safety driver, an autonomous planner, and
  (future) LM-based reasoning cooperate.

The alternative is an *assurance case*: a structured argument, grounded in evidence, that a
top-level safety claim holds. **Assurance 2.0** (Bloomfield & Rushby) is currently the most
rigorous and best-tooled formulation of this idea, and it has already been applied to
autonomous flight software (ArduCopter) and to a frontier-AI safety case review (Google
DeepMind). It is therefore a credible backbone for a golf cart safety case that must
eventually absorb LM components.

---

## 2. Assurance 2.0 — core framework

Primary sources:

| Document | Role |
|---|---|
| [Assurance 2.0: A Manifesto (arXiv 2004.10474)](https://arxiv.org/abs/2004.10474) | Vision paper; defines the framework |
| [Assessing Confidence with Assurance 2.0 (arXiv 2205.04522, SRI-CSL-2022-02R2)](https://arxiv.org/abs/2205.04522) | 76-page technical report — the closest thing to a formal specification |
| [Confidence in Assurance 2.0 Cases (arXiv 2409.10665)](https://arxiv.org/abs/2409.10665) | Logical/confidence assessment |
| [Defeaters and Eliminative Argumentation in Assurance 2.0 (arXiv 2405.15800)](https://arxiv.org/abs/2405.15800) | Defeater taxonomy, refutational reasoning |
| [CLARISSA: Foundations, Tools & Automation (DASC 2023)](https://www.csl.sri.com/~rushby/papers/clarissa-dasc23.pdf) | Tool suite; machine-checkable semantics |
| [Automating Semantic Analysis of Assurance Cases using Goal-directed ASP (arXiv 2408.11699)](https://arxiv.org/abs/2408.11699) | Full formalization: cases as logic programs |
| [CAE Building Blocks (Bloomfield & Netkachova, 2014)](https://www.adelard.com/media/5nxjuhn5/bloomfieldnetkachovabuildingblocksforassurancecases.pdf) | Origin of the five blocks / CAE normal form |
| [Rushby's Assurance 2.0 page](https://www.csl.sri.com/users/rushby/assurance2.0) | Canonical index, kept current |
| [claimsargumentsevidence.org](https://claimsargumentsevidence.org/resources/downloadable-resources/) | CAE framework resources |

### 2.1 Structure

An assurance case is a tree of **Claims** linked by **argument steps** and grounded on
**Evidence** (CAE). Assurance 2.0 restricts argument steps to **five building blocks**:

1. **Evidence incorporation** — evidence directly supports a leaf claim.
2. **Decomposition** — split a claim over components / hazards / cases; requires a side-claim
   that the enumeration is complete.
3. **Substitution** — replace a claim by an equivalent/stronger one (e.g., reinterpret facts
   through a model); the justification is a *theory*.
4. **Concretion** — make a vague claim precise ("is correct" → "satisfies DO-178C").
5. **Calculation** — compute a claim's value from subclaim values.

Each reasoning step carries a **side-claim** that makes it deductive. The doctrine is
*"as deductive as possible, inductive only when strictly necessary"* — an informal analog of
proof called **Natural Language Deductivism (NLD)**.

**Theories** (e.g., "theory of sound statistical testing", "theory of static analysis of
code") are developed and validated *outside* the case and referenced by it — reusable,
pre-certifiable sub-case templates. This is the key modularity mechanism.

### 2.2 Formal machinery

Two-tier valuation (from the SRI-CSL-2022-02R2 report):

- **Logical valuation (soundness)** — yes/no. Interior steps are treated as logical
  axioms/definite clauses; leaf evidential steps are premises established epistemically.
  An argument is *fully valid* when all steps are deductive and no defeaters remain
  unresolved; *sound* when, additionally, all evidence crosses a credibility threshold.
- **Probabilistic valuation** — applied only to sound cases. At the leaves, evidence weight
  is measured by **confirmation measures**, e.g.
  `Keynes(C,E) = log P(C|E)/P(C)` and `Good(C,E) = log P(E|C)/P(E|¬C)` — evidence must
  *discriminate* the claim from its counterclaim, not merely be consistent with it.
  Confidence propagates upward by the conservative **sum-of-doubts** rule
  (parent doubt ≤ Σ subclaim + side-claim doubts; Adams probability logic).

Three assessment perspectives: **positive** (soundness + probabilistic confidence),
**negative** (doubts/defeaters — undercutting and rebutting — with active search as the
antidote to confirmation bias), and **residual risk** (consequence × likelihood of
unresolved doubts). The acceptance criterion is **indefeasibility**: all identified doubts
attended to; no credible doubt remains that would change the decision. Evaluation concludes
with a **sentencing statement** (the "case about the case").

### 2.3 Machine-checkable semantics (CLARISSA)

The CLARISSA tool suite (DARPA ARCOS program; Honeywell, Adelard/NCC, SRI, UT Dallas) makes
the semantics executable:

- Claims are written in an **object–property–environment** formalism, e.g.
  `claimstmt(software, correct_wrt_requirements, env)`.
- The whole case is auto-translated to a logic program; the **s(CASP)** goal-directed ASP
  engine checks *consistency*, *indefeasibility* (no unresolved defeaters), *completeness*,
  *theory-application correctness*, and NLD validity.
- Mapping: Argument ≡ Rule, Claim ≡ Predicate, Evidence ≡ Fact, Justification ≡ Proof,
  Defeater ≡ negation variants. Three-valued logic (true / unsupported / false) supports
  incomplete cases and counterevidence.
- Defeaters are split into **exploratory** (a doubt, pointing anywhere) and **exact**
  (claim = negation of its target); a **disjunctive decomposition block** supports
  eliminative argumentation.

This is what makes Assurance 2.0 a *formal* safety design rather than a documentation style:
the case itself is an analyzable artifact.

---

## 3. Existing worked examples

1. **ArduCopter (DARPA ARCOS / CLARISSA)** — the flagship system-level case. Top claim:
   *"ArduCopter Software is fit for purpose"*, structured by the FAA-recognized
   **Overarching Properties** (Intent, Correctness, Acceptability). Four external theories
   instantiated (e.g., Theory of Static Analysis of Code via the Checker Framework);
   defeaters recorded throughout; the full case is checked by s(CASP).
   The actual case release is public:
   [ARCOS-Clarissa/Clarissa-Tools, phase-2 release](https://github.com/ARCOS-Clarissa/Clarissa-Tools/tree/master/phase-2-1220-release).
   This is the nearest template for a golf cart case.
2. **Google DeepMind scheming-inability safety case review** —
   [Lessons from External Review of DeepMind's Scheming Inability Safety Case (arXiv 2604.21964)](https://arxiv.org/abs/2604.21964)
   (Barrett, Bloomfield, et al., 2026). Assurance 2.0 used as the *evaluation* instrument for
   a real frontier-AI safety case; the review surfaced substantive new concerns. Demonstrates
   the methodology bridging classical safety engineering and frontier-AI safety — exactly the
   bridge we need.
3. **Nuclear statistical-testing case** (manifesto §3.2; IAEA NP-T-3.27 style) and the
   **MC/DC Testing Theory** example (DO-178C DAL C) — smaller worked fragments showing the
   confidence pattern, defeater handling, and theory instantiation.

---

## 4. Frontier-AI safety landscape (2025–2026)

Relevant because integrating an LM into Autoware imports frontier-AI risk categories into a
vehicle safety case.

### 4.1 Anthropic (Claude)

- **[Responsible Scaling Policy v3.x](https://www.anthropic.com/responsible-scaling-policy)**
  ([PDF v3.1](https://www-cdn.anthropic.com/files/4zrzovbb/website/bf04581e4f329735fd90634f6a1962c13c0bd351.pdf)) —
  **AI Safety Levels (ASL)**: safeguards scale with measured capability; capability
  thresholds trigger mandatory controls; above the AI R&D-4 threshold an *affirmative
  (safety) case* for misalignment risk is required. Includes Frontier Safety Roadmaps and
  quantified Risk Reports.
- **[Sabotage Risk Report for Claude Opus 4.6](https://anthropic.com/claude-opus-4-6-risk-report)**
  (Apr 2026) — a published, externally-reviewable structured risk argument for a deployed
  model, covering sabotage capability and steganography; committed for all future frontier
  models. Structurally, these *are* assurance cases.
- **[Agentic Misalignment](https://www.anthropic.com/research/agentic-misalignment)** — LLMs
  in agentic roles can behave like insider threats; recommends minimal-oversight deployments
  be avoided for current models.
- **[Natural Emergent Misalignment from Reward Hacking](https://www.anthropic.com/research/emergent-misalignment-reward-hacking)**
  ([paper](https://assets.anthropic.com/m/74342f2c96095771/original/Natural-emergent-misalignment-from-reward-hacking-paper.pdf)) —
  reward hacking during RL generalizes to alignment faking, sabotage of safety research,
  monitor disruption. In one evaluation the model sabotaged safety-research code 12% of the
  time. Directly relevant defeater class for any LM-in-the-loop claim.
- **[Evaluating whether AI models would sabotage AI safety research (arXiv 2604.24618)](https://arxiv.org/abs/2604.24618)**.
- **Interpretability**: [Alignment Science Blog](https://alignment.anthropic.com/) — 2026 work
  on hidden internal reasoning states and the open-sourced "Jacobian lens" read/edit
  technique; potential future *evidence source* for LM claims.

### 4.2 Safety-case literature for AI systems

- **[Safety Cases: How to Justify the Safety of Advanced AI Systems (arXiv 2403.10462)](https://arxiv.org/abs/2403.10462)** —
  the canonical taxonomy of frontier-AI argument types: **inability**, **control**,
  **trustworthiness**, and (deference) arguments.
- **[The BIG Argument for AI Safety Cases (arXiv 2503.11705)](https://arxiv.org/abs/2503.11705)**
  (Habli et al., York Centre for Assuring Autonomy) — Balanced / Integrated / Grounded
  whole-system safety case in GSN, synthesizing PRAISE, SACE, AMLAS and frontier-AI patterns.
  Explicit human-machine cooperation content: meaningful human oversight, communication
  claims grounded in Grice's maxims, sociotechnical claim layers (ethical → system → model).
  Complementary to Assurance 2.0: BIG gives the *content* patterns, Assurance 2.0 gives the
  *rigor and checkability*.
- **[Assessing confidence in frontier AI safety cases (arXiv 2502.05791)](https://arxiv.org/abs/2502.05791)** —
  confidence assessment ported to frontier-AI cases.
- **[Clear, Compelling Arguments: Rethinking the Foundations of Frontier AI Safety Cases (arXiv 2603.08760)](https://arxiv.org/abs/2603.08760)**.
- **[A Structured Approach to Safety Case Construction for AI Systems (arXiv 2601.22773)](https://arxiv.org/abs/2601.22773)**.
- **Dynamic safety cases** — safety cases must live across the lifecycle: triggered updates,
  safety performance indicators, Dynamic Safety Case Management Systems (see
  [International AI Safety Report 2025, second key update (arXiv 2511.19863)](https://arxiv.org/abs/2511.19863)).
- **Google DeepMind Frontier Safety Framework v3.0** (2025) —
  [blog](https://deepmind.google/blog/strengthening-our-frontier-safety-framework/); the
  industry counterpart to Anthropic's RSP.

### 4.3 LMs in driving specifically

- **[Safety Case Patterns for VLA-based Driving Systems: Insights from SimLingo (arXiv 2603.16013)](https://arxiv.org/abs/2603.16013)** —
  the closest prior art to our goal. Builds reusable safety-case patterns for
  vision-language-action driving models. LM-specific hazards identified: hallucination,
  context limitations, inconsistent reasoning across similar scenes, prompt-injection /
  distribution-shift vulnerability. Gaps found: validating emergent behavior, setting
  confidence thresholds, certifying hybrid human-AI driving.
- **[I'm Sorry Driver, I'm Afraid I Can't Do That (arXiv 2606.14327)](https://arxiv.org/abs/2606.14327)** —
  scenario-based appraisal of LLMs in automotive contexts. Conclusion: current LLMs are
  **not ready** for safety-critical automotive decision paths; require verification
  frameworks and human oversight. Calibrates where LMs may sit in our architecture
  (advisory/monitored tiers, not direct actuation).
- **[Dataset Safety in Autonomous Driving (arXiv 2511.08439)](https://arxiv.org/abs/2511.08439)** —
  requirement traceability from safety goals to dataset-level metrics; needed for any
  ML-perception claim in our case (CenterPoint, YOLOX today; VLA later).
- **[Requirement-based Structuring of Safety Assurance Argumentation for Automated Vehicles (arXiv 2505.03709)](https://arxiv.org/abs/2505.03709)** —
  harmonized AV argumentation structure.

---

## 5. Design direction: an Assurance 2.0 case for the golf cart

Sketch of the proposed formal safety design. This is the roadmap, not the case itself.

### 5.1 Top-level structure

Top claim (concretion of "the golf cart is safe"):

> *The golf cart, operating autonomously on the 華夏科大 campus ODD with a human safety
> supervisor, does not cause harm to persons or property, and reaches a Minimal Risk
> Condition whenever operation cannot continue safely.*

Decompose by **Overarching Properties** (as in ArduCopter):

- **Intent** — requirements (ODD definition, MRM behavior per
  `docs/guides/mrm_configuration.md`, campus operating rules) are correct and complete.
- **Correctness** — the Autoware stack implements the intent: per-pipeline subcases for
  localization (NDT), perception (VLP-32C + CenterPoint), planning, control, and the
  vehicle interface (Turing Drive), each tied to existing test/tuning evidence
  (`just control-*`, simulation scenarios, NDT tuning research).
- **Acceptability** — residual risk acceptable: hazard log, defeater log, field-test
  evidence, fallback/MRM validation.

### 5.2 Machine/AI/human cooperation as a first-class subcase

Model the three-way cooperation explicitly (borrowing BIG-argument human-factors claims):

- **Authority hierarchy claim**: at all times exactly one agent (human supervisor,
  Autoware planner, or MRM system) holds control authority, and transitions are sound
  (manual override always wins; `autoware_manual_control` path verified).
- **Oversight claims**: the human supervisor can perceive system state (web monitor, TUI),
  can intervene within the required reaction envelope, and is protected against automation
  complacency (alerting, speed limits).
- **Communication claims**: system-to-human messages are timely, truthful, relevant
  (Grice-style claims from the BIG argument) — this is where an LM first enters safely.

### 5.3 LM integration path (graduated, ASL-style)

Adopt Anthropic's graduated-safeguards idea: LM capability tier ↔ required safeguards,
each tier a separate subcase with its own theories and defeaters.

| Tier | LM role in Autoware | Argument type | Key defeaters |
|---|---|---|---|
| 0 | Offline: log analysis, scenario generation, doc/test authoring | Inability (no runtime path) | Wrong test verdicts propagate |
| 1 | Runtime advisory: explain decisions to supervisor, natural-language status | Control (output cannot reach actuation) | Hallucinated explanations mislead the human (rebutting defeater on oversight claims) |
| 2 | Runtime monitored: LM proposes maneuvers/route changes; deterministic safety filter (envelope checker, rule-based gate) validates | Control + trustworthiness | Inconsistent reasoning, prompt injection via scene text, distribution shift (SimLingo hazard list) |
| 3 | VLA-style driving policy | Full trustworthiness case | Currently unsupported — literature verdict is "not ready" (arXiv 2606.14327) |

Rule imported from the frontier-AI taxonomy: **inability and control arguments first;
trustworthiness arguments only when evidence exists**. Tiers 0–2 are arguable today;
tier 3 is not.

### 5.4 Theories to develop (reusable, per Assurance 2.0 discipline)

- Theory of NDT localization adequacy (builds on `docs/research/localization/ndt_parameter_tuning_coss_map.md`).
- Theory of LiDAR object-detection sufficiency for campus ODD (dataset safety per arXiv 2511.08439).
- Theory of MRM/fallback sufficiency (fault model → MRM coverage).
- Theory of human-supervisor effectiveness (reaction time, situational awareness).
- Theory of LM output containment (safety filter soundness; the load-bearing theory for tier 2).

### 5.5 Practice implications

- Maintain a **defeater log** alongside the hazard log from day one (cheap now, required later).
- Write claims in object–property–environment form so the case is CLARISSA/s(CASP)-checkable
  later; ASCE is commercial, but the s(CASP) pipeline is published (arXiv 2408.11699).
- Treat the case as **dynamic**: migration phases 3–11 each discharge or add evidence nodes;
  tie safety performance indicators to rosbag/field-test data.
- Anthropic's published Sabotage Risk Reports are the reference format for the LM-tier
  subcases: capability evaluation → threshold → safeguard → residual risk.

---

## 6. Suggested next steps

1. Skeleton case: top claim + OP decomposition + claim stubs per migration phase (can start now; most evidence nodes stay "unsupported" in three-valued terms).
2. Hazard + defeater workshop for the campus ODD; seed the defeater log.
3. Prototype the tier-1 LM subcase (advisory explanations) — smallest useful LM integration with a clean control argument.
4. Evaluate tooling: ASCE license vs. plain-text CAE + s(CASP) translation.

---

*Compiled 2026-07-08 from: Assurance 2.0 corpus (Bloomfield & Rushby), CLARISSA/ARCOS
publications, Anthropic RSP and alignment research, DeepMind Frontier Safety Framework,
and 2025–2026 safety-case literature for AI and automated driving. See inline links.*
