"""Settings. Defaults below; the app saves your choices to ~/SpoofScope/settings.json."""
import os, sys, json

HOME_DIR = os.path.join(os.path.expanduser("~"), "SpoofScope")
WORK_DIR = os.path.join(HOME_DIR, "work")
SETTINGS_PATH = os.path.join(HOME_DIR, "settings.json")
FROZEN = getattr(sys, "frozen", False)

DEFAULTS = {
    # Folder that contains one sub-folder per material
    "data_root": "",
    # Rules that turn a top-level folder name into a material label (first match wins, case-insensitive)
    "material_rules": [["finger testing", "finger_testing_indoor"], ["favicol", "transparent_favicol"],
                       ["glue", "elmers_glue"], ["gelatin", "gelatin"], ["silicon", "silicone_rubber"],
                       ["latex", "latex_paint"], ["clay", "clay"], ["wax", "wax"]],
    # Materials that are LIVE fingers (leave empty if none)
    "live_materials": [],
    # Ignore everything at or below this row (640-px image) - removes the sensor's bottom bezel band. 0 = off.
    "mask_max_row": 485,
}
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff")
PATCHES_PER_IMAGE = 300
N_FEATURE_TYPES = 8
N_JOBS = 1 if FROZEN else 2


def load():
    s = dict(DEFAULTS)
    try:
        with open(SETTINGS_PATH) as f:
            s.update(json.load(f))
    except Exception:
        pass
    return s


def save(s):
    os.makedirs(HOME_DIR, exist_ok=True)
    with open(SETTINGS_PATH, "w") as f:
        json.dump(s, f, indent=1)
