"""Deterministic PBR data maps for the existing gear and MakeHuman UVs.

Run with Blender's bundled Python (numpy), or any Python with numpy:
  python surface_detail.py --out B2BCrowd/Resources/Textures
No diffuse photo, alpha, mesh, skeleton or animated control is replaced.
Panel coordinates are metres from gear.py; skin zones use the verified
shared MakeHuman skin atlas. Small maps are shared by all character LODs.
"""
from pathlib import Path
import argparse, json, math, struct, zlib
import numpy as np


def png(path, a):
    a = np.round(np.clip(a, 0, 1) * 255).astype(np.uint8)
    height, width = a.shape[:2]
    channels = 1 if a.ndim == 2 else a.shape[2]
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\0' + row.tobytes() for row in a)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0 if channels == 1 else 2, 0, 0, 0))
    path.write_bytes(data + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))


def grid(n=256, h=None):
    h = h or n
    # PNG rows go down; the verified Collada UV v goes up.
    return np.meshgrid((np.arange(n) + .5) / n, 1 - (np.arange(h) + .5) / h)


def field(u, v, seed):
    rng = np.random.default_rng(seed)
    result = np.zeros_like(u)
    for frequency, amplitude in [(2, .5), (5, .25), (11, .15), (27, .08)]:
        phase = rng.uniform(0, math.tau, 2)
        result += amplitude * np.sin(math.tau * u * frequency + phase[0]) * np.cos(math.tau * v * (frequency + 1) + phase[1])
    return result


def normal(height, strength=.2):
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dy = -(np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    n = np.stack([-dx, -dy, np.ones_like(dx)], axis=-1)
    n /= np.linalg.norm(n, axis=-1)[..., None]
    return n * .5 + .5


def oval(x, y, cx, cy, rx, ry):
    return np.exp(-(((x - cx) / rx)**2 + ((y - cy) / ry)**2) * 2)


def panel(out, kind, seed):
    w, d = ((1.69, .74) if kind == 'booth' else (.256, .406) if kind == 'mixer' else (.316, .406))
    u, v = grid(512, 256 if kind == 'booth' else 512)
    x, y = (u - .5) * w, (v - .5) * d
    rng = np.random.default_rng(seed)
    touch = np.zeros_like(x)
    if kind.startswith('deck'):
        sx = -.12 if kind == 'deck_a' else .12
        contacts = [(sx, -.155, .025, .022), (sx, -.11, .025, .024),
                    (0, -.048, .10, .085), (sx * -.75, .15, .019, .024)]
        # Finger drag alongside the tempo slider, not over the entire panel.
        touch += oval(x, y, -sx / .12 * .14, -.04, .012, .083) * .48
    elif kind == 'mixer':
        contacts = [(cx, yy, .022, .024) for cx in [-.055, .055] for yy in [.17, .125, .08, .035, -.015]]
        contacts += [(0, -.185, .055, .017)]
        for cx in [-.055, .055]: touch += oval(x, y, cx, -.095, .019, .056) * .70
    else:
        contacts = [(-.46, -.29, .115, .040), (.49, -.28, .1, .04), (.6, -.25, .045, .045)]
    for cx, cy, rx, ry in contacts:
        # Slightly displaced partial impressions, not conspicuous full prints.
        cx += rng.uniform(-.004, .004); cy += rng.uniform(-.004, .004)
        patch = oval(x, y, cx, cy, rx, ry)
        ridge = .82 + .18 * np.sin((x - cx) * 1600 + np.sin((y - cy) * 80) * 2.5)
        touch += patch * ridge * rng.uniform(.5, .85)
    touch = np.clip(touch, 0, 1)
    variation = field(u, v, seed)
    scratches = np.zeros_like(x)
    # Sparse, sub-millimetre hairlines concentrated near active controls/edge.
    for _ in range(44 if kind != 'booth' else 26):
        cx, cy = rng.uniform(-w * .46, w * .46), rng.uniform(-d * .46, d * .46)
        length = rng.uniform(.003, .018)
        angle = rng.uniform(-.35, .35) + (math.pi / 2 if rng.random() < .25 else 0)
        along = (x - cx) * math.cos(angle) + (y - cy) * math.sin(angle)
        across = -(x - cx) * math.sin(angle) + (y - cy) * math.cos(angle)
        scratches += np.exp(-((across / .00026)**2) * 2) * np.exp(-((along / length)**6)) * rng.uniform(.15, .5)
    edge = np.exp(-((np.minimum(u, 1-u) * w / .004)**2)) + np.exp(-((np.minimum(v, 1-v) * d / .004)**2))
    edge *= .4 + .6 * (variation + 1) * .5
    rough = (.64 if kind != 'booth' else .61) + variation * .033 - touch * .22 + scratches * .09 - edge * .028
    # Subtle colour changes; no rust, mud or damage to the existing labels.
    linear = np.clip(.992 + variation * .007 - touch * .022 - scratches * .016, .93, 1)
    colour = np.stack([linear, linear * .998, linear * .996], axis=-1) ** (1 / 2.2)
    h = variation * .018 - scratches * .13 + np.sin(u * math.tau * 117) * .006
    png(out / f'{kind}_use_rough.png', rough)
    png(out / f'{kind}_use_multiply.png', colour)
    png(out / f'{kind}_use_normal.png', normal(h, .7))
    return {'rough_min': float(rough.min()), 'rough_max': float(rough.max()), 'contact_fraction': float((touch > .15).mean())}


def chrome_roughness():
    # Band-limited, isotropic roughness breaks the previous sine-product grid.
    # A polished surface gets restrained, irregular handling marks, not tiles.
    n = 256
    rng = np.random.default_rng(31)
    white = rng.normal(size=(n, n))
    f = np.fft.fftfreq(n) * n
    fx, fy = np.meshgrid(f, f)
    spec = np.fft.fft2(white) * np.exp(-(fx*fx + fy*fy) / (2 * 5.5**2))
    smooth = np.real(np.fft.ifft2(spec))
    smooth /= max(float(smooth.std()), 1e-6)
    return .245 + np.tanh(smooth * .55) * .035


def generate(out):
    out.mkdir(parents=True, exist_ok=True)
    report = {k: panel(out, k, i + 105) for i, k in enumerate(['deck_a','deck_b','mixer','booth'])}
    u, v = grid()
    f = field(u, v, 13)
    # Fine moulded polymer; handled controls are smoother, cables stay matte.
    polymer = np.sin(u * math.tau * 91) * np.cos(v * math.tau * 83) * .12 + field(u, v, 41) * .1
    png(out / 'polymer_detail_normal.png', normal(polymer, .4))
    png(out / 'polymer_use_rough.png', .50 + f * .075)
    png(out / 'rubber_use_rough.png', .78 + field(u, v, 19) * .035)
    png(out / 'metal_use_rough.png', .38 + field(u, v, 29) * .065 + np.sin(v * math.tau * 83) * .012)
    png(out / 'chrome_use_rough.png', chrome_roughness())
    # Twill weave at submillimetre scale; diffuse textures already hold folds.
    weave = np.sin(u * math.tau * 64) * .20 + np.sin(v * math.tau * 64) * .18
    weave += np.sin((u + v) * math.tau * 32) * .07
    png(out / 'fabric_detail_normal.png', normal(weave, .22))
    png(out / 'fabric_detail_rough.png', .79 + field(u, v, 21) * .075)
    png(out / 'hair_detail_rough.png', .49 + field(u, v, 37) * .065 + np.sin(u * math.tau * 58) * .04)
    # The inspected male/female MakeHuman textures share this atlas layout.
    # Colour is retained from their original complexion, age and lip textures.
    u, v = grid(512)
    row = 1 - v
    forehead = oval(u, row, .791, .524, .044, .060)
    nose = oval(u, row, .868, .522, .026, .025)
    lip = oval(u, row, .910, .520, .012, .017)
    cheeks = oval(u, row, .863, .463, .023, .036) + oval(u, row, .864, .584, .023, .036)
    hands = oval(u, row, .47, .930, .067, .040) + oval(u, row, .651, .929, .071, .040)
    zones = .55 + field(u, v, 81) * .014 - forehead * .15 - nose * .19 - lip * .22 - cheeks * .035 - hands * .075
    png(out / 'skin_zone_rough.png', zones)
    colour = np.ones((*u.shape, 3)) * .994
    colour += field(u, v, 83)[..., None] * .0025
    colour[..., 1] -= cheeks * .016
    colour[..., 2] -= cheeks * .019
    png(out / 'skin_zone_multiply.png', colour ** (1 / 2.2))
    report['skin'] = {'rough_min':float(zones.min()),'rough_max':float(zones.max()),'forehead':.40,'nose':.36,'lips':.33,'body':.55}
    files = sorted(out.glob('*.png'))
    report['files'] = [{'name':p.name, 'bytes':p.stat().st_size} for p in files]
    report['encoded_bytes'] = sum(p.stat().st_size for p in files)
    (out / 'surface_detail_report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({k:v for k,v in report.items() if k != 'files'}, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--chrome-only', action='store_true')
    args = p.parse_args()
    if args.chrome_only:
        args.out.mkdir(parents=True, exist_ok=True)
        png(args.out / 'chrome_use_rough.png', chrome_roughness())
        print('Generated one refined chrome roughness map.')
    else:
        generate(args.out)
