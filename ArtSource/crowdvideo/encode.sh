#!/bin/sh
# Grok で作った観客の動画を、アプリ用のループ動画にする。
# 前→逆再生をつなげて継ぎ目のないループにし、音は消す（AI 動画の音は使わない）。
# 使い方: sh encode.sh            … クラブ共通（このフォルダ）→ crowd_t0..5.mp4
#         sh encode.sh forestRave … 会場専用（forestRave/）→ crowd_forestRave_t0..5.mp4
cd "$(dirname "$0")"
V=${1:-}
SRC=${V:-.}
PRE=crowd_${V:+${V}_}
OUT=../../B2BCrowd/Resources/CrowdVideo
mkdir -p "$OUT"
i=0
for n in t0_dead t1_warming t2_good t3_hot t4_insane t5_legendary; do
  ffmpeg -v error -y -i "$SRC/$n.mp4" -filter_complex \
    "[0:v]scale=704:1280,fps=24,setsar=1,split[a][b];[b]reverse[r];[a][r]concat=n=2:v=1:a=0,format=yuv420p[v]" \
    -map "[v]" -an -c:v libx264 -preset slow -crf 24 -profile:v high -movflags +faststart "$OUT/${PRE}t$i.mp4"
  i=$((i + 1))
done
ls -la "$OUT"
