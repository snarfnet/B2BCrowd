import subprocess, numpy as np, glob, os
def load(f):
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", f, "-ac", "1", "-ar", "22050", "-f", "f32le", "-"], capture_output=True).stdout
    return np.frombuffer(raw, np.float32)
for f in sorted(glob.glob("raw/*.flac")):
    x = load(f)
    if len(x) < 2048: continue
    frames = [x[i:i + 2048] * np.hanning(2048) for i in range(0, len(x) - 2048, 1024)]
    S = np.abs(np.fft.rfft(np.array(frames), axis=1)) + 1e-9
    e = S.sum(axis=1); loud = S[e > np.percentile(e, 60)]
    flat = np.exp(np.log(loud).mean(axis=1)) / loud.mean(axis=1)          # 0=音程あり 1=ノイズ
    peak = np.argmax(loud.mean(axis=0)) * 22050 / 2048
    print("%-32s flatness %.3f  peakHz %5.0f" % (os.path.basename(f), flat.mean(), peak))
