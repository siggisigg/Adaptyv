#!/usr/bin/env bash
# Render every ```mermaid block in README.md to docs/diagrams/*.svg and *.png.
#
# README.md is the single source of truth: this script extracts the diagrams from it, so the
# images can't drift from the README. Re-run it after editing a diagram.
#
# Needs Docker (uses the official Mermaid CLI image, which bundles a headless Chromium).
# Usage (from anywhere):  docs/render-diagrams.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="docs/diagrams"
IMAGE="minlag/mermaid-cli"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT/src"

# 1. Extract each diagram to docs/diagrams/src/NN-<name>.mmd
#    NN = order in the README; name = the block's "%% file: <name>" line, else its section heading.
python3 - "$OUT/src" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
section, n = "intro", 0
lines = pathlib.Path("README.md").read_text().splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("## "):
        title = re.sub(r"^## (\d+\.\s*)?", "", line)
        section = "-".join(re.sub(r"[^a-z0-9 ]", "", title.lower()).split()[:4])
    if line.strip() == "```mermaid":
        body = []
        i += 1
        while lines[i].strip() != "```":
            body.append(lines[i]); i += 1
        n += 1
        # Name: a "%% file: <name>" comment on the first line (Mermaid ignores %% lines),
        # else the section heading.
        m = re.match(r"%%\s*file:\s*(\S+)", body[0]) if body else None
        name = m.group(1) if m else section
        (out / f"{n:02d}-{name}.mmd").write_text("\n".join(body) + "\n")
    i += 1
print(f"extracted {n} diagrams")
PY

# 2. Render each one to SVG (sharp at any size, for slides) and PNG at 2x (for tools without SVG).
#    -u: write files as you, not root.  -b white: white background for slides.
for src in "$OUT"/src/*.mmd; do
  name="$(basename "$src" .mmd)"
  for fmt in svg png; do
    extra=()
    [[ "$fmt" == png ]] && extra=(-s 2)
    docker run --rm -u "$(id -u):$(id -g)" -v "$ROOT:/data" "$IMAGE" \
      -q -t default -b white "${extra[@]}" \
      -i "/data/$src" -o "/data/$OUT/$name.$fmt"
  done
  echo "rendered $name"
done
