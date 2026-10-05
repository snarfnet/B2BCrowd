import subprocess, os
R = "raw/b2b_%s_00001.flac"
OUT = "../../B2BCrowd/Resources/Sounds"
ONE = {  # 出力名: 元
    "cheer_small": "cheer_small_s11", "cheer_small2": "cheer_small_s33",
    "cheer_big": "cheer_big_s33", "whistle": "whistle_s22", "whistle2": "whistle_s33",
    "woo": "woo_s22", "woo2": "woo_s33", "applause": "applause_s22", "boo": "boo_s22", "horn": "horn_s33",
}
LOOP = {"amb_low": "amb_low_s11", "amb_high": "amb_high_s33"}
def run(args):
    subprocess.run(["ffmpeg", "-v", "error", "-y"] + args, check=True)
trim = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.02,areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,areverse"
for name, src in ONE.items():
    run(["-i", R % src, "-af", trim + ",afade=t=in:d=0.02,areverse,afade=t=in:d=0.25,areverse,loudnorm=I=-16:TP=-1.5:LRA=11",
         "-ar", "44100", "-c:a", "aac", "-b:a", "128k", f"{OUT}/{name}.m4a"])
for name, src in LOOP.items():
    # 終わり 1.5 秒を頭に重ねてつなぎ目を消す
    run(["-i", R % src, "-filter_complex",
         "[0]asplit=3[s1][s2][s3];"
         "[s1]atrim=10.5:12,asetpts=N/SR/TB,afade=t=out:d=1.5[tail];"
         "[s2]atrim=0:1.5,asetpts=N/SR/TB,afade=t=in:d=1.5[head];"
         "[tail][head]amix=inputs=2:normalize=0[x];"
         "[s3]atrim=1.5:10.5,asetpts=N/SR/TB[mid];"
         "[x][mid]concat=n=2:v=0:a=1,loudnorm=I=-22:TP=-2",
         "-ar", "44100", "-c:a", "aac", "-b:a", "128k", f"{OUT}/{name}.m4a"])
for f in sorted(os.listdir(OUT)):
    d = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f"{OUT}/{f}"], capture_output=True, text=True).stdout.strip()
    print(f, d, os.path.getsize(f"{OUT}/{f}"))
