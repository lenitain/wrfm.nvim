#!/usr/bin/env bash
# Regenerate tests/fixtures/golden/*.txt from the installed `wrfm` CLI.
# Run manually when the renderer contract changes intentionally: `mise run golden`.
# CI never runs this; tests compare the Lua renderer against the committed files.
set -euo pipefail

command -v wrfm >/dev/null 2>&1 || {
  echo "error: wrfm CLI not found in PATH (needed for golden regeneration)" >&2
  exit 1
}

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models_dir="$repo/tests/fixtures/models"
golden_dir="$repo/tests/fixtures/golden"
version="$(wrfm --version 2>/dev/null || echo unknown)"

views=("30 45" "0 0" "90 0")
sizes=("40x12" "17x7")

mkdir -p "$golden_dir"
rm -f "$golden_dir"/*.txt

for model_path in "$models_dir"/*.wrfm; do
  model="$(basename "$model_path" .wrfm)"
  for view in "${views[@]}"; do
    read -r pitch yaw <<<"$view"
    for size in "${sizes[@]}"; do
      w="${size%x*}"
      h="${size#*x}"
      out="$golden_dir/$model-$pitch-$yaw-$size.txt"
      {
        echo "# wrfm render $model_path --format braille --views= --pitch=$pitch --yaw=$yaw --width=$w --height=$h"
        echo "# generated-with: $version"
        wrfm render "$model_path" --format braille --views= \
          "--pitch=$pitch" "--yaw=$yaw" "--width=$w" "--height=$h" \
          | grep -v '^#' | sed 's/[[:space:]]*$//' | head -n "$h"
      } > "$out"
      echo "wrote ${out#$repo/}"
    done
  done
done
