#!/bin/bash
# DJ の実写動画：緑背景の写真（SAKI の写真を参照に同じカメラ・同じブース）→ Grok で play/browse/drop。
# 使い方: bash make_djs.sh stills | videos
set -u
D=/c/Users/Windows/B2BCrowd/ArtSource/djvideo
W=C:/Users/Windows/B2BCrowd/ArtSource/djvideo
export PATH="/c/Users/Windows/AppData/Roaming/npm:$PATH"
declare -A DESC=(
  [kofi]="DJの『KOFI』（30代のガーナ系の男性、濃い肌、短い黒髪、グレーのジップジャケットの下にストライプのシャツ、首にヘッドホン）"
  [mei]="DJの『MEI』（20代の中国系の女性、黒髪の高いポニーテール、青い短めのTシャツ、黒いパンツ、首にヘッドホン）"
  [zuri]="DJの『ZURI』（20代のケニア系の女性、濃い肌、とても短いナチュラルヘア、青い短めのVネックトップ、金のフープピアス、首にヘッドホン）"
  [mrfedora]="DJの『MR. FEDORA』（50代の男性、グレーのフェドーラ帽、チャコールのスーツの上着、白いシャツの襟、短い白髪まじりのひげ、首にヘッドホン）"
  [haru]="DJの『HARU』（20代の日本人の男性、短い黒髪、無地の白いTシャツ、首にヘッドホン）"
  [chromex]="DJロボットの『CHROME-X』（人型ロボット。つややかな黒い装甲、クロームの関節、頭はバイザー型で横一文字の白い光のライン）"
  [android7]="DJロボットの『ANDROID 7』（人型アンドロイド。つややかな白い装甲、角の丸い箱型の頭に暗い顔の画面とピンクに光る目、グレーの関節）"
  [retrobot]="DJロボットの『RETRO-BOT』（レトロな人型ロボット。オレンジ色の角ばった箱型の体と頭、頭の上にアンテナ、丸い目のライト、クリーム色の関節）"
)
NAMES="kofi mei zuri mrfedora haru chromex android7 retrobot"

if [ "${1:-}" = stills ]; then
  for n in $NAMES; do
    [ -f "$D/${n}_base.png" ] && continue
    codex exec -m gpt-5.6-sol --sandbox danger-full-access --skip-git-repo-check "imagenスキルを使って、参照画像 $W/saki_base.png を元に画像を1枚生成し $W/${n}_base.png に保存してください。参照画像と同じカメラ位置（DJの真後ろの少し高い位置）・同じ構図・同じ縦横比4:5・同じDJブースと機材・同じ完全な単色のクロマキー用グリーン（#00FF00）の背景（影もグラデーションもなし）・同じマゼンタとシアンのリムライト。変えるのはDJ本人だけ：${DESC[$n]}。後ろ姿で、横顔が少し見える程度。両手はミキサーとプレーヤーの上。写実的な質感。文字・ロゴは入れない。" < /dev/null > "$D/${n}.log" 2>&1 &
  done
  wait
  ls "$D"/*_base.png
fi

if [ "${1:-}" = videos ]; then
  cd /c/Users/Windows/asc-automation
  export GSHOT="C:/Users/Windows/AppData/Local/Temp/claude/C--Users-Windows/0e211aec-ca61-4197-a63c-f6022ebeb45d/scratchpad/"
  G="Locked-off static camera, no camera movement, no zoom. The background stays a perfectly flat solid chroma green the whole time, nothing appears in the green area. Realistic natural motion."
  vid() { for a in 1 2; do [ -f "$2" ] && break; timeout 400 node _grok_gen.js "$1" "$2" "$3" 2>&1 | tail -1; done; }
  for n in $NAMES; do
    vid "$D/${n}_base.png" "$D/${n}_play.mp4" "$G The DJ plays the set: nods to the beat, turns a knob on the mixer, then rides an EQ knob, shoulders moving with the music."
    vid "$D/${n}_base.png" "$D/${n}_browse.mp4" "$G The DJ is choosing the next track: looks down at the player screen, scrolls the browse knob, taps a button, cues with headphones held to one ear."
    vid "$D/${n}_base.png" "$D/${n}_drop.mp4" "$G The DJ drops the next track: slides the crossfader across, then raises one fist high toward the crowd in excitement, bouncing with the beat."
  done
  ls -la "$D"/*.mp4
fi
