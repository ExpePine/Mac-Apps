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
    "material_rules": [["finger testing", "Live"], ["favicol", "Material 3"],
                       ["glue", "Material 3"], ["gelatin", "Material 1"], ["silicon", "Material 2"],
                       ["latex", "Material 4"], ["clay", "Material 5"], ["wax", "Material 6"]],
    # Materials that are LIVE fingers (leave empty if none)
    "live_materials": [],
    # Materials still used for training but not shown anywhere in the app
    "hidden_materials": ["Material 5", "Material 6"],
    # Ignore everything at or below this row (640-px image) - removes the sensor's bottom bezel band. 0 = off.
    "mask_max_row": 485,
}
IMAGE_EXT = (".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff")
PATCHES_PER_IMAGE = 300
N_FEATURE_TYPES = 8
N_JOBS = 1 if FROZEN else 2


# earlier, longer material names -> current short names (used to update saved settings)
RENAMED = {"finger_testing_indoor": "Live", "finger_In": "Live",
           "gelatin": "Material 1", "gel": "Material 1",
           "silicone_rubber": "Material 2", "sil_R": "Material 2",
           "elmers_glue": "Material 3", "glue_E": "Material 3", "transparent_favicol": "Material 3", "fevi_T": "Material 3",
           "latex_paint": "Material 4", "latex_P": "Material 4",
           "clay": "Material 5", "wax": "Material 6"}


def display_name(m):
    """Neutral name shown in the app for any earlier material label."""
    return RENAMED.get(m, m)


def load():
    s = dict(DEFAULTS)
    try:
        with open(SETTINGS_PATH) as f:
            s.update(json.load(f))
    except Exception:
        pass
    s["material_rules"] = DEFAULTS["material_rules"]          # names always follow this version
    s["hidden_materials"] = DEFAULTS["hidden_materials"]
    s["live_materials"] = [RENAMED.get(m, m) for m in s.get("live_materials", [])]
    return s


def save(s):
    os.makedirs(HOME_DIR, exist_ok=True)
    with open(SETTINGS_PATH, "w") as f:
        json.dump(s, f, indent=1)
