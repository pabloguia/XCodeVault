---
name: run-experiment
description: Run one of the gating experiments E1–E11 from docs/architecture/EXPERIMENTS.md and record its evidence, matrix entry, and hypothesis status update. Use when asked to run/record an experiment or verify a hypothesis.
---

# Running a gating experiment

1. Read the experiment's section in `docs/architecture/EXPERIMENTS.md` and the hypothesis it
   gates in `docs/architecture/HYPOTHESES.md`.
2. Classify it: **read-only** (run freely), **scratch-only** (must use an `hdiutil create -fs APFS`
   disk image, never real developer data), **root-required** (needs `sudo`; if `sudo -n true`
   fails, write the exact commands into the evidence file as "pending — manual" and stop), or
   **hardware/destructive** (E6, E7, E9: implement the harness, write the manual procedure,
   mark the matrix "pending — manual", and ask the user before running).
3. Use or extend `scripts/experiments/e<N>-*.sh`, sourcing `common.sh` for the header and
   redaction. Output goes to `docs/research/evidence/e<N>-<env>.txt`.
4. Record:
   - a `COMPATIBILITY_MATRIX.md` entry using its template (date, H#, test, result, evidence
     path, functional checks, verdict, notes);
   - the hypothesis status line in `HYPOTHESES.md` (unverified → probable → verified /
     falsified) with a one-line reason and the evidence path;
   - corrections to `docs/research/FINDINGS-2026-09-05.md` under a dated "Corrections" section
     if observed behavior contradicts a desk finding;
   - an ADR if the result changes a design decision.
5. Clean up everything the experiment created on the user's disks.
6. Summarize in ≤10 lines: what was run, on what, what it proved/falsified, what it re-plans.
