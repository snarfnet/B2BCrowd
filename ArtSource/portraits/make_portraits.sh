#!/bin/bash
# キャラ選択の写真：DJ 動画の元写真（後ろ姿・緑背景）を参照に、同じ人物を正面から（codex imagen）→ char_<id>.jpg
set -u
D=/c/Users/Windows/B2BCrowd/ArtSource/portraits; W=C:/Users/Windows/B2BCrowd/ArtSource
export PATH="/c/Users/Windows/AppData/Roaming/npm:$PATH"
declare -A ID=([saki]=c09 [leo]=c02 [kofi]=c12 [mei]=c16 [zuri]=c05 [mrfedora]=c07 [haru]=c13 [chromex]=r01 [android7]=r02 [retrobot]=r03)
gen() {
  n=$1
  [ -f "$D/$n.png" ] && return
  codex exec -m gpt-5.6-sol --sandbox danger-full-access --skip-git-repo-check "imagenスキルを使って、参照画像 $W/djvideo/${n}_base.png の人物（またはロボット）と同じ見た目・同じ服装・同じ髪型（ロボットなら同じ外装と色）で、正面を向いた写真を1枚生成し $W/portraits/$n.png に保存してください。正方形 1024x1024。胸から上のバストアップ、カメラ目線で自信のある笑顔（ロボットは堂々としたポーズ）。片手をヘッドホンに添えている。背景は夜のクラブの DJ ブースで、ピンクと青のライトが柔らかくボケている。写実的な写真、文字・ロゴなし。" < /dev/null > "$D/$n.log" 2>&1
}
for n in saki leo kofi mei zuri; do gen $n & done; wait
for n in mrfedora haru chromex android7 retrobot; do gen $n & done; wait
ls -la $D/*.png
