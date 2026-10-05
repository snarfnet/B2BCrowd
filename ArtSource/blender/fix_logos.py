# MakeHuman のロゴ入り T シャツから、ロゴを塗りつぶして無地にする
import os, shutil, cv2, numpy as np
D = os.path.expandvars(r'%APPDATA%\Blender Foundation\Blender\4.4\extensions\.user\user_default\mpfb\data\clothes')
BOXES = {  # 正規化座標 (x0, y0, x1, y1)
    'female_casualsuit01': (0.69, 0.10, 0.95, 0.36),
    'male_casualsuit02': (0.43, 0.09, 0.64, 0.33),
    'male_casualsuit04': (0.45, 0.09, 0.64, 0.33),
    'female_casualsuit02': (0.69, 0.10, 0.95, 0.36),
    'male_casualsuit06': (0.18, 0.08, 0.78, 0.22),
}
for c, (x0, y0, x1, y1) in BOXES.items():
    p = os.path.join(D, c, c + '_diffuse.png')
    orig = p + '.orig.png'
    if not os.path.exists(orig):
        shutil.copy(p, orig)
    img = cv2.imread(orig, cv2.IMREAD_UNCHANGED)
    h, w = img.shape[:2]
    X0, Y0, X1, Y1 = int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h)
    roi = img[Y0:Y1, X0:X1, :3].astype(np.int32)
    med = np.median(roi.reshape(-1, 3), axis=0)
    dist = np.abs(roi - med).sum(axis=2)
    mask = np.zeros((h, w), np.uint8)
    mask[Y0:Y1, X0:X1] = (dist > 45).astype(np.uint8) * 255
    mask = cv2.dilate(mask, np.ones((9, 9), np.uint8))
    bgr = img[:, :, :3].copy()
    fixed = cv2.inpaint(bgr, mask, 9, cv2.INPAINT_TELEA)
    img[:, :, :3] = fixed
    cv2.imwrite(p, img)
    cv2.imwrite(os.path.join(os.path.dirname(__file__), '..', 'out', c + '_fixed_preview.png'), cv2.resize(img[Y0 - 40:Y1 + 40, X0 - 40:X1 + 40], None, fx=0.5, fy=0.5))
    print('fixed', c, int((mask > 0).sum()))
