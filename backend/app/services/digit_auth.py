import json
import math
import os
from pathlib import Path
from typing import Dict, List, Optional

_DATA_DIR = Path(__file__).parent.parent / "data"
_DATA_FILE = _DATA_DIR / "digit_references.json"
_TOLERANCE = 1.2

# Amorces génériques. ⚠️ À REMPLACER par les signatures Hu EXACTES des moules
# officiels (séries 2 et 5), capturées sur un objet AUTHENTIQUE de référence.
# Priorité de chargement : variable d'env ARTGENS_DIGIT_REFS (JSON
# {"2":[...],"5":[...]}) > fichier data/digit_references.json > ces amorces.
_SEED: Dict[str, List[float]] = {
    "2": [-0.91, -0.42, -1.62, -0.47],
    "5": [0.57, 1.99, 4.78, 5.38],
}

_REFERENCES: Dict[str, List[float]] = dict(_SEED)


def _load() -> None:
    global _REFERENCES
    env = os.environ.get("ARTGENS_DIGIT_REFS")
    if env:
        try:
            data = json.loads(env)
            _REFERENCES = {str(k): [float(x) for x in v] for k, v in data.items()}
            return
        except Exception:
            pass
    try:
        if _DATA_FILE.exists():
            with open(_DATA_FILE) as f:
                data = json.load(f)
            _REFERENCES = {
                str(k): [float(x) for x in v]
                for k, v in data.get("references", {}).items()
            }
    except Exception:
        pass


def _save() -> None:
    try:
        _DATA_DIR.mkdir(parents=True, exist_ok=True)
        with open(_DATA_FILE, "w") as f:
            json.dump({"references": _REFERENCES}, f)
    except Exception:
        pass


_load()


def hu_distance(a: List[float], b: List[float]) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def get_reference(value) -> Optional[List[float]]:
    return _REFERENCES.get(str(value))


def set_reference(value, hu: List[float]) -> None:
    _REFERENCES[str(value)] = [float(x) for x in hu]
    _save()


def verify(value, hu: List[float], tol: float = _TOLERANCE) -> dict:
    ref = get_reference(value)
    if ref is None:
        return {
            "authentic": False,
            "distance": None,
            "tolerance": tol,
            "value": str(value),
            "reason": "reference_non_definie",
        }
    d = hu_distance(hu, ref)
    return {
        "authentic": bool(d <= tol),
        "distance": d,
        "tolerance": tol,
        "value": str(value),
    }
