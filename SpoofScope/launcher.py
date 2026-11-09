"""Entry point for the SpoofScope Mac app (PyInstaller).  Also:  python launcher.py --selftest"""
import os, sys, multiprocessing


def _base():
    return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))


def _pyinstaller_hints():   # never called; makes PyInstaller bundle everything app.py needs
    import config, core, pipeline                                     # noqa
    import numpy, scipy.ndimage, pandas, joblib, cv2                  # noqa
    import sklearn.ensemble, sklearn.cluster, sklearn.preprocessing   # noqa
    import sklearn.model_selection, sklearn.metrics                   # noqa
    import skimage.feature                                            # noqa
    import streamlit, streamlit.web.cli, streamlit.testing.v1         # noqa
    import onnxruntime, sklearn.decomposition                         # noqa


def _synthetic_dataset(root, n_per=12):
    """Small fake dataset (striped 'ridges' + blobs) for the self-test."""
    import numpy as np, cv2, pandas as pd
    rng = np.random.default_rng(0)
    yy, xx = np.mgrid[0:640, 0:640]
    rows = []
    for m_i, (mat, mac) in enumerate([("Wax_Test_Sr_1", "AAAAAAAAAAAA"), ("Clay_Test_Sr_2", "BBBBBBBBBBBB")]):
        d = os.path.join(root, mat, "RawData"); os.makedirs(d, exist_ok=True)
        for k in range(n_per):
            ang = rng.uniform(0, np.pi)
            img = 0.5 + 0.4 * np.sin(2 * np.pi * (xx * np.cos(ang) + yy * np.sin(ang)) / 9.0)
            mask = ((xx - 320) / 190.0) ** 2 + ((yy - 300) / 230.0) ** 2 < 1
            img = np.where(mask, img, 0.95) + rng.normal(0, 0.03, img.shape)
            for _ in range(rng.integers(2, 10)):
                cx, cy = rng.integers(200, 440, 2)
                img[(xx - cx) ** 2 + (yy - cy) ** 2 < rng.uniform(9, 40)] = 0.95 if m_i else 0.05
            ts = f"1102202512{k:02d}{m_i:02d}"
            ext = ".bmp" if m_i else ".jpg"     # cover both BMP and JPG inputs
            cv2.imwrite(os.path.join(d, f"Imag_640x640_50_{mac}_{ts}{ext}"), (np.clip(img, 0, 1) * 255).astype("uint8"))
            for v in ("V1", "V2"):
                fl = int(rng.random() < 0.4)
                rows.append({"Version": v, "MAC ID": mac, " ImageName": int(ts), " Quality": 50,
                             " F_Live": 200 * fl + 10, " F_Spoof": 245 - 200 * fl})
        os.makedirs(os.path.join(root, mat, "output"), exist_ok=True)
    df = pd.DataFrame(rows)
    for mat, mac in [("Wax_Test_Sr_1", "AAAAAAAAAAAA"), ("Clay_Test_Sr_2", "BBBBBBBBBBBB")]:
        df[df["MAC ID"] == mac].to_csv(os.path.join(root, mat, "output", "Model_test.csv"), index=False)


def selftest():
    import tempfile, time
    tmp = tempfile.mkdtemp(prefix="spoofscope_selftest_")
    os.environ["HOME"] = tmp            # keep the test away from real settings/work folders
    t = time.time()
    import config, core, pipeline
    data = os.path.join(tmp, "data")
    _synthetic_dataset(data)
    s = config.load(); s["data_root"] = data; config.save(s)
    idx = pipeline.build_index(data, s)
    assert len(idx) == 24 and idx["n_versions"].notna().all(), "index/CSV join failed"
    n, errs = pipeline.extract(progress=lambda d, t_: None)
    assert n == 24 and not errs, errs
    rep = pipeline.train()
    assert "material" in rep["heads"] and "hard_case" in rep["heads"], rep["heads"].keys()
    import joblib
    models = joblib.load(os.path.join(config.WORK_DIR, "models.joblib"))
    g = core.load_gray(idx["path"][0])
    f, b = core.patch_features(g)
    for h in ["rarity"] + list(models["heads"]):
        sm = core.head_scores(models, f, b, h)
        regs = core.find_regions(models, f, b, sm, 0.7)
        core.overlay(g, sm, regs); core.evidence_search(sm, 0.5)
    print(f"SELFTEST pipeline OK in {time.time() - t:.0f}s")
    if core.dino_available():
        t = time.time()
        tok = core.dino_tokens(g)
        assert tok.shape == (core.N, core.N, core.DINO_DIM), tok.shape
        s["backend"] = "dino"; config.save(s)
        n, errs = pipeline.extract(progress=lambda d, t_: None)
        assert n == 24 and not errs, errs
        rep = pipeline.train()
        m2 = joblib.load(os.path.join(config.WORK_DIR, "models.joblib"))
        f2, b2 = core.compute_features(g, "dino", m2["pca"])
        assert f2.shape[-1] == len(core.feature_names("dino")), f2.shape
        core.head_scores(m2, f2, b2, "hard_case")
        print(f"SELFTEST dino OK in {time.time() - t:.0f}s ({(time.time() - t) / 24:.1f}s/image incl. PCA+train)")
    elif os.environ.get("SPOOFSCOPE_REQUIRE_DINO"):
        raise RuntimeError("DINOv2 model or onnxruntime missing")
    from streamlit.testing.v1 import AppTest
    at = AppTest.from_file(os.path.join(_base(), "app.py"), default_timeout=180).run()
    if at.exception:
        raise RuntimeError(f"app raised: {[e.value for e in at.exception]}")
    print(f"SELFTEST app OK ({len(at.tabs)} tabs)")
    print("SELFTEST PASSED")


def main():
    multiprocessing.freeze_support()
    if "--selftest" in sys.argv:
        selftest(); return
    home = os.path.join(os.path.expanduser("~"), "SpoofScope")
    os.makedirs(home, exist_ok=True)
    os.chdir(home)
    if sys.platform == "darwin":      # keep the Mac awake while the app runs (overnight extraction)
        import subprocess
        try:
            subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])
        except Exception:
            pass
    if getattr(sys, "frozen", False):
        log = open(os.path.join(home, "launcher.log"), "a", buffering=1)
        sys.stdout = sys.stderr = log
    from streamlit.web import cli as stcli
    sys.argv = ["streamlit", "run", os.path.join(_base(), "app.py"),
                "--global.developmentMode=false", "--browser.gatherUsageStats=false",
                "--server.headless=" + ("true" if os.environ.get("SPOOFSCOPE_HEADLESS") else "false")]
    sys.exit(stcli.main())


if __name__ == "__main__":
    main()
