"""SpoofScope pipeline: index -> extract -> train. Used by the app and by run_pipeline.py."""
import os, glob, json, time
import numpy as np, pandas as pd, joblib
from joblib import Parallel, delayed
from sklearn.preprocessing import StandardScaler
from sklearn.ensemble import IsolationForest, HistGradientBoostingClassifier
from sklearn.cluster import MiniBatchKMeans
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.metrics import roc_auc_score
import config, core

def material_of(folder, rules):
    f = folder.lower()
    for key, mat in rules:
        if key in f:
            return mat
    return f.split("_")[0]


def load_csvs(root, log=print):
    frames = []
    for p in glob.glob(os.path.join(root, "**", "Model_*.csv"), recursive=True):
        try:
            df = pd.read_csv(p)
        except Exception as e:
            log(f"skip csv {p}: {e}"); continue
        df.columns = [c.strip() for c in df.columns]
        need = {"Version", "MAC ID", "ImageName", "F_Live", "F_Spoof"}
        if not need.issubset(df.columns):
            log(f"skip csv (columns) {p}"); continue
        # one row usually has a blank version: give it the version that is one row short
        if df["Version"].isna().any():
            vc = df["Version"].value_counts()
            short = vc[vc == vc.max() - 1]
            df["Version"] = df["Version"].fillna(short.index[0] if len(short) == 1 else "unknown")
        df["MAC"] = df["MAC ID"].astype(str).str.strip().str.upper()
        df["ts"] = df["ImageName"].astype("int64").astype(str).str.zfill(14)
        df["csv_file"] = os.path.relpath(p, root)
        frames.append(df)
    return pd.concat(frames, ignore_index=True) if frames else None


def build_index(root, settings=None, log=print):
    settings = settings or config.load()
    if not root or not os.path.isdir(root):
        raise ValueError(f"Data folder not found: {root!r}")
    os.makedirs(config.WORK_DIR, exist_ok=True)

    rows, seen = [], {}
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.lower().endswith(config.IMAGE_EXT) or fn.startswith("."):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root)
            parts = rel.split(os.sep)
            top = parts[0] if len(parts) > 1 else "(root)"
            tags = [x for x in parts[1:-1]]
            h = core.file_md5(p)
            if h in seen:   # duplicate copy: just add its folder tags
                r = rows[seen[h]]
                r["tags"] = ";".join(sorted((set(r["tags"].split(";")) | set(tags)) - {""}))
                r["n_copies"] += 1
                continue
            mac, ts = core.parse_name(fn)
            seen[h] = len(rows)
            rows.append(dict(id=h, path=p, folder=top, material=material_of(top, settings["material_rules"]),
                             tags=";".join(tags), mac=mac, ts=ts, n_copies=1))
    idx = pd.DataFrame(rows)
    if idx.empty:
        raise ValueError(f"No images found under {root}")
    idx["is_live"] = idx["material"].isin(settings["live_materials"])

    csv = load_csvs(root, log)
    if csv is not None:
        csv["fooled"] = csv["F_Live"] > csv["F_Spoof"]
        csv["p_spoof"] = csv["F_Spoof"] / (csv["F_Live"] + csv["F_Spoof"]).clip(lower=1)
        agg = csv.groupby(["MAC", "ts"]).agg(prod_p_spoof=("p_spoof", "mean"),
                                             prod_p_spoof_std=("p_spoof", "std"),
                                             n_versions=("Version", "nunique"),
                                             n_fooled=("fooled", "sum"),
                                             quality=("Quality", "first")).reset_index()
        piv = csv.pivot_table(index=["MAC", "ts"], columns="Version", values="fooled", aggfunc="max").astype(float)
        piv.columns = [f"fooled_{c}" for c in piv.columns]
        agg = agg.merge(piv.reset_index(), on=["MAC", "ts"], how="left")
        idx = idx.merge(agg, left_on=["mac", "ts"], right_on=["MAC", "ts"], how="left").drop(columns=["MAC"])
        csv.to_csv(os.path.join(config.WORK_DIR, "production_scores_long.csv"), index=False)
        log(f"CSV rows: {len(csv)}  images matched to CSV: {idx['n_versions'].notna().sum()}")
    idx.to_csv(os.path.join(config.WORK_DIR, "index.csv"), index=False)
    log(f"Unique images: {len(idx)}  (duplicates skipped: {int(idx['n_copies'].sum() - len(idx))})")
    log(idx.groupby("material").size().to_string())
    return idx


def feat_dir(backend):
    return os.path.join(config.WORK_DIR, "feats" if backend == "classic" else "feats_" + backend)


def backend_now():
    b = config.load().get("backend", "classic")
    return b if (b == "classic" or core.dino_available()) else "classic"


def load_pca(backend):
    p = os.path.join(feat_dir(backend), "pca.joblib")
    return joblib.load(p) if os.path.exists(p) else None


def _fit_pca(rows, backend, log):
    """Fit the DINOv2 token -> 96-number PCA on a sample of up to 120 images."""
    from sklearn.decomposition import PCA
    rng_ = np.random.default_rng(1)
    pick = [rows[i] for i in rng_.choice(len(rows), min(120, len(rows)), replace=False)]
    T = []
    for i, r in enumerate(pick):
        g = core.load_gray(r["path"])
        _, b = core.patch_features(g)
        T.append(core.dino_tokens(g)[b])
        log(f"PCA sample {i + 1}/{len(pick)}") if (i + 1) % 20 == 0 else None
    T = np.concatenate(T)
    pca = PCA(n_components=core.DINO_PCS, random_state=0).fit(T)
    joblib.dump(pca, os.path.join(feat_dir(backend), "pca.joblib"))
    log(f"PCA fitted on {len(T)} patches; {pca.explained_variance_ratio_.sum():.0%} of DINOv2 variance kept")
    return pca


def _extract_one(row, backend="classic", pca=None):
    out = os.path.join(feat_dir(backend), row["id"] + ".npz")
    if os.path.exists(out):
        return "skip"
    try:
        g = core.load_gray(row["path"])
        f, b = core.compute_features(g, backend, pca)
        np.savez_compressed(out, feats=f.astype(np.float16), bmask=b)
        return "ok"
    except Exception as e:
        return f"error {row['path']}: {e}"


def read_index():
    return pd.read_csv(os.path.join(config.WORK_DIR, "index.csv"), dtype={"ts": str})


def extract(limit=0, progress=None, log=print, backend=None):
    """Compute patch features for indexed images (resumable). progress(done, total) is optional."""
    backend = backend or backend_now()
    os.makedirs(feat_dir(backend), exist_ok=True)
    idx = read_index()
    if limit:
        idx = idx.groupby("material", group_keys=False).apply(lambda d: d.head(max(1, limit // idx.material.nunique())))
    rows = idx.to_dict("records")
    t = time.time()
    pca = None
    if backend == "dino":
        pca = load_pca(backend) or _fit_pca(rows, backend, log)
    log(f"extracting {len(rows)} images with backend '{backend}'")
    if progress is None and config.N_JOBS > 1 and backend == "classic":
        res = Parallel(n_jobs=config.N_JOBS, verbose=5)(delayed(_extract_one)(r) for r in rows)
    else:
        res = []
        for i, r in enumerate(rows):
            res.append(_extract_one(r, backend, pca))
            if progress:
                progress(i + 1, len(rows))
    errs = [r for r in res if r.startswith("error")]
    log(f"done {len(res)} images in {time.time() - t:.0f}s, errors: {len(errs)}")
    for e in errs[:10]:
        log("  " + e)
    return len(res), errs


MAX_HEAD_PATCHES = 400_000
rng = np.random.default_rng(0)


def load_sample(idx, FEAT_DIR):
    X, img, rc = [], [], []
    for i, row in enumerate(idx.itertuples()):
        z = np.load(os.path.join(FEAT_DIR, row.id + ".npz"))
        f, b = z["feats"].astype(np.float32), z["bmask"]
        rr, cc = np.where(b)
        if rr.size == 0:
            continue
        k = rng.choice(rr.size, min(config.PATCHES_PER_IMAGE, rr.size), replace=False)
        X.append(f[rr[k], cc[k]]); img.append(np.full(k.size, i)); rc.append(np.c_[rr[k], cc[k]])
    return np.concatenate(X), np.concatenate(img), np.concatenate(rc)


def topk_mean(v, top=0.1):
    v = np.sort(v)[::-1]
    return v[: max(1, int(len(v) * top))].mean()


def fit_head(name, X, y_img, img, positive, report, log=print, max_iter=200):
    """Patch-level classifier trained with image-level labels; evaluated per image with
    grouped cross-validation (no image appears in both train and test)."""
    y = y_img[img]
    sel = np.arange(len(y))
    if len(sel) > MAX_HEAD_PATCHES:
        sel = rng.choice(sel, MAX_HEAD_PATCHES, replace=False)
    mk = lambda: HistGradientBoostingClassifier(max_iter=max_iter, learning_rate=0.08,
                                                class_weight="balanced", random_state=0)
    # --- grouped CV at image level
    n_img_cls = pd.Series(y_img).value_counts()
    folds = int(min(5, n_img_cls.min()))
    metric = None
    if folds >= 2:
        cv = StratifiedGroupKFold(n_splits=folds, shuffle=True, random_state=0)
        img_true, img_pred = [], []
        for tr, te in cv.split(X[sel], y[sel], img[sel]):
            m = mk().fit(X[sel][tr], y[sel][tr])
            P = m.predict_proba(X[sel][te]); cls = list(m.classes_)
            for im in np.unique(img[sel][te]):
                msk = img[sel][te] == im
                if positive is None:
                    img_pred.append(cls[int(np.argmax(np.log(P[msk] + 1e-6).sum(0)))])
                else:
                    img_pred.append(topk_mean(P[msk][:, cls.index(positive)]))
                img_true.append(y_img[im])
        if positive is None:
            metric = {"image_accuracy": float(np.mean(np.array(img_true) == np.array(img_pred))), "folds": folds}
        else:
            t = (np.array(img_true) == positive).astype(int)
            metric = {"image_AUC": float(roc_auc_score(t, img_pred)) if 0 < t.sum() < len(t) else None, "folds": folds}
    model = mk().fit(X[sel], y[sel])
    report["heads"][name] = {"n_images": int(len(y_img)), "classes": {str(k): int(v) for k, v in n_img_cls.items()},
                             "cv": metric}
    log(f"  head {name}: {report['heads'][name]}")
    return {"model": model, "positive": positive}


def train(log=print, backend=None):
    W = config.WORK_DIR
    backend = backend or backend_now()
    FEAT_DIR = feat_dir(backend)
    log(f"training on backend '{backend}'")
    t0 = time.time()
    idx = read_index()
    idx = idx[idx["id"].map(lambda h: os.path.exists(os.path.join(FEAT_DIR, h + ".npz")))].reset_index(drop=True)
    if idx.empty:
        raise ValueError("No features found. Run feature extraction first.")
    log(f"images with features: {len(idx)}")
    X, img, rc = load_sample(idx, FEAT_DIR)
    log(f"patches sampled: {len(X)}  ({X.nbytes / 1e6:.0f} MB)")
    scaler = StandardScaler().fit(X)
    Xs = scaler.transform(X).astype(np.float32)
    report = {"backend": backend, "n_images": int(len(idx)), "n_patches": int(len(X)), "heads": {}, "warnings": []}

    # ---- rarity head (unsupervised)
    live = idx["is_live"].values.astype(bool)
    ref = live[img] if live.any() else np.ones(len(img), bool)
    iso = IsolationForest(n_estimators=200, max_samples=4096, random_state=0, n_jobs=config.N_JOBS)
    ref_idx = np.where(ref)[0]
    if ref_idx.size > MAX_HEAD_PATCHES:
        ref_idx = rng.choice(ref_idx, MAX_HEAD_PATCHES, replace=False)
    iso.fit(Xs[ref_idx])
    r = -iso.score_samples(Xs)
    iso_norm = (float(np.percentile(r[ref], 50)), float(np.percentile(r[ref], 99.5)))
    rar = np.clip((r - iso_norm[0]) / (iso_norm[1] - iso_norm[0] + 1e-9), 0, 1)
    report["heads"]["rarity"] = {"reference": "live patches" if live.any() else "all patches (no live data)"}
    heads = {}

    # ---- material head
    mats = idx["material"].values
    if len(set(mats)) >= 2:
        heads["material"] = fit_head("material", Xs, mats, img, None, report, log)
        mac_mats = idx.dropna(subset=["mac"]).groupby("mac")["material"].nunique()
        shared = idx["mac"].map(mac_mats).fillna(1) >= 2
        if shared.mean() < 0.5:
            report["warnings"].append("Most devices (MAC IDs) captured only one material. The material head may be "
                                      "learning the device, not the material. Treat its accuracy as optimistic.")
    # ---- live vs spoof head
    if live.any() and (~live).any():
        lab = np.where(live, "live", "spoof")
        heads["live_vs_spoof"] = fit_head("live_vs_spoof", Xs, lab, img, "spoof", report, log)
    # ---- hard-case head (production model fooled?)
    if "n_fooled" in idx:
        has = idx["n_fooled"].notna().values & ~live
        lab = np.where(idx["n_fooled"].fillna(0).values > 0, "fooled", "caught")
        if has.sum() >= 10 and (lab[has] == "fooled").sum() >= 3 and (lab[has] == "caught").sum() >= 3:
            keep = has[img]
            remap = {old: new for new, old in enumerate(np.where(has)[0])}
            img_h = np.array([remap[i] for i in img[keep]])
            heads["hard_case"] = fit_head("hard_case", Xs[keep], lab[has], img_h, "fooled", report, log)
        else:
            report["warnings"].append("Not enough CSV-matched images with both fooled and caught cases for the hard_case head.")

    # ---- feature types: cluster the most unusual patches
    top = rar >= np.percentile(rar, 97)
    k = min(config.N_FEATURE_TYPES, max(2, int(top.sum() // 50)))
    km = MiniBatchKMeans(n_clusters=k, n_init=10, random_state=0, batch_size=4096).fit(Xs[top])
    lab_top = km.labels_
    examples = {}
    ti = np.where(top)[0]
    for c in range(k):
        members = ti[lab_top == c]
        members = members[np.argsort(-rar[members])][:24]
        examples[str(c)] = [(idx.loc[img[m], "path"], int(rc[m, 0]), int(rc[m, 1]), idx.loc[img[m], "material"]) for m in members]
        mat_mix = pd.Series(idx.loc[img[ti[lab_top == c]], "material"].values).value_counts(normalize=True).round(2)
        report.setdefault("feature_types", {})[str(c)] = {"n_patches": int((lab_top == c).sum()),
                                                          "materials": mat_mix.head(5).to_dict()}
    names_path = os.path.join(W, "cluster_names.json")
    names = json.load(open(names_path)) if os.path.exists(names_path) else {}
    models = dict(scaler=scaler, iso=iso, iso_norm=iso_norm, heads=heads, kmeans=km, examples=examples,
                  cluster_names=names, feature_names=core.feature_names(backend), n_feature_types=k,
                  backend=backend, pca=load_pca(backend) if backend != "classic" else None)
    joblib.dump(models, os.path.join(W, "models.joblib"))
    report["seconds"] = round(time.time() - t0, 1)
    json.dump(report, open(os.path.join(W, "report.json"), "w"), indent=1, default=str)
    log(f"training finished in {report['seconds']} s")
    return report


