"""Entry point for the SpoofScope Mac app (PyInstaller).  Also:  python launcher.py --selftest"""
import os, sys, multiprocessing


def _base():
    return getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))


def _app_path():
    p = os.path.join(_base(), "appsrc", "app.py")
    return p if os.path.exists(p) else os.path.join(_base(), "app.py")


URL = "http://localhost:8501"


def _healthy():
    import urllib.request
    try:
        with urllib.request.urlopen(URL + "/_stcore/health", timeout=1) as r:
            return r.status == 200
    except Exception:
        return False


def _notify(msg):
    if sys.platform == "darwin":
        import subprocess
        try:
            subprocess.Popen(["osascript", "-e", f'display notification "{msg}" with title "SpoofScope"'])
        except Exception:
            pass


def _open_when_ready():
    import time, subprocess, webbrowser
    for _ in range(240):
        if _healthy():
            try:
                subprocess.Popen(["open", URL]) if sys.platform == "darwin" else webbrowser.open(URL)
            except Exception:
                pass
            return
        time.sleep(0.5)


class _Tee:
    def __init__(self, *s): self.s = s
    def write(self, x):
        for f in self.s:
            try: f.write(x); f.flush()
            except Exception: pass
    def flush(self): pass
    def isatty(self): return False


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
    at = AppTest.from_file(_app_path(), default_timeout=180).run()
    if at.exception:
        raise RuntimeError(f"app raised: {[e.value for e in at.exception]}")
    print(f"SELFTEST app OK ({len(at.tabs)} tabs)")
    print("SELFTEST PASSED")


def apptest_fresh():
    """Run app.py exactly as the server would, in a process where nothing is pre-imported."""
    import tempfile
    os.environ["HOME"] = tempfile.mkdtemp(prefix="spoofscope_apptest_")
    from streamlit.testing.v1 import AppTest
    at = AppTest.from_file(_app_path(), default_timeout=180).run()
    if at.exception:
        raise RuntimeError(f"app raised: {[e.value for e in at.exception]}")
    print(f"APPTEST fresh OK ({len(at.tabs)} tabs)")


def main():
    multiprocessing.freeze_support()
    if "--selftest" in sys.argv:
        selftest(); return
    if "--apptest" in sys.argv:
        apptest_fresh(); return
    if _healthy():                      # already running: just bring up the page
        _notify("SpoofScope is already running - opening it in your browser.")
        import subprocess; subprocess.Popen(["open", URL]); return
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
        tee = _Tee(log, sys.__stdout__) if sys.__stdout__ and sys.__stdout__.isatty() else log
        sys.stdout = sys.stderr = tee
    print("SpoofScope starting ...")
    _notify("Starting... your browser will open in a few seconds.")
    import cv2, core, pipeline          # load the heavy libraries once, from the bundle  # noqa
    if not os.environ.get("SPOOFSCOPE_HEADLESS"):
        import threading
        threading.Thread(target=_open_when_ready, daemon=True).start()
    from streamlit.web import cli as stcli
    sys.argv = ["streamlit", "run", _app_path(),
                "--global.developmentMode=false", "--browser.gatherUsageStats=false",
                "--server.port=8501", "--server.headless=true"]
    sys.exit(stcli.main())


if __name__ == "__main__":
    main()
