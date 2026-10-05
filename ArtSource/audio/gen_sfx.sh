#!/bin/bash
# Stable Audio 3（ローカル）で観客の声を作る。音楽は入れない（Apple Music と重なるので）
G="python E:/ComfyUI/sa3_gen.py"
OUT="C:/Users/Windows/B2BCrowd/ArtSource/audio/raw"
gen() { # name seconds prompt
  for seed in 11 22 33; do
    $G "$3" --sfx --seconds $2 --no-halve --seed $seed --out "b2b_$1_s$seed" --copy-to "$OUT" >/dev/null 2>&1 || echo "FAIL $1 $seed"
  done
  echo "done $1"
}
gen cheer_small 3 "Excited nightclub crowd cheering and shouting, short burst of cheers, no music"
gen cheer_big 5 "Huge crowd roaring and screaming with excitement, massive cheer at a festival, no music"
gen whistle 2 "Loud sharp two-finger whistle by one person in a cheering crowd, no music"
gen woo 3 "Party crowd yelling woo, excited people shouting woo, no music"
gen applause 4 "Crowd clapping and applauding enthusiastically with cheers, no music"
gen boo 3 "Disappointed crowd groaning and booing, no music"
gen amb_low 12 "Nightclub crowd ambience, people talking and murmuring, chatter, no music"
gen amb_high 12 "Excited crowd ambience at a concert, continuous cheering and yelling, no music"
gen horn 2 "Party air horn blast, three short air horn honks"
