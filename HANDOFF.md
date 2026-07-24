# ScanSnap S1500M → SANE pipeline handoff

## Goal
Replace ScanSnap Manager (dies with macOS Tahoe upgrade) with a shell pipeline
(`scan.sh`) whose output matches ScanSnap Manager quality: color fidelity,
deskew, crop-to-paper, per-page orientation, OCR. Test corpus: 7 checks,
duplex, 14 pages. Reference output: `scansnap-checks-2026-07-22_pdf.pdf`.

## Status (2026-07-23): VALIDATED — user judges output "at least as
## good as or better than scansnap" across all three document classes:
## checks (checks-v7-fixed.pdf), brightener-blue text docs
## (s4-fixed-v4.pdf), and colored/yellow stock (kearny.pdf vs
## ~/Documents/2026-Scans/scansnap-kearny.pdf — auto-gate correctly
## declined whitening, warm paper preserved, no flags).

## Status (2026-07-22, v7): WORKING
All 14 corpus pages crop cleanly (no bg strips, no shadow bands, dark and
pale checks both intact), duplex pairs agree within ~13px, orientation is
deterministic and correct on every page. `newscan-v7.pdf` built from the
saved corpus raws. Remaining known deviations, judged acceptable:
- p10-type backs (text in BOTH directions: sideways endorsement + upright
  security boilerplate) come out landscape — the per-page OCR evidence
  genuinely favors it. ScanSnap made them portrait. User hasn't ruled.
- ~4-8px pale sliver on one edge of some backs (penumbra the 4px shave
  doesn't fully cover). Sub-millimeter; invisible at document scale.
- Edge-metric "blue" flags on p1/p3/p11 S/W edges are FALSE alarms — the
  checks' own blue-gray/green paper tint trips the B−R metric. Verified
  visually clean.
- CAPTURE-LEVEL clipping (user-reported on Worcester, Walton, Wilmington,
  Peachtree-back, Pawtucket): corners/edges of full-letter-width checks
  cut off. Verified present in the RAW pnm frames themselves — the S1500
  scan window is exactly 8.5" wide starting at the detected leading edge,
  with NO overscan option in the fujitsu backend (-t min 0, -x max
  215.872mm; checked scanimage -A). A full-width doc fed with ~1° skew
  geometrically loses a corner at digitization. NOT fixable in software;
  fix is mechanical (snug side guides, straight feed). Do NOT try to
  recover it by reducing the -shave 10x10: tested, only gains ~0.5mm and
  the 6px content shift flips the p2 rotation vote below the gate and
  misfires p13's top trim (banner eaten). Reverted.
  User-verified 2026-07-22: a deliberately skewed Worcester scanned by
  ScanSnap Manager (Documents/2025-Scans/scansnap-worcester.pdf) clips
  the same letters — SS just paints the bg white, which step 2d now
  replicates. SIDE clipping is now fixed by the widened scan window
  (see step 1); only the leading-edge (top-corner) clip remains, and
  only for skewed feeds. Capture cannot start before the feed: line
  sensor (rows exist only while paper moves), frame start is a firmware
  edge-trigger, no --overscan on this model, and ScanSnap Manager
  clips identically. Workarounds for precious/skew-prone docs: carrier
  sheet (sleeve edge takes the trigger, doc sits below it), or feed
  bottom-first (trigger loss lands on the blank bottom margin; the
  per-page orientation vote auto-rotates the result).

## Current pipeline (scan.sh, single self-invoking script)
1. `scanimage -d fujitsu --source 'ADF Duplex' --resolution 300 --mode Color
   --page-width=221.121 -x 221.121 --buffermode On --format=pnm` — RAW
   full frame, NO `--swcrop`/`--swdeskew`. The maxed page-width widens
   the window from 8.5" to 221.1mm (2612px) and the S1500 hardware
   DELIVERS real pixels there (verified on a deliberately skewed feed:
   recovered both side edges of a letter-width check, 2547x1050 full
   capture). ADF centering splits the extra ~2.6mm per side. Page-HEIGHT
   maxing was evaluated and rejected: it only extends past the trailing
   edge (up to 876mm — slow, huge frames) and cannot recover top-corner
   clip, since capture starts at the leading-edge trigger (-t min 0).
2. Per page in parallel (xargs re-invokes `scan.sh --process-page`):
   a. bg = per-head CALIBRATED CONSTANT (odd pages/front head
      rgb(176,194,197) lum 189, even/back rgb(188,205,208) lum 200;
      override SCANNER_BG_FRONT/SCANNER_BG_BACK). Do NOT auto-measure
      per frame: v7 originally measured the bottom 15% strip, which a
      full-height letter page COVERS — bg read as white paper, blue bg
      margins un-keyed and whitening aimed at paper (the s.pdf
      blue-border bug, found 2026-07-22). Head calibration is stable
      within ~2 units across every batch measured; keying fuzz absorbs
      the drift.
   b. `magick -background rgb($bg) -deskew 40% +repage -shave 10x10` —
      BUT only if the page has ≥0.2% dark pixels (50% gray threshold).
      -deskew needs dark features; on a featureless blank duplex back
      (fold creases don't survive the threshold) it latches onto noise
      and rotated a STRAIGHT page ~5° (s3.pdf p2). Featureless pages
      instead use their duplex sibling's angle NEGATED (same physical
      sheet; corpus pairs agree to ~0.15°; `-rotate <angle>` verified
      == -deskew at RMSE 0.007), or 0° if the sibling is also
      featureless. |sibling angle|>3° → 0 (ADF can't skew that much).
      Every corpus page is ≥0.46% dark → all stay on the bit-exact
      -deskew path.
   c. Paper location via row/column profiles (profile_bounds in scan.sh):
      two profiles per axis from one keyed image — non-bg fraction
      (fuzz 6% off measured bg) and masked luminance (bg painted black;
      mlum = maskedlum/frac = true mean lum of non-bg pixels per line).
      * bounds: outermost lines with >20% non-bg, 2-consecutive required.
      * shadow trim: trailing paper edge casts a shadow ramp + a DEEP
        trench (mlum 57–65) at the paper edge line. Find darkest line
        within 70 of the bbox edge; real trench iff < base−60 AND nothing
        between it and the bbox edge reaches bglum (a dark PRINTED border
        has bright margin outside → vetoed; fade-tail lines with <30%
        non-bg never veto). Cut at trench, walk inward to first line
        ≥ base−12 (≤25 lines else revert). base = min(bglum, interior
        median mlum) so dark-stock pages don't sit wholly below the floor.
      * frame-boundary sides (lo≤2 / hi≥n−3) never trimmed (no bg beyond
        → no shadow possible; protects dark paper cropped at the frame).
   d. Crop + `-shave 4x4` + tone `-level 3%,88% -unsharp 0x1+0.6+0.02`
      (`--clean` swaps blur/divide flattening — text docs only) → the
      ORIENTATION-SCORING image. Bg whitening is NOT in this image:
      whitening jitter (even a 1-unit bg shift repaints different
      pixels) moves tesseract scores ~20% and flipped p2's rotation
      below the gate. The final encode (step 2f) redoes the same crop
      from the deskewed frame WITH whitening (`-fuzz 4% -fill white
      -opaque rgb($bg)`, raw domain, before tone) — deskew wedges at
      capture-clipped corners and shadow tails render white, matching
      ScanSnap's look (user-confirmed vs scansnap-worcester.pdf: SS
      clips skewed edges identically but paints bg white). 4% ≈ 3 sigma
      of bg; palest corpus paper is ~7% away — no whitening holes in
      Worcester (palest) or Pawtucket (darkest).
   e. Orientation: 4-way OCR vote on ≤2200px render, STRICTLY per-page.
      Score = sum of confs of words with conf≥60, len≥3, alnum, capped at
      30 words (high-conf-only: correct orientation wins 2.7–9×, vs ~1.4×
      with the old mean-conf metric). Gate: best ≥ 400 AND ≥ 1.8×second,
      else no rotation. `OMP_THREAD_LIMIT=1` on tesseract for determinism
      (multithreaded tesseract is nondeterministic under parallel load —
      caused vote flicker across identical runs).
3. `img2pdf` → `ocrmypdf --optimize 1 --jpeg-quality 90` (NO --rotate-pages,
   NO --deskew).

Env: `DEBUG=1` keeps temp dir + prints per-page bounds/orient lines and
keeps stage PNGs; `BG_FUZZ` (default 6%). Temp dirs now under `work/`
(user: NEVER use /tmp — everything stays in the project tree).

## Debug tooling
`work/debug.sh <section>` — user-authorized script; must never touch
anything outside the project tree. Sections: `run` (re-process saved
corpus raws in work/scan-v5-debug → work/v7-test, prints bounds+orient+
sizes), `edges` (blue-pixel fraction per edge strip — beware false
positives on blue/gray paper), `runedges`, `pdf` (build newscan-v7.pdf),
`strips` (magnified edge crops), `dual`/`cols3`/`png2`/`samples`/`scores`
(profile dumps, color samples, orientation score experiments).
Corpus raws: `work/scan-v5-debug/raw_0{01..14}.pnm` — 14 real duplex
frames; everything above was tuned against them without rescanning.

## Hard-won facts (do not re-learn these)
- SANE fujitsu `--swcrop` crops to CONTENT not paper; `--swdeskew` partial.
  Both abandoned.
- Raw frames are 2550x3300 (letter @300dpi). 1–2px artifact rim around the
  frame perimeter → shave 10 after deskew.
- Shadow anatomy at a trailing paper edge (measured): outer tail hugging
  bg level (as little as 1 unit below bg — any absolute darkness threshold
  stalls there), steep trench to mlum 57–65 AT the paper edge, sharp jump
  to paper. The tail is within 6% fuzz of bg for shallow shadows (keys
  out) but NOT for deep ones (p1). Trench depth is the only reliable
  landmark; its absence (p3 sides) means the bbox already sits at the edge.
- Pale-green check body (Niobrara) mlum ≈ 181–195 — OVERLAPS bg lum 189
  and sits below bg+10: brightness-only cropping cuts 130 rows of real
  paper. Color-distance keying is the only signal that finds its edges.
- Dark-stock check (Pawtucket, body mlum ≈ 150) sits wholly below
  bglum−12: absolute floors turn edge walks into content cuts; the
  interior-median-relative base fixes it.
- Dark PRINTED borders (ornate frames ~15–20px inside the paper edge)
  mimic the trench; the bright-margin-outside veto is what tells them
  apart. p3's bottom border+margin is genuinely in deep penumbra
  (mlum 59–130 for 30px) — cutting ~20px there is unavoidable and fine.
- Tesseract orientation voting: mean-conf metric gives only ~1.3–1.5×
  separation (flip-prone); high-conf-word-sum gives 2.7–9×. Scoring
  resolution matters: 1600px too small for sparse handwriting backs
  (p2 fails gate), 2200px sweet spot, native 2522px WORSE (90° garbage
  score inflates). OMP_THREAD_LIMIT=1 changes tesseract results (worse
  on some pages) but is required for determinism — gate calibrated
  against single-threaded scores.
- JPEG q90 compression slightly IMPROVES tesseract confidence vs PNG on
  these scans (smoothing) — don't compare scores across formats.
- Tone target (from ScanSnap ref): paper bg ≈235 fronts / 243 backs,
  mid-tone saturation ≈33. `-level 3%,88%` lands ≈235/31.
- Original bug (fixed): relative OUTPUT_PDF written inside TMP_DIR then
  deleted by cleanup — path made absolute up front.

## Next steps
1. Fresh end-to-end validation: load the 7 checks, `DEBUG=1 ./scan.sh
   out.pdf`, confirm a clean run scan→PDF (v7 logic has only been run
   via work/debug.sh against saved raws; the scanimage step last ran
   under v5 logic).
2. Compare against `scansnap-checks-2026-07-22_pdf.pdf` (page sizes ±10px,
   skew <0.1°, MICR bands present, no shadows/strips).
3. Ask user to rule on p10 landscape-vs-portrait; if portrait wanted,
   would need a non-OCR signal (e.g. prefer portrait for check-back
   aspect ratios) — OCR evidence alone favors landscape.
4. Optionally test `--clean` mode + a mixed-document batch (letters,
   receipts) — all tuning so far is on the check corpus.

## Bleed-through / paper-gray suppression (s.pdf → s3.pdf saga)
The blue-gray plate shows through thin/creased paper as pale blue
patches; ScanSnap suppresses these to white.
- TRIED AND REVERTED (2026-07-22): whitening a tube along the
  bg→white mixing line (12-unit -opaque stops, 4% fuzz). Corpus
  metrics looked clean but real text-doc output was "a lot worse" —
  hard opaque edges turn smooth gradients into blotchy white islands.
  Binary matching is the wrong tool for a continuous gradient.
- CURRENT (step 2f in scan.sh): paper-white NORMALIZATION, smooth by
  construction: measure the crop's dominant bright color (mode of
  25%-scaled, depth-5-quantized histogram, lum ≥ bglum+8) = the paper,
  pull it to white with per-channel `-level 0%,P%`. Erases paper tint
  AND most bleed-through (both live along the paper-color axis).
  Forced-on test vs plain on s4 p3: bleed-through goes from "read the
  handwriting" to essentially gone.
- GATE HISTORY — the part that went in circles; do not repeat:
  saturation gating CANNOT work. HSL saturation explodes near white:
  optical-brightener paper (s4 doc, raw mode rgb(215,223,243) — the
  paper itself scans strongly BLUE, B-R=+28) measures 36-58% "sat",
  far above any workable threshold, so the s4 run normalized NOTHING
  and shipped the blue mess. Colored-check bodies overlap the same
  range. Current gate = MODE DOMINANCE (raw domain, on the crop):
  fraction of crop pixels in the single largest 8-unit bright bucket.
  FINAL GATE (after several failed attempts — history below): whiten
  only what the scanner provably tinted. Auto per page, ALL required:
  (1) dom>=40: share of crop pixels within 12 units of the dominant
  bright bucket (docs 57-85, most check fronts below);
  (2) artifact-signature blue on the PRECISE neighborhood-mean paper
  color (never the quantized mode — an 8-unit bucket shift between
  feeds jumps B-G by 8.2 in one step; that instability whitened
  Peachtree on the checks-v7 rescan after passing the first corpus):
  B-R>=23, B-G>=15, G-R<=12. Measured: docs B-R>=25.9 B-G>=18.9
  G-R<=9.2; Wilmington blue-gray (closest stock) B-R<=21.3
  B-G<=11.9 — once survived by 0.1; teal Peachtree G-R 33.8-34.6;
  warm stock negative; neutral white fails (nothing to remove).
  (3) crop short side >=1500px: checks are physically <=4.25"
  (<=1275px @300dpi), letter docs >=2544px — an orthogonal physical
  blocker for the whole check class even if colors drift. Small
  blue-paper scraps keep their tint (safe direction).
  USER REQUIREMENTS (hard): no flags in normal use — mixed batches
  (sizes, colors, checks together) must auto-work like ScanSnap;
  real paper colors (pink/yellow/cream/check stock) must survive.
  Verified on THREE corpora: v5 checks all-off (votes/bodysat
  stable), checks-v7 rescan all-off (raws in work/scansnap_lPC4th,
  outputs checks-v7-fixed.pdf), s4 docs all-on (user-rated "even
  better than scansnap"). Rescans shift measurements by ±1-2 units
  (Wilmington B-R 19.6->21.3, Peachtree dom 37.5->43.3 across
  feeds) — any future threshold must clear that jitter band.
  FAILED GATES (do not retry): HSL saturation (explodes near white
  — shipped the s4 blue mess by gating OFF the pages needing help);
  single-bucket dominance (noise-fragile); neighborhood dominance
  alone (Wilmington would bleach); texture/high-pass energy
  (text-edge halos on dense doc pages overlap engraved patterns);
  gating on quantized mode color (feed-unstable — the Peachtree
  whitening bug).
  `--no-whiten` / `--whiten` / SCAN_NORM=off|on exist as emergency
  overrides only — the user should never need them.

## Tone calibration vs ScanSnap (2026-07-23)
User: our colors "way more intense" than SS and the physical check.
Cause: `-level 3%,88%` stretches RGB channels independently —
brightening multiplies channel DIFFERENCES, i.e. amplifies chroma
(Pawtucket B-R 39 raw -> 46; measured overall: our body colors 15-30
darker and 1.5-1.9x the channel spread of SS's).
Fix: final-encode tone (worker FTONE) brightens on the LAB L channel
only, with the mid-lift from GAMMA, not white-point: `-colorspace
LAB -channel R -level 3%,90%,1.75 +channel -colorspace sRGB
-modulate 100,82 -unsharp 0x1+0.6+0.02`.
LESSON (cost one round-trip): first calibration used a hard white
point at L=80% — matched SS's body MEANS but CLIPPED everything
paler: Walton/Wilmington stock washed out, back security print
illegible (user-caught). Detail retention must be a measured target
alongside the mean: tonecal prints central-50% std; the clip showed
as Pawtucket-back std 3.6 vs ~7-16 preserved. Soft-shouldered gamma
(1.75 @ white 90%) gets means within ~6 of SS AND keeps the std.
Calibrated data-driven (debug.sh sscmp/tonecal vs SS ref PDF
~/Documents/2025-Scans/scansnap-checks-2026-07-22.pdf; candidates
applied to crop_raw_*.png from a DEBUG checksrun; SS rasterized at
300dpi for std comparability — SS's own std runs ~half ours, use
relative not absolute). Residuals ~≤9 (Pawtucket G): single global
curve can't zero per-paper response; IT8/ICC declined as rathole.
ARCHITECTURE: orientation-scoring image keeps the OLD tone
(`-level 3%,88%`) via $FILTER — votes are calibrated to those exact
pixels; FINAL_FILTER env overrides FTONE (main sets it for --clean).
sscmp's lum column is buggy; HSL sat unstable near white — compare
mean RGB + std only. Gate decisions and votes verified unchanged
(28 checks off / 6 docs on); s4-fixed-v4.pdf rebuilt with final
tone (v3, user-approved, was the clipping F variant — docs are
near-white so the difference there is minimal).

## Version history of attempts (what NOT to revisit)
- v1 (blur/divide/level): bleached colors; sideways backs.
- v1-fix (ocrmypdf --rotate-pages thr 2): rotation misfires.
- v2 (+swdeskew): content-cropped, zero margins, 0.26° residual.
- v3 (black-bg assumption): trim no-op, black deskew wedges.
- v4 (bg-key #b0c1c5 + erode + bbox): shadows/edges/one flip.
- v5 (= v4 rerun, raws saved): baseline for offline tuning.
- v6 (brightness-profile crop): fixed shadows, but cut pale-green check
  body 130 rows (brightness ≈ bg) — dead end alone.
- v7 (color-key bounds + trench-based shadow trim + high-conf orientation):
  current. Every intermediate variant (absolute floors, fixed-width
  polish, dim-based polish) over- or under-cut some corpus page — the
  trench+veto+relative-floor combination is the first that handles all 14.
