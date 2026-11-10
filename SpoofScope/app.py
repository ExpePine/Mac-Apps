"""SpoofScope - Streamlit app.  Run:  streamlit run app.py"""
import os, json, glob
import numpy as np, pandas as pd, joblib, cv2
import streamlit as st
import config, core, pipeline

W = config.WORK_DIR
os.makedirs(W, exist_ok=True)
st.set_page_config(page_title="SpoofScope", layout="wide")
SETTINGS = config.load()


@st.cache_resource
def load_models():
    p = os.path.join(W, "models.joblib")
    if not os.path.exists(p):
        return None
    m = joblib.load(p)
    names_p = os.path.join(W, "cluster_names.json")
    if os.path.exists(names_p):
        m["cluster_names"] = json.load(open(names_p))
    return m


@st.cache_data
def load_index():
    p = os.path.join(W, "index.csv")
    return pd.read_csv(p, dtype={"ts": str}) if os.path.exists(p) else None


@st.cache_data
def load_long():
    p = os.path.join(W, "production_scores_long.csv")
    return pd.read_csv(p, dtype={"ts": str}) if os.path.exists(p) else None


def analyse(g, models, head, thr, img_thr, min_patches=1):
    feats, bmask = core.compute_features(g, models.get("backend", "classic"), models.get("pca"),
                                         models.get("mask_max_row", 0))
    sm = core.head_scores(models, feats, bmask, head)
    regions = core.find_regions(models, feats, bmask, sm, thr, min_patches)
    ev = core.evidence_search(sm, img_thr)
    return feats, bmask, sm, regions, ev


models = load_models()
idx = load_index()
_rp = os.path.join(W, "report.json")
REPORT = json.load(open(_rp)) if os.path.exists(_rp) else {}
READY = models is not None and idx is not None
st.title("SpoofScope: spoof-feature highlighter")

heads = ["rarity"] + (list(models["heads"].keys()) if READY else [])
HEAD_HELP = {"rarity": "How unusual each patch is compared with the reference patches (unsupervised).",
             "material": "How strongly each patch matches one material (confidence of the top material).",
             "live_vs_spoof": "Probability that a patch comes from a spoof rather than a live finger.",
             "hard_case": "How much a patch looks like patches from spoofs that FOOLED the production model."}
with st.sidebar:
    st.header("Settings")
    head = st.selectbox("Highlight head", heads, help="Each head is a small model on the same patch features.")
    st.caption(HEAD_HELP.get(head, ""))
    thr = st.slider("Patch flag threshold", 0.0, 1.0, 0.7, 0.01)
    img_thr = st.slider("Image score threshold (evidence search)", 0.0, 1.0, 0.5, 0.01)
    min_size = st.slider("Minimum region size (patches)", 1, 10, 2)
    alpha = st.slider("Heatmap opacity", 0.0, 1.0, 0.45, 0.05)
    st.divider()
    if st.button("Quit SpoofScope", help="Stops the app. Open it again from Applications."):
        st.write("SpoofScope stopped. You can close this tab.")
        os._exit(0)
    show_paths = st.checkbox("Show file paths / IDs", value=False,
                             help="Leave off for external audiences: hides operator names, MAC IDs and serials.")

tab_setup, tab_an, tab_de, tab_ft, tab_batch, tab_rep = st.tabs(
    ["Setup", "Analyse image", "Data engine", "Feature types", "Batch", "Model report"])

# ------------------------------------------------------------------ Setup
with tab_setup:
    st.subheader("1. Data folder")
    st.caption("The folder that contains one sub-folder per material. In Finder: select the folder, "
               "press Option+Command+C to copy its path, then paste it here.")
    root = st.text_input("Data folder path", SETTINGS.get("data_root", "")).strip().strip('"').strip("'")
    mats_known = sorted(idx["material"].unique()) if idx is not None else []
    live = st.multiselect("Materials that are LIVE fingers (leave empty if none)",
                          sorted(set(mats_known) | set(SETTINGS.get("live_materials", []))),
                          default=SETTINGS.get("live_materials", []))
    dino_ok = core.dino_available()
    opts = ["classic", "dino"] if dino_ok else ["classic"]
    backend = st.radio("Feature backend", opts, index=opts.index(SETTINGS.get("backend", "classic")) if SETTINGS.get("backend", "classic") in opts else 0,
                       format_func=lambda b: {"classic": "Classic (fast, ~0.5-1 s/image)",
                                              "dino": "DINOv2 + classic (foundation model, slower: run overnight)"}[b],
                       horizontal=True)
    if not dino_ok:
        st.caption("DINOv2 model not found in this build; only the classic backend is available.")
    max_row = st.number_input("Ignore rows from (bottom bezel cut-off, in 640-px image; 0 = off)", 0, 640,
                              int(SETTINGS.get("mask_max_row", 485)), step=5,
                              help="Everything at or below this row is excluded from the print mask. "
                                   "Changing it needs features extracted again (stored separately).")
    if st.checkbox("Preview the cut-off on a dataset image", value=False) and idx is not None and len(idx):
        _g = core.load_gray(idx["path"].iloc[0])
        _v = cv2.cvtColor((_g * 255).astype(np.uint8), cv2.COLOR_GRAY2RGB)
        _m = core.print_mask(_g, max_row)
        _v[_m] = (0.6 * _v[_m] + 0.4 * np.array([0, 160, 255])).astype(np.uint8)
        if max_row:
            _v[max(0, int(max_row) - 1):int(max_row) + 1, :] = (255, 0, 0)
        st.image(_v, caption="Blue = print mask used for features; red line = cut-off", width=360)
    if st.button("Save settings"):
        SETTINGS["backend"] = backend
        SETTINGS["mask_max_row"] = int(max_row)
        SETTINGS["data_root"], SETTINGS["live_materials"] = root, live
        config.save(SETTINGS)
        st.success("Saved.")

    st.subheader("2. Build")
    n_feat = len(glob.glob(os.path.join(pipeline.feat_dir(SETTINGS.get("backend", "classic"),
                                                          int(SETTINGS.get("mask_max_row", 0) or 0)), "*.npz")))
    st.write(f"Indexed images: **{0 if idx is None else len(idx)}**, with features: **{n_feat}**, "
             f"model trained: **{'yes (' + models.get('backend', 'classic') + ')' if models is not None else 'no'}**")
    st.caption("Your Mac is kept awake while SpoofScope runs, so overnight runs are not interrupted by sleep "
               "(keep it plugged in; closing the lid of a laptop without an external display still sleeps it).")
    quick = st.checkbox("Quick test (first ~200 images only)", value=False)
    c1, c2, c3, c4 = st.columns(4)
    do_idx, do_ext, do_tr, do_all = c1.button("Index data"), c2.button("Extract features"), c3.button("Train"), c4.button("Run all 3")
    logbox = st.empty()
    lines = []

    def log(msg):
        lines.append(str(msg))
        logbox.code("\n".join(lines[-30:]))

    try:
        if do_idx or do_all:
            SETTINGS["data_root"], SETTINGS["live_materials"], SETTINGS["backend"] = root, live, backend
            SETTINGS["mask_max_row"] = int(max_row)
            config.save(SETTINGS)
            pipeline.build_index(root, SETTINGS, log)
        if do_ext or do_tr:
            SETTINGS["backend"] = backend; SETTINGS["mask_max_row"] = int(max_row); config.save(SETTINGS)
        if do_ext or do_all:
            bar = st.progress(0.0, text="Extracting features")
            pipeline.extract(limit=200 if quick else 0,
                             progress=lambda d, t: bar.progress(d / max(t, 1), text=f"Extracting features {d}/{t}"), log=log)
        if do_tr or do_all:
            with st.spinner("Training..."):
                pipeline.train(log)
        if do_idx or do_ext or do_tr or do_all:
            st.cache_resource.clear(); st.cache_data.clear()
            st.success("Done. Reload the page (Command+R) to use the new results in the other tabs.")
    except Exception as e:
        st.error(f"{type(e).__name__}: {e}")

if not READY:
    for t in (tab_an, tab_de, tab_ft, tab_batch, tab_rep):
        with t:
            st.info("Set up and train first (Setup tab).")

# ------------------------------------------------------------------ Analyse
with tab_an:
    if READY:
        c0, c1 = st.columns([1, 2])
        with c0:
            src = st.radio("Image source", ["Upload", "From dataset"], horizontal=True)
            g, meta = None, {}
            if src == "Upload":
                up = st.file_uploader("Fingerprint image", type=["jpg", "jpeg", "png", "bmp", "tif", "tiff"])
                if up is not None:
                    arr = cv2.imdecode(np.frombuffer(up.read(), np.uint8), cv2.IMREAD_GRAYSCALE)
                    if arr is not None:
                        g = cv2.resize(arr, (core.SIZE, core.SIZE), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
            else:
                mat = st.selectbox("Material", sorted(idx["material"].unique()))
                sub = idx[idx["material"] == mat].reset_index(drop=True)
                only_hard = st.checkbox("Only images that fooled >= 1 production version",
                                        value=False, disabled="n_fooled" not in sub)
                if only_hard and "n_fooled" in sub:
                    sub = sub[sub["n_fooled"].fillna(0) > 0].reset_index(drop=True)
                if len(sub):
                    i = st.number_input(f"Image # (0-{len(sub) - 1})", 0, len(sub) - 1, 0)
                    meta = sub.iloc[int(i)].to_dict()
                    g = core.load_gray(meta["path"])
                else:
                    st.info("No images match.")
        if g is not None:
            feats, bmask, sm, regions, ev = analyse(g, models, head, thr, img_thr, min_size)
            with c1:
                st.image(core.overlay(g, sm, regions, alpha), caption=f"{head} heatmap; boxes = flagged regions")
            with c0:
                st.metric("Image score (top-10% patches)", f"{core.image_score(sm):.2f}")
                st.metric("Flagged regions", len(regions))
                st.metric("Evidence patches to flip verdict", "all" if ev is None else len(ev),
                          help="Greedy search: strongest patches removed one at a time until the image score "
                               "falls below the image threshold. Fewer = the verdict rests on a few spots.")
                if regions:
                    counts = pd.Series([r["type"] for r in regions]).value_counts().rename_axis("feature type").reset_index(name="count")
                    st.dataframe(counts, hide_index=True)
                if meta:
                    info = {k: meta.get(k) for k in ["material", "tags", "quality", "prod_p_spoof", "n_fooled", "n_versions"] if k in meta}
                    if show_paths:
                        info.update({k: meta.get(k) for k in ["path", "mac", "ts"]})
                    st.json(info)
            with st.expander("Evidence search replay (move by move)"):
                s = sm.copy()
                rows = []
                for step, (r, c, v) in enumerate((ev or [])[:40]):
                    s[r, c] = np.nan
                    rows.append({"move": step + 1, "patch (row,col)": f"({r},{c})", "patch score": round(v, 3),
                                 "image score after": round(core.image_score(s), 3)})
                st.dataframe(pd.DataFrame(rows), hide_index=True)

# ------------------------------------------------------------------ Data engine
with tab_de:
    if READY:
        long = load_long()
        if long is None:
            st.info("No Model_*.csv production-score files were found when indexing.")
        else:
            st.subheader("Production model: spoofs accepted as live, by version and material")
            lk = long.merge(idx[["mac", "ts", "material"]].drop_duplicates(), left_on=["MAC", "ts"], right_on=["mac", "ts"], how="left")
            lk["material"] = lk["material"].fillna("(no image file)")
            tab = (lk.groupby(["material", "Version"])["fooled"].mean() * 100).round(1).unstack()
            st.dataframe(tab)
            st.caption("Percent of captures where F_Live > F_Spoof. Lower is better.")
            st.subheader("Hard cases (data-engine triggers)")
            hc = idx[idx["n_fooled"].fillna(0) > 0].copy() if "n_fooled" in idx else pd.DataFrame()
            if len(hc):
                hc["version_disagreement"] = hc["prod_p_spoof_std"].round(3)
                cols = ["material", "n_fooled", "n_versions", "prod_p_spoof", "version_disagreement", "quality"]
                if show_paths:
                    cols += ["mac", "ts", "path"]
                st.dataframe(hc.sort_values("n_fooled", ascending=False)[cols], hide_index=True)
                st.caption("Images that fooled at least one version, ranked by how many versions they fooled.")
            if "ts" in idx and "n_fooled" in idx:
                st.subheader("Control chart: fooled versions over capture time")
                m = st.selectbox("Material ", sorted(idx["material"].unique()), key="cc")
                d = idx[(idx["material"] == m) & idx["n_fooled"].notna()].copy()
                if len(d):
                    d["time"] = pd.to_datetime(d["ts"], format="%d%m%Y%H%M%S", errors="coerce")
                    d = d.dropna(subset=["time"]).sort_values("time").set_index("time")
                    st.line_chart(d["n_fooled"])

# ------------------------------------------------------------------ Feature types
with tab_ft:
    if READY:
        st.write("Most unusual patches, grouped automatically. Name each group once; names are saved and used in the counts.")
        names = dict(models.get("cluster_names", {}))
        ex = models["examples"]
        for c in sorted(ex, key=int):
            mix = REPORT.get("feature_types", {}).get(c, {})
            st.markdown(f"**Group {c}** - {mix.get('n_patches', '?')} patches; materials: {mix.get('materials', {})}")
            crops = []
            for path, r, cc, mat in ex[c][:12]:
                try:
                    g2 = core.load_gray(path)
                except Exception:
                    continue
                y0, x0 = max(0, r * core.GRID - 16), max(0, cc * core.GRID - 16)
                crop = g2[y0:y0 + 48, x0:x0 + 48]
                crop = cv2.resize((crop * 255).astype(np.uint8), (96, 96), interpolation=cv2.INTER_NEAREST)
                crops.append(crop)
            if crops:
                st.image(crops, width=96)
            names[c] = st.text_input(f"Name for group {c}", names.get(c, f"type_{c}"), key=f"name_{c}")
        if st.button("Save names"):
            json.dump(names, open(os.path.join(W, "cluster_names.json"), "w"), indent=1)
            st.cache_resource.clear()
            st.success("Saved. Counts now use these names.")

# ------------------------------------------------------------------ Batch
with tab_batch:
    if READY:
        folder = st.text_input("Folder of images to analyse")
        if st.button("Run batch") and folder:
            files = [p for p in glob.glob(os.path.join(folder, "**", "*"), recursive=True) if p.lower().endswith(config.IMAGE_EXT)]
            prog, rows = st.progress(0.0), []
            for i, p in enumerate(files):
                try:
                    g = core.load_gray(p)
                    feats, bmask, sm, regions, ev = analyse(g, models, head, thr, img_thr, min_size)
                    row = {"file": os.path.basename(p), "image_score": round(core.image_score(sm), 3),
                           "regions": len(regions), "evidence_patches": -1 if ev is None else len(ev)}
                    for r in regions:
                        row[r["type"]] = row.get(r["type"], 0) + 1
                    rows.append(row)
                except Exception as e:
                    rows.append({"file": os.path.basename(p), "error": str(e)})
                prog.progress((i + 1) / max(1, len(files)))
            df = pd.DataFrame(rows).fillna(0)
            st.dataframe(df)
            st.download_button("Download CSV", df.to_csv(index=False), "spoofscope_batch.csv", "text/csv")

# ------------------------------------------------------------------ Report
with tab_rep:
    if READY:
        p = os.path.join(W, "report.json")
        if os.path.exists(p):
            rep = json.load(open(p))
            for w in rep.get("warnings", []):
                st.warning(w)
            st.json(rep)
