#!/bin/bash
set -e

# Usage: scan.sh [output.pdf] [--clean] [--no-whiten|--whiten]
#   Everything always scans in full color. The whiten step only
#   decides whether the PAPER BACKGROUND TINT is normalized to white.
#   Default (auto): whiten a page only when its paper is uniform
#   (dominance gate — check patterns never qualify) AND blue-or-
#   neutral tinted (scanner lamp/optical brightener cast is always
#   blue; warm tints = real pink/yellow/cream stock, preserved).
#   --no-whiten  never whiten paper (exact paper color fidelity)
#   --whiten     always whiten paper (known white-paper batch)
#   --clean      blur/divide background flattening (B&W text only,
#                bleaches everything — predates --whiten, rarely
#                needed now)
#
# Env vars:
#   DEBUG=1        keep the temp dir (raw_*.pnm etc.) for inspection
#   BG_FUZZ        color tolerance when keying out the ADF background
#                  (default 6%)
#   SCANNER_BG_FRONT / SCANNER_BG_BACK
#                  ADF background color per scan head as R,G,B
#                  (defaults 176,194,197 / 188,205,208 — recalibrate
#                  by scanning a short doc with DEBUG=1 and sampling
#                  the bottom of a raw_*.pnm from each side)
#
# Internal: scan.sh --process-page <img.pnm> <filter>
#   Per-page worker invoked in parallel via xargs. Not for direct use.

BG_FUZZ="${BG_FUZZ:-6%}"

# ---- helpers ---------------------------------------------------------

# Locate the paper along one axis from two ImageMagick txt:- profiles:
# the non-bg pixel fraction per line, and the mean luminance per line
# with bg pixels painted black (so maskedlum/frac = true mean luminance
# of just the non-bg pixels — robust when a line is only partly paper).
#
# 1. Bounds: outermost lines with >20% non-bg pixels, two consecutive
#    required so a stray artifact line can't stretch the box.
# 2. Shadow trim: a trailing paper edge casts a shadow onto the bg
#    just outside the paper — included by step 1 since it isn't
#    bg-colored. Its measured profile, outside-in: a tail hugging the
#    bg level (as little as 1 unit below it, so a plain darkness
#    threshold stalls), then a steep dip to mlum 57-65 at the paper
#    edge line, then a sharp jump onto the paper. So per side: find
#    the darkest line within 70px of the bbox edge; it marks a real
#    shadow iff it is a deep dip (< bglum-60) AND the line 8 steps
#    outward from it is still shadow-dark (a dark PRINTED border
#    inside the paper fails this — outside it lies bright paper
#    margin, not shadow ramp). Then cut at the dip and walk inward
#    to the first non-dark line, which is the true paper edge.
#    Sides at the frame boundary have no bg to cast shadow on and
#    are left untouched.
#
# Prints "-1 -1" if nothing qualifies.
#   profile_bounds <nonbg.txt> <maskedlum.txt> <bglum 0-255>
profile_bounds() {
  awk -F'[()]' -v bglum="$3" '
    FNR==1 { fi++; next }
    fi==1 { f[FNR-2]=$2/255; n=FNR-1 }
    fi==2 { ml[FNR-2]=$2 }
    function mlum(i) { return f[i] > 0.02 ? ml[i]/f[i] : 255 }
    function min(a,b) { return a<b ? a : b }
    function max(a,b) { return a>b ? a : b }
    END{
      lo=-1; hi=-1
      for(i=0;i<n-1;i++) if(f[i]>0.2 && f[i+1]>0.2){lo=i;break}
      for(i=n-1;i>0;i--) if(f[i]>0.2 && f[i-1]>0.2){hi=i;break}
      # Reference paper level: median mlum of the central 60% of the
      # box. Pages darker than the bg (dense patterns, dark stock)
      # would otherwise sit wholly below a bg-derived floor and turn
      # the shadow walk into a random cut through page content.
      ref = 255
      if(lo>=0 && hi>lo+20){
        m=0; delete hist
        for(i=int(lo+0.2*(hi-lo)); i<=int(hi-0.2*(hi-lo)); i++){
          v=int(mlum(i)); if(v>255)v=255; hist[v]++; m++ }
        c=0; for(v=0;v<=255;v++){ c+=hist[v]; if(c>=m/2){ref=v;break} }
      }
      base = ref < bglum ? ref : bglum
      floor = base - 12; dipthr = base - 60
      # A dip only counts as the edge trench if NOTHING between it and
      # the bbox edge reaches bg-level brightness: a dark PRINTED
      # border has the bright paper margin (>= bg level) outside it
      # and gets vetoed, while a real trench has only the shadow ramp
      # outside, which always reads below the bg. (Lines with <30%
      # non-bg pixels are fade-tail lines whose mlum is unreliable —
      # they never veto.) After cutting at the dip, walk inward to the
      # first paper-level line; if none appears within 25 lines the
      # dip was page content after all: revert that side.
      if(lo>=0 && hi>lo){
        if(hi<n-3){
          dip=hi; for(i=max(lo,hi-70); i<=hi; i++) if(mlum(i)<mlum(dip)) dip=i
          ok = (mlum(dip)<dipthr)
          for(i=dip+1; ok && i<=hi; i++) if(f[i]>=0.3 && mlum(i)>=bglum) ok=0
          if(ok){
            hi0=hi; hi=dip; t=0
            while(hi>lo && mlum(hi)<floor && t<25){hi--;t++}
            if(mlum(hi)<floor) hi=hi0
          }
        }
        if(lo>2){
          dip=lo; for(i=min(hi,lo+70); i>=lo; i--) if(mlum(i)<mlum(dip)) dip=i
          ok = (mlum(dip)<dipthr)
          for(i=dip-1; ok && i>=lo; i--) if(f[i]>=0.3 && mlum(i)>=bglum) ok=0
          if(ok){
            lo0=lo; lo=dip; t=0
            while(lo<hi && mlum(lo)<floor && t<25){lo++;t++}
            if(mlum(lo)<floor) lo=lo0
          }
        }
      }
      print lo, hi }' "$1" "$2"
}

# ---- per-page worker (self-invoked) ----------------------------------
process_page() {
  local img="$1" filter="$2"
  [ -e "$img" ] || return 0
  local base="${img%.pnm}"

  # 1. The ADF background color is a per-scan-head hardware constant:
  #    every measurement across all batches agrees within ~2 units
  #    (fronts rgb(176,194,197), backs rgb(188,205,208); duplex order
  #    means odd pages = front head, even = back head). Use the
  #    calibrated constants directly — the keying fuzz absorbs the
  #    small drift. Do NOT measure per-frame: a full-height letter
  #    page covers the whole bed, and measuring its bottom strip
  #    reads white paper as "background", which un-keys the real blue
  #    bg margins AND aims the whitening at paper (the s.pdf blue-
  #    border bug). Override via SCANNER_BG_FRONT/SCANNER_BG_BACK if
  #    the heads ever get recalibrated.
  local num bg bglum
  num=${base##*_}
  case "$num" in *[!0-9]*|'') num=1;; esac
  if [ $((10#$num % 2)) -eq 1 ]; then
    bg="${SCANNER_BG_FRONT:-176,194,197}"
  else
    bg="${SCANNER_BG_BACK:-188,205,208}"
  fi
  bglum=$(echo "$bg" | awk -F, '{printf "%.0f", .299*$1+.587*$2+.114*$3}')

  # 2. Deskew the raw frame (fill = this frame's bg color so rotation
  #    wedges blend into the background) and shave the 1–2px sensor
  #    artifact rim. (Shave 10 is tuned: reducing it to recover more
  #    of full-bleed pages shifted content enough to flip the p2
  #    rotation vote and misfire p13's top trim — not worth ~0.5mm.)
  #    -deskew's angle estimate needs dark features; on a featureless
  #    page (blank duplex back — fold creases don't survive the 50%
  #    threshold) it latches onto noise and can rotate a straight
  #    page by several degrees (s3.pdf p2). A duplex back shares its
  #    sheet with its front, so its true angle is the front's angle
  #    NEGATED (verified on corpus pairs to ~0.15°; -rotate with the
  #    deskew-reported angle reproduces -deskew to RMSE 0.007).
  #    Trust the page's own estimate only if ≥0.2% of its pixels are
  #    dark (every corpus page is ≥0.46%); else mirror a trustworthy
  #    sibling; else leave unrotated.
  local darkfrac angle sibnum sib sibfrac
  darkfrac=$(magick "$img" -shave 6x6 -colorspace gray -threshold 50% \
               -format '%[fx:1-mean]' info:)
  if awk -v d="$darkfrac" 'BEGIN{exit !(d>=0.002)}'; then
    magick "$img" -background "rgb($bg)" -deskew 40% +repage \
           -shave 10x10 "stage_${base}.png"
  else
    if [ $((10#$num % 2)) -eq 1 ]; then sibnum=$((10#$num+1)); else sibnum=$((10#$num-1)); fi
    sib="${base%_*}_$(printf '%03d' "$sibnum").pnm"
    angle=0
    if [ -e "$sib" ]; then
      sibfrac=$(magick "$sib" -shave 6x6 -colorspace gray -threshold 50% \
                  -format '%[fx:1-mean]' info:)
      if awk -v d="$sibfrac" 'BEGIN{exit !(d>=0.002)}'; then
        angle=$(magick "$sib" -deskew 40% -format '%[deskew:angle]' info: | \
                awk '{a=-$1; if(a>3||a<-3)a=0; printf "%.4f", a}')
      fi
    fi
    [ -n "$DEBUG" ] && \
      echo "DEBUG ${base}: featureless (dark $darkfrac) -> sibling-mirror angle $angle" >&2
    magick "$img" -background "rgb($bg)" -rotate "$angle" +repage \
           -shave 10x10 "stage_${base}.png"
  fi

  local W H
  read -r W H <<< "$(magick identify -format '%w %h' "stage_${base}.png")"

  # 3. Locate the paper via row/column profiles (see profile_bounds):
  #    bg-color keying finds the bounds regardless of paper color or
  #    brightness, then the shadow band the keying can't exclude is
  #    trimmed positionally from the edges. Rows first, then columns
  #    measured only within the found rows. Both profiles per axis
  #    come from one keyed image: its binary alpha-less mask (non-bg
  #    fraction) and the bg-blacked grayscale (masked luminance).
  local y0 y1 x0 x1
  magick "stage_${base}.png" -fuzz "$BG_FUZZ" -fill black -opaque "rgb($bg)" \
         \( +clone -fill white +opaque black \) \
         -colorspace gray -scale "1x${H}!" \
         \( -clone 1 -write "prof_${base}_nonbg.txt" +delete \) \
         -delete 1 "prof_${base}_mlum.txt"
  read -r y0 y1 <<< "$(profile_bounds "prof_${base}_nonbg.txt" \
                         "prof_${base}_mlum.txt" "$bglum")"
  if [ "$y0" -ge 0 ]; then
    magick "stage_${base}.png" -crop "${W}x$((y1 - y0 + 1))+0+${y0}" +repage \
           -fuzz "$BG_FUZZ" -fill black -opaque "rgb($bg)" \
           \( +clone -fill white +opaque black \) \
           -colorspace gray -scale "${W}x1!" \
           \( -clone 1 -write "prof_${base}_nonbg.txt" +delete \) \
           -delete 1 "prof_${base}_mlum.txt"
    read -r x0 x1 <<< "$(profile_bounds "prof_${base}_nonbg.txt" \
                           "prof_${base}_mlum.txt" "$bglum")"
  else
    x0=-1; x1=-1
  fi
  rm -f "prof_${base}_nonbg.txt" "prof_${base}_mlum.txt"

  [ -n "$DEBUG" ] && \
    echo "DEBUG ${base}: stage ${W}x${H} bg $bg bglum $bglum rows ${y0}-${y1} cols ${x0}-${x1}" >&2

  # Sanity: if the paper wasn't found (blank/failed page), keep the
  # whole frame rather than emitting a sliver.
  local CW CH
  CW=$((x1 - x0 + 1)); CH=$((y1 - y0 + 1))
  if [ "$x0" -lt 0 ] || [ "$CW" -lt 100 ] || [ "$CH" -lt 100 ]; then
    x0=0; y0=0; CW=$W; CH=$H
  fi

  # 4. Crop to paper + tone → the orientation-scoring image. NO bg
  #    whitening here: the rotation gate is calibrated on these exact
  #    pixels, and whitening jitter (a 1-unit bg shift repaints
  #    different pixels) moves tesseract scores enough to flip
  #    marginal sparse-text pages. Whitening happens only in the
  #    final encode (step 6).
  eval magick \"stage_${base}.png\" \
       -crop "${CW}x${CH}+${x0}+${y0}" +repage -shave 4x4 \
       -colorspace sRGB \
       $filter \
       -units PixelsPerInch -density 300 \
       "png:\"stage2_${base}.png\""

  # 5. Per-page orientation: score OCR quality at all four rotations
  #    and keep the winner. Decided entirely from THIS page's own
  #    content — no assumptions about neighbors, sides, or feed
  #    direction.
  #    Score = sum of confidences of confidently-read words only
  #    (conf>=60, capped at 30 words). Sideways/garbage reads produce
  #    plenty of words, but almost none reach conf 60, so correct
  #    orientations win by 5-8x instead of the ~1.4x the old
  #    mean-confidence metric gave — sharp enough to gate hard.
  local best_rot=0 best=0 second=0 rot score
  for rot in 0 90 180 270; do
    score=$(magick "stage2_${base}.png" -resize '2200x2200>' -rotate "$rot" png:- 2>/dev/null | \
      OMP_THREAD_LIMIT=1 tesseract stdin stdout --psm 6 tsv 2>/dev/null | \
      awk -F'\t' 'NR>1 && $11+0>=60 && length($12)>=3 && $12 ~ /[[:alnum:]]/ {s+=$11; n++; if(n>=30) exit}
                  END{ printf "%.0f", s+0 }')
    score=${score:-0}
    if [ "$score" -gt "$best" ]; then second=$best; best=$score; best_rot=$rot
    elif [ "$score" -gt "$second" ]; then second=$score; fi
  done
  # Only rotate on solid evidence: meaningful text AND a clear winner.
  # (Weakest genuine winner in the test corpus scored 1742 at 8x the
  # runner-up; a garbage vote on a blank streaky page stays far below
  # 400.)
  rot=0
  if [ "$best" -ge 400 ] && [ $((best * 10)) -ge $((second * 18)) ]; then
    rot=$best_rot
  fi
  [ -n "$DEBUG" ] && \
    echo "DEBUG ${base}: orient best $best@$best_rot second $second -> rot $rot" >&2

  # 6. Final encode: same crop, plus ScanSnap-style whitening of any
  #    background still inside it (deskew wedges at clipped corners,
  #    shadow tails — ScanSnap renders these white; 4% fuzz ≈ 3 sigma
  #    of the bg, well inside the palest corpus paper at ~7%).
  #    Whitening runs in the raw color domain, i.e. before $filter.
  #    (Whitening the whole bg→white mixing line to kill bleed-through
  #    was tried and REVERTED: hard opaque edges on a smooth gradient
  #    made real pages much worse — see HANDOFF.)
  #    Additionally, WHITE-PAPER pages get paper-white normalization:
  #    find the dominant bright color (the paper — includes optical-
  #    brightener blue tints, which scan strongly blue) and pull it to
  #    white with a smooth per-channel -level. Erases paper tint AND
  #    most bleed-through (both live along the paper-color axis), like
  #    ScanSnap. Gate = MODE DOMINANCE, not saturation (HSL saturation
  #    explodes near white — it can't tell tinted paper from colored
  #    checks; that bug shipped the s4.pdf blue mess): uniform paper
  #    puts ≥~21% of crop pixels in one 8-unit color bucket, check
  #    front patterns ≤~12%. Threshold 15%. SCAN_NORM=off|on overrides
  #    (--color / --white flags).
  # dom = share of crop pixels within 12 units (per channel) of the
  # dominant bright color — the mode's whole neighborhood, not one
  # quantization bucket, so uniform paper isn't split by noise.
  local dom PR PG PB paper="" norm=""
  read -r dom PR PG PB <<< "$(magick "stage_${base}.png" \
        -crop "${CW}x${CH}+${x0}+${y0}" +repage -scale 25% -depth 5 \
        -format %c histogram:info: | \
      awk -F'[(,)]' -v minl=$((bglum+8)) \
        '{c[NR]=$1+0; tot+=c[NR]; r[NR]=$2+0; g[NR]=$3+0; b[NR]=$4+0
          l=.299*r[NR]+.587*g[NR]+.114*b[NR]
          if(l>=minl && c[NR]>best){best=c[NR]; m=NR}}
         END{if(!m){print "0 0 0 0"; exit}
             for(i=1;i<=NR;i++){
               dr=r[i]-r[m]; if(dr<0)dr=-dr
               dg=g[i]-g[m]; if(dg<0)dg=-dg
               db=b[i]-b[m]; if(db<0)db=-db
               if(dr<=12 && dg<=12 && db<=12) near+=c[i]}
             printf "%.1f %.1f %.1f %.1f", near*100/tot, r[m], g[m], b[m]}')"
  # Auto mode: whiten ONLY what the scanner itself provably tinted.
  # Two per-page conditions, both required:
  #   1. uniform paper: dom >= 40 (patterned check fronts reach 25.5
  #      at most — except Wilmington's near-solid stock, caught by 2);
  #   2. artifact-strength blue cast: B-R >= 20 AND B-G >= 12. Optical
  #      brightener fluorescence is STRONG and blue-not-teal (measured
  #      docs B-R 24.6-32.9, B-G 16.4-24.7); every corpus check fails
  #      at least one (pale-blue Wilmington B-R 16.5; teal Peachtree
  #      B-R 41 but B-G 8.2), warm stock (pink/yellow/cream) is
  #      negative, and neutral white paper fails too — no artifact,
  #      nothing to remove. (Texture gating was tried and dropped:
  #      text-edge halos on dense doc pages overlap engraved-pattern
  #      energy.)
  # Both signals are per-page; mixed batches need no flags.
  case "${SCAN_NORM:-auto}" in
    on)   paper=1;;
    off)  paper="";;
    *)    awk -v d="$dom" -v r="$PR" -v g="$PG" -v b="$PB" \
            'BEGIN{exit !(d>=40 && r>0 && b-r>=20 && b-g>=12)}' && paper=1;;
  esac
  [ -n "$paper" ] && [ "$PR" != "0" ] && norm=$(awk -v r="$PR" -v g="$PG" -v b="$PB" 'BEGIN{
      printf "-channel R -level 0%%,%.1f%% +channel", r/2.55
      printf " -channel G -level 0%%,%.1f%% +channel", g/2.55
      printf " -channel B -level 0%%,%.1f%% +channel", b/2.55}')
  [ -n "$DEBUG" ] && \
    echo "DEBUG ${base}: dom $dom paper $PR,$PG,$PB norm $([ -n "$norm" ] && echo on || echo off)" >&2
  local bgcolor="rgb($bg)"
  eval magick \"stage_${base}.png\" \
       -crop "${CW}x${CH}+${x0}+${y0}" +repage -shave 4x4 \
       -fuzz 4% -fill white -opaque \"\$bgcolor\" \
       $norm \
       -colorspace sRGB \
       $filter \
       -rotate "$rot" \
       -units PixelsPerInch -density 300 \
       -quality 90 "clean_${base}.jpg"
  [ -z "$DEBUG" ] && rm -f "stage_${base}.png" "stage2_${base}.png"
  return 0
}

if [ "$1" = "--process-page" ]; then
  process_page "$2" "$3"
  exit 0
fi
# ----------------------------------------------------------------------

OUTPUT_PDF="${1:-scanned_doc.pdf}"
CLEAN_MODE=""
SCAN_NORM="${SCAN_NORM:-auto}"
shift $(($# > 0 ? 1 : 0))
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN_MODE="--clean";;
    --no-whiten) SCAN_NORM=off;;  # never normalize paper tint to white
    --whiten)    SCAN_NORM=on;;   # always normalize paper tint to white
    *) echo "unknown option: $arg" >&2; exit 1;;
  esac
done
export SCAN_NORM

# Absolute paths BEFORE cd'ing into the temp dir: the output (so it
# isn't written into — and deleted with — the temp dir), and this
# script itself (so xargs can re-invoke it as the worker).
case "$OUTPUT_PDF" in
  /*) ;;
  *) OUTPUT_PDF="$PWD/$OUTPUT_PDF" ;;
esac
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

mkdir -p "$(dirname "$SELF")/work"
TMP_DIR=$(mktemp -d "$(dirname "$SELF")/work/scansnap_XXXXXX")
if [ -z "$DEBUG" ]; then
  trap 'rm -rf "$TMP_DIR"' EXIT
else
  echo "DEBUG: keeping temp dir $TMP_DIR"
fi
cd "$TMP_DIR"

NUM_CORES=$(sysctl -n hw.ncpu)

echo "==> 1. Scanning ADF Duplex (RAW frame — no backend crop/deskew)..."
# page-width/-x maxed: the backend allows a 221.121mm window (vs 8.5" =
# 215.9mm default) and the hardware delivers real pixels out there.
# The ADF centers the paper, so this captures ~2.6mm of extra margin
# per side — rescues the side edges of letter-width docs fed slightly
# offset or skewed. (Top-corner clipping from skew is NOT fixable:
# capture starts at the leading-edge trigger, -t cannot go negative.)
scanimage -d fujitsu \
          --source 'ADF Duplex' \
          --resolution 300 \
          --mode Color \
          --page-width=221.121 -x 221.121 \
          --buffermode On \
          --format=pnm \
          --batch="raw_%03d.pnm"

if [ "$CLEAN_MODE" = "--clean" ]; then
  FILTER='\( +clone -blur 0x25 \) -compose divide -composite -level 5%,95%'
else
  # ScanSnap-matching tone: brightens paper whites (suppresses
  # bleedthrough), mild contrast/saturation boost, light sharpen.
  FILTER='-level 3%,88% -unsharp 0x1+0.6+0.02'
fi

echo "==> 2. Deskew, crop, tone, per-page orientation — $NUM_CORES cores..."
printf "%s\n" raw_*.pnm | xargs -P "$NUM_CORES" -I {} "$SELF" --process-page {} "$FILTER"

echo "==> 3. Compiling PDF and running OCR..."
img2pdf clean_raw_*.jpg -o combined.pdf
ocrmypdf --optimize 1 --jpeg-quality 90 \
         combined.pdf "$OUTPUT_PDF"

echo "==> Done! Saved to: $OUTPUT_PDF"
