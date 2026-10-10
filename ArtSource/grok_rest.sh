#!/bin/bash
# 2026-10-10: 森・レコード屋の引き版の動画と、振り向いたロボ3本の作り直し
cd /c/Users/Windows/B2BCrowd/ArtSource/crowdvideo
bash make_venue_wide.sh forestRave "夜の森の野外レイヴ" "An outdoor forest rave at night among tall trees, string lights and green lasers through the haze."
bash make_venue_wide.sh recordShop "レコード屋の店内DJイベント" "An in-store DJ party inside a cozy record shop, vinyl racks along the walls, warm lights."
cd /c/Users/Windows/asc-automation
D=/c/Users/Windows/B2BCrowd/ArtSource/djvideo
G="Locked-off static camera, no camera movement, no zoom. The background stays a perfectly flat solid chroma green the whole time, nothing appears in the green area. Realistic natural motion. The robot keeps its back to the camera the entire time and never turns around or looks back; we only ever see its back and the back of its head."
vid() { for a in 1 2 3; do [ -f "$2" ] && break; timeout 400 node _grok_gen.js "$1" "$2" "$3" 2>&1 | tail -1; done; }
vid $D/android7_base.png $D/android7_play.mp4 "$G The DJ plays the set: nods to the beat, turns a knob on the mixer, then rides an EQ knob, shoulders moving with the music."
vid $D/retrobot_base.png $D/retrobot_browse.mp4 "$G The DJ is choosing the next track: looks down at the player screen, scrolls the browse knob, taps a button."
vid $D/retrobot_base.png $D/retrobot_drop.mp4 "$G The DJ drops the next track: slides the crossfader across, then raises one fist high toward the crowd, bouncing with the beat."
ls -la $D/*.mp4 | tail -5
echo GROK_DONE
