# SpoofScope

Highlights and counts suspected spoof features in fingerprint images, trained on your own data.
Runs entirely on your Mac (no internet, no GPU). Opens in your web browser.

## Install
1. Download `SpoofScope.dmg` from the **spoofscope-latest** release (or the latest "SpoofScope DMG" Actions run).
2. Open it and drag **SpoofScope** to **Applications**.
3. First launch: right-click SpoofScope > **Open** (or System Settings > Privacy & Security > **Open Anyway**).
   The app is not signed with an Apple developer certificate, so macOS asks once.
   If macOS says the app is "damaged", run in Terminal: `xattr -cr /Applications/SpoofScope.app`
4. A browser tab opens at http://localhost:8501. It can take 10-30 s the first time.

## Use
1. **Setup** tab: paste the path of the folder that holds one sub-folder per material
   (in Finder select it and press Option+Command+C to copy the path). Mark live-finger folders if you have any.
2. Press **Run all 3** (index, extract features, train). Tick *Quick test* first to try ~200 images.
3. Reload the page (Command+R). Use **Analyse image** (upload an image), **Data engine**, **Feature types**, **Batch**, **Model report**.
4. To stop the app use **Quit SpoofScope** in the sidebar.

Everything SpoofScope creates lives in `~/SpoofScope` (settings, features, trained models, `launcher.log`).
Your images are only read, never changed or copied.

## Feature backends (Setup tab)
- **Classic**: 31 hand-designed measurements per 16x16 patch. About 0.5-1 s per image.
- **DINOv2 + classic**: adds DINOv2-small (Meta's self-supervised vision foundation model, Apache-2.0),
  run locally with ONNX Runtime. Each patch gets 96 extra learned numbers (PCA of the 384-number token).
  Slower (expect a few seconds per image on a 2019 Intel MacBook); run it overnight.
  SpoofScope keeps the Mac awake while it runs; keep it plugged in and the lid open.
Images can be BMP, JPG, PNG or TIFF.

## Heads
- `rarity`: how unusual a patch is (unsupervised)
- `hard_case`: patches like those in spoofs that fooled the production model (needs `Model_*.csv` files in the data folder)
- `material`: patches that strongly match one material
- `live_vs_spoof`: only when live folders are marked

## Caveats before quoting numbers
- With no live data, `rarity` means "unusual among your captures", not "spoof vs live".
- If each device (MAC) captured one material, the `material` head may learn the device. The report warns about this.
- `hard_case` usually has few positive images; its AUC is noisy.

## Developers
`pip install -r requirements.txt` then `streamlit run app.py`, or `python run_pipeline.py --root "<folder>"`.
`python launcher.py --selftest` runs an end-to-end test on generated images.
The DMG is built by `.github/workflows/spoofscope-dmg.yml` on an Intel macOS runner.
