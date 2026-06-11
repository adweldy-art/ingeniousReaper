---
id: ADR-001
status: Accepted
date: 2026-05-26
author: AgentX (Architect phase)
title: Plugin Profiler & DSP-First Emulation for REAPER Channel Strip
---

# ADR-001: Plugin Profiler & DSP-First Emulation for REAPER Channel Strip

**Status**: Accepted  
**Date**: 2026-05-26  
**Author**: AgentX (Architect phase)  
**PRD**: (See context below)  
**Next Phase**: UX/Engineer phase (profile extraction & codegen)  

---

## Table of Contents

1. [Context](#context)
2. [Decision](#decision)
3. [Options Considered](#options-considered)
4. [Rationale](#rationale)
5. [Consequences](#consequences)
6. [Implementation](#implementation)
7. [Test Plugin Roadmap](#test-plugin-roadmap)
8. [References](#references)

---

## Context

**Goal**: Build a tool to analyze VST plugins (EQ, compression, saturation) and generate equivalent JSFX emulations for use as a channel strip in REAPER.

**Requirements**:
- Analyze VST plugin behavior across frequency, amplitude, and time domains
- Extract plugin characteristics in a machine-readable profile format (JSON)
- Generate parameterized JSFX code that matches plugin output at >80% fidelity
- Support composable channel strip (multiple emulated effects in series)
- Allow user tweaking of extracted parameters
- Enable A/B testing (original plugin vs. emulated JSFX)

**Constraints**:
- REAPER Lua/JSFX runtime only (no external DSP libraries)
- Real-time performance (<5% CPU per effect at 48kHz)
- Deterministic behavior (reproducible across sessions)
- User wants 100% DSP solution to start (no neural complexity initially)

**Background**:
- Existing IGR_AnalyzerLab.jsfx can sweep plugins at multiple frequencies/amplitudes
- Lua ? JSFX gmem bridge already working (AutoGainStageToJSFX.lua)
- NAM (Neural Amp Modeler) offers insights but overkill for VST plugin emulation
- Plugin emulation is deterministic (VST already runs offline/known code) unlike hardware modeling

---

## Decision

We will build a **DSP-first plugin profiler and emulation framework** that:

1. **Captures plugin profiles** using frequency sweeps + amplitude analysis
2. **Extracts deterministic parameters** (filters, saturation curves, gain staging)
3. **Generates parametric JSFX** from profiles (EQ, compression, saturation templates)
4. **Supports composition** (load multiple emulated effects into a channel strip)
5. **Enables progressive enhancement** (add neural residual layer later if fidelity <80%)

**Key architectural choices**:
- Profile format: JSON (human-readable, version-safe)
- Analysis engine: Python (plugin_profiler.py) running offline
- Code generation: Template-based JSFX codegen (profile_to_jsfx_generator.py)
- Deployment: Auto-copy to REAPER resource paths (C:\Users\Adam\AppData\Roaming\REAPER\Effects\ingeneousWiz)
- Testing: A/B comparison rig in REAPER with error scoring

---

## Options Considered

### Option 1: DSP-First (SELECTED)

**Description**:
Extract plugin parameters via analysis (frequency response, saturation curve, compression ratio/threshold, delay). Generate JSFX as parametric DSP chains. No machine learning.

**Pros**:
- Zero training time (pure analysis + parameter fitting)
- Fully transparent and auditable (user can tweak parameters)
- Composable (mix/match extracted effects)
- Deterministic (bit-bit reproducible)
- Low CPU overhead in REAPER
- Suitable for VSTs (which are already deterministic code)

**Cons**:
- Limited fidelity on complex feedback/modulation (reverbs, delays, analog emulations)
- Requires hand-crafted DSP templates per effect type
- May not capture subtle harmonic interactions

**Effort**: M  
**Risk**: Low

---

### Option 2: Lightweight Neural (Hybrid)

**Description**:
Train small feedforward network on captured plugin behavior. Export weights + inference stub. DSP handles 80%, neural handles 20% (residual error).

**Pros**:
- Higher fidelity (90%+) than pure DSP
- Captures nonlinear feedback and modulation
- Training fast (10-30 min)
- Neural layer only corrects what DSP misses

**Cons**:
- Adds training/export complexity
- Neural inference adds 2-3% CPU in REAPER
- Export format not yet standardized (ONNX too heavy)
- Requires LSTM or RNN (stateful inference harder in JSFX)
- Overkill for EQ and compression (well-modeled by DSP)

**Effort**: L  
**Risk**: Medium

---

### Option 3: Pure Neural (WaveNet-style)

**Description**:
Train large WaveNet on full plugin audio. Export to .nam format (like NAM) or ONNX. Real-time playback.

**Pros**:
- Highest fidelity (95%+)
- Captures any plugin behavior (black box)
- Proven (NAM project does this)

**Cons**:
- Training time: 2-8 hours per plugin
- CPU overhead: 10-20% per effect (unsustainable for channel strip)
- Heavy dependencies (PyTorch, inference frameworks)
- Not suitable for REAPER JSFX (would need VST wrapper)
- Overkill for VSTs (non-analog, already deterministic)
- User explicitly asked for "100% DSP for now"

**Effort**: XL  
**Risk**: High

---

### Option 4: Lookup Table (LUT) Interpolation

**Description**:
Sample plugin output on a fine grid of (frequency, amplitude, phase) points. Store as binary LUT. Runtime interpolates between grid points.

**Pros**:
- High fidelity (90%+) without training
- Fast inference (2-3 table lookups)
- Arbitrary plugin behavior capture

**Cons**:
- Large storage (~5-50MB per plugin)
- No user parameter tweaking (black box)
- Interpolation artifacts at grid boundaries
- Overkill for EQ/compression (well-modeled analytically)

**Effort**: M  
**Risk**: Low

---

## Rationale

We chose **Option 1 (DSP-First)** because:

1. **Alignment with use case**: VST plugins are deterministic software, not analog hardware. Extract parameters analytically rather than black-box model.

2. **User preference**: Explicitly requested "100% DSP for now" and "undecided on neural" pending feasibility data.

3. **Composability**: Channel strip use case requires mixing/matching effects. DSP chains are composable; neural models are black boxes.

4. **Transparency**: User can understand, tweak, and improve the generated JSFX. Supports iterative refinement.

5. **Fast iteration**: No training pipeline needed. Profiler ? JSON ? JSFX codegen cycle can be completed in hours.

6. **Fallback path**: If DSP achieves >80% fidelity, launch. If gaps remain, add neural residual layer (Option 2) without rearchitecting.

7. **Low risk**: Pure DSP is well-understood. Failures are easy to debug (compare frequency response, saturation curves, delay).

**Key decision factors**:
- Plugin emulation != hardware emulation (no unmeasured physics)
- User requested deterministic DSP, not AI complexity
- Channel strip use case requires composability
- Fast iteration > perfection initially

---

## Consequences

### Positive
- **Fast MVP**: Profiler + codegen in 3-4 weeks (vs. 8+ weeks for neural pipeline)
- **Transparent**: User owns the generated JSFX; can inspect, audit, and tweak
- **Composable**: Effects can be loaded in any order; parameters are independent
- **CPU efficient**: Parametric DSP runs in <2% CPU per effect
- **Reproducible**: Same plugin profile always generates same JSFX
- **Extensible**: Add neural residual layer later without breaking DSP foundation

### Negative
- **Limited fidelity on feedback/modulation**: May struggle with reverbs, delays, or complex dynamics (not in scope for Phase 1)
- **Manual template creation**: Each effect type (EQ, compressor, saturation) needs a DSP template (effort: 1-2 weeks)
- **Parameter extraction error**: If analysis doesn't capture plugin behavior accurately, fidelity suffers
- **No adaptive learning**: Unlike neural approaches, can't generalize across plugins (each needs custom template)

### Neutral
- **New dependency**: Python profiler (profile_to_jsfx_generator.py) added to build pipeline
- **Template versioning**: JSFX templates become source code to maintain
- **User education**: Users need to understand parameter extraction trade-offs

---

## Implementation

**Detailed technical specification**: docs/artifacts/specs/SPEC-001-profiler.md (to be created)

**High-level implementation plan**:

`
Phase 1: Profile Extraction (2 weeks)
  1. Refine IGR_AnalyzerLab to capture plugin metrics:
     - Frequency response (magnitude/phase sweep)
     - Amplitude sensitivity (gain vs. input level)
     - Harmonic distortion (THD curves)
     - Dynamic range analysis (compression/expansion)
  2. Build plugin_profiler.py (Python)
     - Read sweep data from audio files
     - Extract parameters (filter Q/gain, saturation curve, compressor ratio/knee, delay)
     - Output JSON profile
  3. Validate with 1 reference plugin (e.g., stock REAPER EQ)
  4. Deliverable: Profile JSON + Python profiler script

Phase 2: JSFX Code Generation (2 weeks)
  1. Build profile_to_jsfx_generator.py
     - Read JSON profile
     - Choose effect template (EQ, compressor, saturation)
     - Substitute extracted parameters into template
     - Output .jsfx file
  2. Create DSP templates (JSFX source):
     - TEMPLATE_EQ.jsfx (parametric filter)
     - TEMPLATE_COMPRESSOR.jsfx (soft-knee compressor)
     - TEMPLATE_SATURATION.jsfx (waveshaper + tone)
  3. Test codegen on reference profiles
  4. Deliverable: JSFX templates + Python codegen

Phase 3: A/B Testing & Validation (1.5 weeks)
  1. Build Reaper test rig (Lua script)
     - Load original plugin + emulated JSFX in series
     - A/B switch with audio bypass
     - Measure error (FFT diff, THD variance, RMS error)
  2. Profile 3 reference plugins (EQ, compression, saturation)
  3. Generate 3 JSFX emulations
  4. Run blind A/B tests; score fidelity
  5. Adjust parameter extraction if fidelity <80%
  6. Deliverable: A/B test results + 3 working JSFX emulations

Phase 4: Channel Strip Orchestration (1 week)
  1. Build Lua channel strip loader
     - Load multiple emulated effects in series
     - Expose parameters to REAPER UI
     - Save/recall presets
  2. Deploy to REAPER resource paths
  3. Create user tutorial (how to profile & generate your own)
  4. Deliverable: Channel strip JSFX + example presets

Total MVP timeline: ~5 weeks (can compress to 3-4 with parallel work)
`

**Key milestones**:
- **Milestone 1** (Week 2): Profile extraction working on reference plugin; JSON profile generated
- **Milestone 2** (Week 4): JSFX codegen produces working effect; EQ emulation matches reference
- **Milestone 3** (Week 5): A/B tests pass; fidelity >80% for 3 effect types
- **Milestone 4** (Week 6): Channel strip deployed; user tutorial complete

---

## Test Plugin Roadmap

**Phase 1 (MVP) test plugins** — representative of channel strip stages:

| Plugin | Category | Why | Profile Extracts |
|--------|----------|-----|------------------|
| **Stock REAPER ReaEQ** (or FabFilter Pro-Q / Waves SSL) | EQ | Foundational; well-understood filtering | Filter type, center freq, Q, gain at each band |
| **Stock REAPER ReaComp** (or Waves CLA / FabFilter Pro-C) | Compression | Dynamic glue; standard compressor topology | Threshold, ratio, attack, release, knee, makeup gain |
| **Softube Saturation / Waves Saturator / Stock Distortion** | Saturation/Distortion | Character; nonlinear stage | Input gain, saturation curve (Sigmoid/Tanh), output tone (LPF cutoff) |

**Future plugins** (Phase 2+):
- Multiband compressors (extract per-band profiles)
- Reverbs/delays (use LUT approach; too complex for parametric)
- Analog modelers (combine parametric DSP + neural residual)

---

## References

- **NAM (Neural Amp Modeler)**: https://github.com/sdatkinson/neural-amp-modeler (reference architecture for profile/training, not directly adopted)
- **Existing JSFX analyzer**: [IGR_AnalyzerLab.jsfx](IGR_AnalyzerLab.jsfx)
- **Existing automation**: [AutoGainStageToJSFX.lua](AutoGainStageToJSFX.lua)
- **REAPER gmem bridge**: @init / gmem[] communication pattern
- **DSP references**: Filter design (RBJ), saturation (Sigmoid/Tanh), compression topology

---

## Decisions Deferred (Future ADRs)

1. **ADR-002**: Neural residual layer design (if DSP fidelity <80% and worth pursuing)
2. **ADR-003**: Preset sharing / community plugin library
3. **ADR-004**: Real-time plugin analysis (live profiling while VST runs in REAPER)
4. **ADR-005**: LUT-based emulation (if multiband or reverb support needed)

