"""SpoofScope core: per-patch feature extraction and inference.
Pure numpy / scipy / OpenCV / scikit-image. No deep-learning framework needed."""
import re, hashlib
import numpy as np, cv2
from scipy import ndimage as ndi
from skimage.feature import local_binary_pattern

SIZE = 640          # images are resized to SIZE x SIZE
GRID = 16           # patch size in pixels -> 40 x 40 patches
N = SIZE // GRID

FEATURE_NAMES = (
    ["mean", "std", "p10", "p90", "dark_frac", "white_frac", "grad", "coherence", "orient_break",
     "ridge_band", "ridge_period", "bright_blob", "dark_blob", "cross_line", "rel_contrast"]
    + [f"lbp{i}" for i in range(10)]
    + [f"nb_{k}" for k in ("mean", "std", "coherence", "ridge_band", "dark_frac", "white_frac")]
)
D = len(FEATURE_NAMES)

FNAME_RE = re.compile(r"([0-9A-Fa-f]{12})_(\d{14})")


def file_md5(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(chunk), b""):
            h.update(b)
    return h.hexdigest()


def parse_name(path):
    """Return (MAC, timestamp) from names like Imag_640x640_50_AABBCCDDEEFF_01012025120000.jpg."""
    m = FNAME_RE.search(str(path))
    return (m.group(1).upper(), m.group(2)) if m else (None, None)


def load_gray(path):
    im = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if im is None:
        raise ValueError(f"cannot read image {path}")
    if im.shape != (SIZE, SIZE):
        im = cv2.resize(im, (SIZE, SIZE), interpolation=cv2.INTER_AREA)
    return im.astype(np.float32) / 255.0


def print_mask(g):
    """Pixel mask of the fingerprint area (ridge texture = high local variance)."""
    mu = cv2.GaussianBlur(g, (0, 0), 6)
    var = cv2.GaussianBlur(g * g, (0, 0), 6) - mu * mu
    s = np.sqrt(np.clip(var, 0, None))
    s8 = np.clip(s / (s.max() + 1e-6) * 255, 0, 255).astype(np.uint8)
    _, m = cv2.threshold(s8, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (31, 31))
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, k)
    m = ndi.binary_fill_holes(m > 0)
    m = ndi.binary_opening(m, structure=np.ones((9, 9)))
    lab, n = ndi.label(m)
    if n == 0:
        return np.ones_like(g, bool)
    sizes = ndi.sum(m, lab, range(1, n + 1))
    return lab == (1 + int(np.argmax(sizes)))


def _blocks(a):
    return a[: N * GRID, : N * GRID].reshape(N, GRID, N, GRID).swapaxes(1, 2).reshape(N, N, GRID * GRID)


def _hessian(img, s):
    hxx = ndi.gaussian_filter(img, s, order=(0, 2))
    hyy = ndi.gaussian_filter(img, s, order=(2, 0))
    hxy = ndi.gaussian_filter(img, s, order=(1, 1))
    return hxx * s * s, hyy * s * s, hxy * s * s


def patch_features(g, mask=None):
    """Return (feats[N,N,D] float32, block_mask[N,N] bool)."""
    if mask is None:
        mask = print_mask(g)
    bmask = _blocks(mask.astype(np.float32)).mean(-1) > 0.6
    if bmask.sum() < 4:
        bmask = np.ones((N, N), bool)

    # contrast-normalised image: ink -> 0, paper -> 1
    lo = np.percentile(g[mask], 5) if mask.any() else g.min()
    hi = np.percentile(g[~mask], 50) if (~mask).sum() > 100 else np.percentile(g, 99)
    gn = np.clip((g - lo) / max(hi - lo, 1e-3), 0, 1.2).astype(np.float32)

    B = _blocks(g)
    mean, std = B.mean(-1), B.std(-1)
    p10, p90 = np.percentile(B, 10, -1), np.percentile(B, 90, -1)
    Bn = _blocks(gn)
    dark, white = (Bn < 0.15).mean(-1), (Bn > 0.85).mean(-1)

    gx = cv2.Sobel(gn, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gn, cv2.CV_32F, 0, 1, ksize=3)
    grad = _blocks(np.hypot(gx, gy)).mean(-1)

    # structure tensor -> ridge orientation and coherence
    jxx = cv2.GaussianBlur(gx * gx, (0, 0), 4)
    jyy = cv2.GaussianBlur(gy * gy, (0, 0), 4)
    jxy = cv2.GaussianBlur(gx * gy, (0, 0), 4)
    bxx, byy, bxy = _blocks(jxx).mean(-1), _blocks(jyy).mean(-1), _blocks(jxy).mean(-1)
    coh = np.sqrt((bxx - byy) ** 2 + 4 * bxy ** 2) / (bxx + byy + 1e-6)
    theta = 0.5 * np.arctan2(2 * bxy, bxx - byy)            # gradient orientation per block
    c2, s2 = np.cos(2 * theta), np.sin(2 * theta)
    mc, ms = ndi.uniform_filter(c2, 3), ndi.uniform_filter(s2, 3)
    nrm = np.hypot(mc, ms) + 1e-6
    orient_break = 1 - (c2 * mc + s2 * ms) / nrm

    # ridge periodicity in 32x32 windows centred on each block
    pad = np.pad(gn, 8, mode="reflect")
    win = np.lib.stride_tricks.sliding_window_view(pad, (32, 32))[::GRID, ::GRID][:N, :N]
    win = (win - win.mean(axis=(-1, -2), keepdims=True)) * np.outer(np.hanning(32), np.hanning(32))
    F = np.abs(np.fft.fft2(win)) ** 2
    fy, fx = np.meshgrid(np.fft.fftfreq(32) * 32, np.fft.fftfreq(32) * 32, indexing="ij")
    rad = np.hypot(fy, fx)
    band = (rad >= 2.5) & (rad <= 5.5)                      # ~6-13 px ridge period
    tot = F[..., rad > 0.5].sum(-1) + 1e-9
    ridge_band = F[..., band].sum(-1) / tot
    rb = np.round(rad).astype(int)
    radial = np.stack([F[..., rb == r].sum(-1) for r in range(2, 8)], -1)
    ridge_period = 32.0 / (2 + np.argmax(radial, -1))

    # bright blobs (voids/bubbles) and dark blobs (fused areas) via Hessian determinant
    hxx, hyy, hxy = _hessian(gn, 2.5)
    det, tr = hxx * hyy - hxy ** 2, hxx + hyy
    bright = np.where((tr < 0) & (det > 0), det, 0)
    hxx8, hyy8, hxy8 = _hessian(gn, 8.0)
    det8, tr8 = hxx8 * hyy8 - hxy8 ** 2, hxx8 + hyy8
    darkb = np.where((tr8 > 0) & (det8 > 0), det8, 0)
    bright_blob, dark_blob = _blocks(bright).max(-1), _blocks(darkb).max(-1)

    # bright thin lines running ACROSS the ridge flow (tears / cracks)
    h1, h2, h3 = _hessian(gn, 1.5)
    tmp = np.sqrt(((h1 - h2) / 2) ** 2 + h3 ** 2)
    lam = (h1 + h2) / 2 - tmp                                # most negative eigenvalue
    phi = 0.5 * np.arctan2(2 * h3, h1 - h2) + np.pi / 2      # direction of the bright line
    th_px = 0.5 * np.arctan2(2 * jxy, jxx - jyy) + np.pi / 2 # ridge flow direction
    cross = np.abs(np.sin(phi - th_px))
    cross_line = _blocks(np.clip(-lam, 0, None) * cross ** 2).mean(-1)

    ref = np.median(std[bmask]) + 1e-6
    rel_contrast = std / ref

    lbp = local_binary_pattern((np.clip(gn, 0, 1) * 255).astype(np.uint8), 8, 1, "uniform")
    L = _blocks(lbp).astype(int)
    lbp_h = np.stack([(L == i).mean(-1) for i in range(10)], -1)

    def nb(f):
        return np.abs(f - ndi.median_filter(f, size=3))

    feats = np.dstack([mean, std, p10, p90, dark, white, grad, coh, orient_break,
                       ridge_band, ridge_period, bright_blob, dark_blob, cross_line, rel_contrast,
                       lbp_h, nb(mean), nb(std), nb(coh), nb(ridge_band), nb(dark), nb(white)]).astype(np.float32)
    return feats, bmask


# ---------------------------------------------------------------- inference
def head_scores(models, feats, bmask, head):
    """Per-patch score map in [0,1] for the chosen head (NaN outside print)."""
    X = models["scaler"].transform(feats[bmask].astype(np.float64)).astype(np.float32)
    out = np.full((N, N), np.nan, np.float32)
    if head == "rarity":
        r = -models["iso"].score_samples(X)
        lo, hi = models["iso_norm"]
        s = np.clip((r - lo) / (hi - lo + 1e-9), 0, 1)
    else:
        clf = models["heads"][head]["model"]
        pos = models["heads"][head]["positive"]
        P = clf.predict_proba(X)
        if pos is None:   # multi-class (material): confidence of the top class
            s = P.max(1)
        else:
            s = P[:, list(clf.classes_).index(pos)]
    out[bmask] = s
    return out


def image_score(score_map, top=0.1):
    v = np.sort(score_map[~np.isnan(score_map)])[::-1]
    if v.size == 0:
        return 0.0
    return float(v[: max(1, int(len(v) * top))].mean())


def evidence_search(score_map, thr_img, top=0.1):
    """'Move search': remove the strongest patches one at a time until the image-level
    score (mean of the top-10% patches) drops below thr_img.
    Returns the removed patches [(row, col, score), ...] in order, or None if even
    removing every patch never brings the score below the threshold."""
    flat = np.nan_to_num(score_map, nan=-1).ravel()
    order = np.argsort(-flat)
    order = order[flat[order] >= 0]
    v = flat[order]
    n = v.size
    if n == 0:
        return []
    cs = np.concatenate([[0], np.cumsum(v)])
    for j in range(n):
        k = max(1, int((n - j) * top))
        if (cs[j + k] - cs[j]) / k < thr_img:
            return [(int(i) // N, int(i) % N, float(flat[i])) for i in order[:j]]
    return None


def find_regions(models, feats, bmask, score_map, thr, min_patches=1):
    """Connected flagged regions, each assigned a feature type by the clustering head."""
    flag = np.nan_to_num(score_map, nan=0) >= thr
    lab, n = ndi.label(flag, structure=np.ones((3, 3)))
    regions = []
    km = models.get("kmeans")
    names = models.get("cluster_names", {})
    for k in range(1, n + 1):
        rr, cc = np.where(lab == k)
        if rr.size < min_patches:
            continue
        t = "unknown"
        if km is not None:
            X = models["scaler"].transform(feats[rr, cc].astype(np.float64)).astype(np.float32)
            labels = km.predict(X)
            t = names.get(str(int(np.bincount(labels).argmax())), f"type_{int(np.bincount(labels).argmax())}")
        regions.append(dict(id=k, type=t, patches=int(rr.size),
                            peak=float(np.nanmax(score_map[rr, cc])),
                            box=(int(cc.min() * GRID), int(rr.min() * GRID),
                                 int((cc.max() + 1) * GRID), int((rr.max() + 1) * GRID))))
    return regions


def heat_mask(score_map, floor=0.3):
    m = np.nan_to_num(score_map, nan=0) >= floor
    return cv2.resize(m.astype(np.uint8), (SIZE, SIZE), interpolation=cv2.INTER_NEAREST) > 0


def overlay(g, score_map, regions, alpha=0.45):
    base = cv2.cvtColor((g * 255).astype(np.uint8), cv2.COLOR_GRAY2BGR)
    sm = np.nan_to_num(score_map, nan=0)
    heat = cv2.resize(sm, (SIZE, SIZE), interpolation=cv2.INTER_CUBIC)
    heat = cv2.applyColorMap((np.clip(heat, 0, 1) * 255).astype(np.uint8), cv2.COLORMAP_JET)
    valid = cv2.resize((~np.isnan(score_map)).astype(np.uint8), (SIZE, SIZE), interpolation=cv2.INTER_NEAREST) > 0
    valid &= heat_mask(score_map)
    out = base.copy()
    out[valid] = cv2.addWeighted(base, 1 - alpha, heat, alpha, 0)[valid]
    for r in regions:
        x0, y0, x1, y1 = r["box"]
        cv2.rectangle(out, (x0, y0), (x1, y1), (255, 255, 255), 2)
        cv2.putText(out, r["type"][:14], (x0, max(12, y0 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
    return cv2.cvtColor(out, cv2.COLOR_BGR2RGB)
