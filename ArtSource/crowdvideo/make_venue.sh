#!/bin/bash
# 会場ごとの観客の写真6枚（盛り上がり6段階）→ Grok で動画6本。
# 使い方: bash make_venue.sh <venue> "<会場の説明（日本語）>" "<会場の説明（英語、動画用）>"
set -u
V=$1; DESC=$2; EN=$3
D=/c/Users/Windows/B2BCrowd/ArtSource/crowdvideo/$V
W=C:/Users/Windows/B2BCrowd/ArtSource/crowdvideo/$V
mkdir -p "$D"
export PATH="/c/Users/Windows/AppData/Roaming/npm:$PATH"
cx() { codex exec -m gpt-5.6-sol --sandbox danger-full-access --skip-git-repo-check "$1" < /dev/null > "$D/$2.log" 2>&1; }

if [ ! -f "$D/t2_good.png" ]; then
  cx "imagenスキルを使って画像を1枚生成し $W/t2_good.png に保存してください。縦長 9:16（940x1672程度）の写実的な写真。場所：$DESC 視点：DJブースのすぐ後ろ、DJの目線の高さから、踊る観客を正面から少し見下ろす。画面の下から25%は手前のブースの縁で真っ暗（何も写らない黒）。DJ機材・DJ本人・手は写さない。観客：20代〜30代の多様な人たちがDJの方を向いて、楽しそうに体を揺らして踊っている（中くらいの盛り上がり）。本物の現場で撮った報道写真のような質感：35mm、肌や服がリアル、顔は自然。文字・ロゴ・透かしは入れない。" t2
fi
BASE=$W/t2_good.png
gen() {
  [ -f "$D/$1.png" ] && return
  cx "imagenスキルを使って、参照画像 $BASE を元に画像を1枚生成し $W/$1.png に保存してください。参照画像と同じ場所・同じカメラ位置と構図・同じ縦長9:16・同じ照明の配置・下部の真っ黒なブースの縁もそのまま。写実的な報道写真の質感も同じ。変えるのは観客の様子だけ：$2 文字・ロゴは入れない。" "$1"
}
gen t0_dead "ほぼ誰もいない。数人がまばらに立ち、腕を組んだりスマホを見たりして退屈そう。照明は暗め。" &
gen t1_warming "人はまだ少なく間隔が空いている。何人かが小さく頭を振り、ドリンクを持って様子を見ている。" &
gen t3_hot "人でいっぱい。ほとんどの人が手を上げて笑顔で踊り、熱気がある。照明が強くなる。" &
gen t4_insane "ぎゅうぎゅうの満員。全員がジャンプし、両手を高く突き上げて叫んでいる。強いストロボとレーザー。" &
gen t5_legendary "満員で最高潮。全員が両手を上げて歓喜し、紙吹雪が大量に舞い、白いスモークが噴き出す。照明は全開。" &
wait
ls "$D"/*.png

cd /c/Users/Windows/asc-automation
export GSHOT="C:/Users/Windows/AppData/Local/Temp/claude/C--Users-Windows/0e211aec-ca61-4197-a63c-f6022ebeb45d/scratchpad/"
S="Locked-off static camera, no camera movement, no zoom. $EN Realistic natural motion, everyone stays in place."
vid() { for a in 1 2; do [ -f "$D/$1.mp4" ] && break; timeout 400 node _grok_gen.js "$D/$1.png" "$D/$1.mp4" "$S $2" 2>&1 | tail -1; done; }
vid t0_dead "Nearly empty: a few bored people stand still, glance at their phones, sip drinks. Lights move very slowly."
vid t1_warming "A loose crowd starts to warm up: people nod their heads and sway a little, chat and sip drinks."
vid t2_good "The crowd dances naturally with a moderate groove, swaying and nodding to the beat."
vid t3_hot "A packed crowd dances energetically with hands up, smiling, moving to the beat."
vid t4_insane "An ecstatic packed crowd jumps up and down together with both hands raised, shouting, strobes flashing."
vid t5_legendary "Peak euphoric moment: everyone jumps and cheers with hands up while confetti falls and white smoke blasts."
ls -la "$D"/*.mp4
