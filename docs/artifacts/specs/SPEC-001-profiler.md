# SPEC-001: Plugin Analysis Capture (Parameter Grid)

Status: Draft
Date: 2026-05-26
Related ADR: ADR-001

## 1. Scope

This specification covers Phase 1 only:

- Capture broad plugin behavior data across parameter combinations
- Store data for later offline analysis
- Do not generate JSFX in this phase

Out of scope:

- DSP model fitting
- JSFX code generation
- Neural model training

## 2. Problem Statement

Single-point sweeps (fixed plugin settings) do not capture interactions between parameters. For channel-strip style emulation, we must measure how output behavior changes across multiple parameter combinations.

## 3. Goals

- Automate parameter movement for a DUT plugin
- Run analyzer sweeps at each parameter combination and input level
- Capture a normalized, analysis-friendly dataset with sufficient metadata
- Keep runtime deterministic and reproducible

## 4. System Components

1. Analyzer JSFX
- Source instance: JS: IGR_AnalyzerLab in Source mode
- Probe instance: JS: IGR_AnalyzerLab in Probe mode after DUT

2. Capture Script
- ReaScript: Reaper-Scripts/CapturePluginParameterGrid.lua
- Responsibilities:
  - Parse parameter grid definition
  - Generate Cartesian parameter combinations
  - Set DUT FX params (normalized)
  - Run sweeps at each combination and level
  - Export one consolidated CSV

3. Dataset Output
- CSV file in project directory
- One row per analyzer step event
- Includes combo metadata + measured response fields

## 5. Parameter Grid Definition

User entry format in script input:

- Param specs string: p:min:max:steps;...
- Example: 1:0:1:5;2:0:1:4

Meaning:

- Param 1 (1-based FX param index): normalized 0.0 to 1.0 in 5 steps
- Param 2: normalized 0.0 to 1.0 in 4 steps

Combination count:

- Total combinations = product of each parameter step count
- Total passes = combinations x input-level count

## 6. Capture Procedure

For each parameter combination:

1. Apply DUT parameter values (normalized)
2. For each configured input level:
  - Configure source level
  - Trigger analyzer run
  - Read probe metrics from gmem event stream
3. Append rows to in-memory dataset

At completion:

- Export consolidated CSV with dynamic param columns

## 7. Output Schema (CSV)

Core columns:

- combo_index
- combo_total
- combo_summary
- run_level_db
- nonce
- step_index
- freq_hz
- input_db
- output_db
- gain_db
- thd_db
- crest_db
- signal_type

Parameter columns (repeated by param slot):

- pN_index
- pN_norm
- pN_value

Notes:

- pN_index is original 1-based FX parameter index
- pN_norm is normalized value used to set parameter
- pN_value is raw parameter value reported by REAPER API after set

## 8. Reproducibility Requirements

- Fixed sample rate per run
- Fixed analyzer settings per run
- Persist all run settings in capture log (future enhancement)
- No manual parameter movement during automated pass

## 9. Performance and Safety Constraints

- Warn user when pass count exceeds 600
- Stop capture safely if REAPER playback stops unexpectedly (future enhancement)
- Keep analysis script independent from JSFX generation code

## 10. Immediate Deliverables

1. Reaper-Scripts/CapturePluginParameterGrid.lua
2. Dataset runs for at least:
  - One EQ plugin
  - One compressor plugin
  - One saturation plugin
3. Baseline capture report (counts, duration, data completeness)

## 11. Next Phase Entry Criteria

Move to Phase 2 (modeling/codegen) only when:

- Parameter-grid datasets exist for all three plugin classes
- No missing analyzer fields in exported rows
- Combination coverage validated against requested grid