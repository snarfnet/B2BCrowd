import subprocess, json, re, os, glob, collections
def stats(f):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", f, "-af", "astats=metadata=0,silencedetect=n=-45dB:d=0.3", "-f", "null", "-"], capture_output=True, text=True).stderr
    dur = float(re.search(r"Duration: (\d+):(\d+):([\d.]+)", r).groups()[2])
    rms = float(re.findall(r"RMS level dB: ([-\d.inf]+)", r)[-1]) if "RMS level" in r else -99
    peak = float(re.findall(r"Peak level dB: ([-\d.inf]+)", r)[-1])
    sil = sum(float(x) for x in re.findall(r"silence_duration: ([\d.]+)", r))
    return dur, rms, peak, sil
best = {}
rows = collections.defaultdict(list)
for f in sorted(glob.glob("raw/*.flac")):
    name = re.search(r"b2b_(.+)_s\d+", os.path.basename(f)).group(1)
    d, rms, pk, sil = stats(f)
    score = rms - (8 if pk > -0.3 else 0) - sil * 6
    rows[name].append((score, f, d, rms, pk, sil))
for n, r in rows.items():
    r.sort(reverse=True)
    for s in r: print(n, os.path.basename(s[1]), "dur %.1f rms %.1f peak %.1f silence %.1f" % s[2:])
    best[n] = r[0][1]
json.dump(best, open("best.json", "w"), indent=1)
