# 肌の細かい凹凸（毛穴・小じわ）を、継ぎ目なく並べられる法線マップと粗さマップとして作る
import numpy as np
from PIL import Image
N = 512
rng = np.random.default_rng(5)
def tile_noise(scale, amp):
    # 周期的なノイズ（FFT で作るので端がつながる）
    f = np.fft.fftfreq(N)
    fx, fy = np.meshgrid(f, f)
    r = np.sqrt(fx ** 2 + fy ** 2) + 1e-6
    spec = (rng.normal(size=(N, N)) + 1j * rng.normal(size=(N, N))) * np.exp(-((r * N / scale) - 1) ** 2 * 0.5) / r ** 0.5
    n = np.real(np.fft.ifft2(spec))
    return (n - n.mean()) / n.std() * amp
h = tile_noise(70, 1.0) + tile_noise(28, 0.6) + tile_noise(9, 0.25)
# 毛穴：小さなくぼみを散らす
pores = np.zeros((N, N))
for _ in range(2600):
    x, y = rng.integers(0, N, 2)
    pores[y % N, x % N] -= rng.uniform(0.6, 1.4)
k = np.fft.fft2(pores) * np.exp(-(np.fft.fftfreq(N)[None, :] ** 2 + np.fft.fftfreq(N)[:, None] ** 2) * (N / 2.2) ** 2 * 0.02)
pores = np.real(np.fft.ifft2(k))
h = h + pores / np.abs(pores).max() * 1.6
# 法線マップ（端をまたいで差分）
dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
s = 0.35
n = np.dstack([-dx * s, -dy * s, np.ones_like(h)])
n /= np.linalg.norm(n, axis=2, keepdims=True)
Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save("C:/Users/Windows/B2BCrowd/B2BCrowd/Resources/Textures/skin_detail_normal.png")
# 粗さ：毛穴の中は少し粗く、張ったところは少しつやっぽく
r = 0.5 + np.clip(-h * 0.06, -0.12, 0.15)
Image.fromarray((np.clip(r, 0, 1) * 255).astype(np.uint8)).save("C:/Users/Windows/B2BCrowd/B2BCrowd/Resources/Textures/skin_detail_rough.png")
print("ok")
