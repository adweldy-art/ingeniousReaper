# ADR-001 Planning Session Complete

## Decision Accepted
- **DSP-First** approach for plugin profiler + emulation framework
- Channel strip use case: EQ, Compression, Saturation
- Test plugins: ReaEQ, ReaComp, Stock Distortion (or equivalents)
- Phase 1 target: Profile extraction + JSON export (2 weeks)

## Key Findings
- VST plugins are deterministic (software), not hardware ? DSP extraction is efficient
- User prefers 100% DSP initially; neural as optional Phase 2+ enhancement
- Composable channel strip requires parametric effects, not black-box models

## Architecture Layers
1. **Analysis**: IGR_AnalyzerLab.jsfx (sweep) ? plugin_profiler.py (extract params)
2. **Profile**: JSON format (human-readable, versionable)
3. **Codegen**: profile_to_jsfx_generator.py ? parametric JSFX templates
4. **Testing**: A/B rig in Reaper + fidelity scoring (target >80%)
5. **Deployment**: Auto-copy to REAPER resource paths

## Timeline (5 weeks MVP)
- Week 1-2: Profile extraction (Python profiler + analyzer refinement)
- Week 2-3: JSFX codegen + DSP templates (EQ, compressor, saturation)
- Week 3-4: A/B testing + fidelity validation
- Week 4-5: Channel strip orchestration + user tutorial

## Decisions Deferred
- Neural residual layer (ADR-002 if fidelity <80%)
- Community plugin library (ADR-003)
- Real-time profiling (ADR-004)
- LUT emulation for reverbs (ADR-005)

## Next Action
? Create SPEC-001 (technical specification for profile extraction)
? Start Phase 1 engineering (profiler development)
