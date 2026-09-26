---
name: run-experiment
description: Run one of the gating experiments from docs/architecture/EXPERIMENTS.md (E1 onward) and record its evidence, matrix entry, and hypothesis status update. Use when asked to run/record an experiment or verify a hypothesis.
---

# Running a gating experiment

1. Read the experiment's section in `docs/architecture/EXPERIMENTS.md` and the hypothesis it
   gates in `docs/architecture/HYPOTHESES.md`.
2. Classify it, and **do not classify from the experiment number — classify from what the script
   actually does.** The table below was built by reading all 19 scripts on 2026-09-18, because an
   earlier version of this step named three experiments as destructive and was wrong in both
   directions: two of the three are scratch-only, and it missed six that touch the user's real
   environment.

   | Class | What it means | Scripts |
   |---|---|---|
   | **read-only** | Observes; changes nothing. Run freely. | `e1`, `e8`, `e14a` |
   | **scratch-only** | Creates its own `mktemp` set or `hdiutil` image and destroys only that. | `e1b`, `e2`, `e11`, `e12`, `e14b-control-internal`, `e18` |
   | **guarded, on a volume you name** | Writes to a real external volume the caller passes, behind `--i-understand` and a containment guard that refuses anything under `Library/Developer`, anything not under `/Volumes/<vol>/`, and any parent not on the volume's own device. Safe by construction, not by scratch. | `e14b-device-set-external`, `e14c` |
   | **root-required** | Needs `sudo`. If `sudo -n true` fails, write the exact commands into the evidence file as "pending — manual" and stop. | `e4b`, `e13` |
   | **destructive** | Mutates the user's real environment. **Ask before running, every time.** | `e6`, `e6c-item4-attach-owner`, `e8b`, `e8c`, `e9`, `e13b`, `e15` |

   Why each destructive one is destructive, so the list can be checked rather than trusted:

   - `e8c` and `e9` call `simctl create`, `boot` and `delete` with **no `--set`**, so they act on the
     **default device set** — the one the machine's own test rigs use. Before running either, follow
     the repository rule: `pgrep -fl xcodebuild`, `xcrun simctl list devices`, and name the device
     you are about to touch.
   - `e9` additionally creates the symlink over `~/Library/Developer/CoreSimulator` that safety rule
     7 forbids as a product strategy. It exists to test that prohibition, and it is the one script
     that deliberately builds the layout the product refuses.
   - `e8b` and `e15` `defaults write` / `defaults delete` real `com.apple.dt.Xcode` keys
     (`IDECustomDerivedDataLocation`, `DVTSimulatorSetLocation`). Both restore on exit, but an
     interrupted run leaves the user's Xcode pointing somewhere else.
   - `e6` force-unmounts a mounted volume and removes an archive tree.
   - `e6c-item4-attach-owner` detaches and re-attaches the disk image named on its command line three
     times (as the operator and as root) and tries to leave it attached by the operator on every exit
     path. It never force-unmounts. Its cells mount only at a control directory it creates; its user
     re-attaches mount the image at its default location under `/Volumes`.
   - `e13b` runs as root under `/Library/Developer`. It is gated behind `--i-understand` and
     `--delete`, which is why it is last on this list rather than first — but it is still a root
     delete.

   A `--set`-scoped `simctl` call is scratch; a bare one is not. That distinction is the whole
   difference between the second and fourth rows.

3. Use or extend `scripts/experiments/e<N>-*.sh`, sourcing `common.sh` for the header and
   redaction. Evidence goes to `docs/research/evidence/`, under one of two naming conventions
   already in use: `e<N>-<env>.txt` (preferred — the environment slug from `xcv_env_slug`) or
   `e<N>-<what>-<timestamp>.txt`. Match whichever the experiment's existing files use.
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
