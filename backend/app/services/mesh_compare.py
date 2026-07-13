"""Comparaison de deux nuages de points / meshes 3D pour l'authentification.

IMPORTANT : 100 % numpy, SANS Open3D. Open3D exige libgomp/OpenMP absent du
plan gratuit Render (et gourmand en RAM). On parse directement les sommets des
fichiers OBJ/PLY, on normalise (centre + diag bbox = 1), on recale (recherche
grossière en rotation autour de l'axe vertical + ICP point-à-point), puis on
mesure la distance de Chamfer + le rappel (fraction de points proches).

Le candidat envoyé par le téléphone est un nuage de points (PLY) issu du SfM
opencv_dart ; la référence stockée sur le backend est un OBJ ou PLY.
"""
import sys
import json
import numpy as np


# ---------------------------------------------------------------------------
# Chargement des points (OBJ .obj ou PLY ascii/binaire little-endian)
# ---------------------------------------------------------------------------
def _read_obj_vertices(path: str) -> np.ndarray:
    pts = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                try:
                    pts.append([float(p[1]), float(p[2]), float(p[3])])
                except (IndexError, ValueError):
                    continue
    return np.asarray(pts, dtype=np.float64)


def _read_ply_vertices(path: str) -> np.ndarray:
    with open(path, "rb") as f:
        header = f.read(2048)
    head = header.split(b"\n")
    is_ascii = b"ascii" in header[:512]
    n_vert = 0
    fmt = "ascii"
    for ln in head:
        s = ln.decode("ascii", "ignore").strip()
        if s.startswith("format"):
            fmt = s  # ex: format ascii 1.0  /  format binary_little_endian 1.0
        if s.startswith("element vertex"):
            try:
                n_vert = int(s.split()[-1])
            except ValueError:
                n_vert = 0
        if s == "end_header":
            break
    if n_vert <= 0:
        raise ValueError(f"PLY illisible (pas de 'element vertex'): {path}")

    if "ascii" in fmt:
        pts = np.empty((n_vert, 3), dtype=np.float64)
        idx = 0
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            # avancer jusqu'à end_header
            for line in f:
                if line.strip() == "end_header":
                    break
            for line in f:
                if idx >= n_vert:
                    break
                p = line.split()
                if len(p) < 3:
                    continue
                try:
                    pts[idx] = [float(p[0]), float(p[1]), float(p[2])]
                    idx += 1
                except ValueError:
                    continue
        return pts[:idx]
    else:
        # binaire little-endian : on suppose propriétés float32 x y z (éventuellement
        # suivies de couleurs uchar). On lit à partir de la fin du header.
        with open(path, "rb") as f:
            raw = f.read()
        off = raw.find(b"end_header") + len(b"end_header") + 1
        # déterminier le stride : compter 'property' lines until prochain 'element'
        props = 0
        end = raw[:off].rfind(b"end_header")
        for ln in raw[:end].split(b"\n"):
            s = ln.decode("ascii", "ignore").strip()
            if s.startswith("property") and "vertex" not in s:
                if "float" in s or "double" in s:
                    props += 1
                elif "uchar" in s or "char" in s or "int" in s or "short" in s:
                    props += 1
        if props == 0:
            props = 3
        # on suppose 3 floats (12 octets) (+props complémentaires ignorées)
        stride = props * 4
        arr = np.frombuffer(raw, dtype=np.float32, count=n_vert * 3, offset=off)
        pts = arr.reshape(-1, 3).astype(np.float64)
        return pts


def _load_points(path: str, max_pts: int = 30000) -> np.ndarray:
    pl = path.lower()
    if pl.endswith(".ply"):
        pts = _read_ply_vertices(path)
    elif pl.endswith(".obj"):
        pts = _read_obj_vertices(path)
    else:
        # tenta obj
        try:
            pts = _read_obj_vertices(path)
            if len(pts) == 0:
                pts = _read_ply_vertices(path)
        except Exception:
            pts = _read_ply_vertices(path)
    pts = np.asarray(pts, dtype=np.float64)
    if pts.size == 0:
        raise ValueError(f"Aucun sommet trouvé dans: {path}")
    if len(pts) > max_pts:
        rng = np.random.default_rng(0)
        sel = rng.choice(len(pts), size=max_pts, replace=False)
        pts = pts[sel]
    return pts


def _normalize(pts: np.ndarray) -> np.ndarray:
    pts = pts - pts.mean(axis=0)
    diag = float(np.linalg.norm(pts.max(axis=0) - pts.min(axis=0)))
    if diag <= 1e-12:
        raise ValueError("Objet dégénéré (diagonale nulle).")
    return pts / diag


# ---------------------------------------------------------------------------
# Plus proches voisins chunkés (sans scipy)
# ---------------------------------------------------------------------------
def _nn_dist(A: np.ndarray, B: np.ndarray) -> np.ndarray:
    """Pour chaque ligne de A, distance au plus proche dans B."""
    na = A.shape[0]
    chunk = 512
    out = np.empty(na, dtype=np.float64)
    B2 = np.sum(B * B, axis=1)
    for i in range(0, na, chunk):
        sub = A[i:i + chunk]
        # dist² = |a|² + |b|² - 2 a.b
        d2 = (np.sum(sub * sub, axis=1)[:, None]
              + B2[None, :]
              - 2.0 * sub @ B.T)
        np.maximum(d2, 0, out=d2)
        out[i:i + chunk] = np.sqrt(d2.min(axis=1))
    return out


def _chamfer(A: np.ndarray, B: np.ndarray) -> tuple:
    d_ab = _nn_dist(A, B)
    d_ba = _nn_dist(B, A)
    return d_ab, d_ba


def _rot_z(theta: float) -> np.ndarray:
    c, s = np.cos(theta), np.sin(theta)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], dtype=np.float64)


def _icp(src: np.ndarray, dst: np.ndarray, max_iter: int = 50, tol: float = 1e-4):
    """ICP point-à-point simple. Renvoie la transformation 4x4 et le nuage
    transformé."""
    T = np.eye(4, dtype=np.float64)
    X = src.copy()
    prev = np.inf
    for _ in range(max_iter):
        d = _nn_dist(X, dst)
        # on garde les correspondances proches (robuste aux outliers)
        thr = np.percentile(d, 90)
        mask = d < thr
        if mask.sum() < 10:
            break
        A = X[mask]
        Bp = np.empty_like(A)
        # pour chaque point retenu, trouver le plus proche (deja dans d) -> argmin
        # recalcul via chunk pour argmin
        chunk = 512
        idxs = np.empty(len(A), dtype=np.int64)
        for i in range(0, len(A), chunk):
            sub = A[i:i + chunk]
            d2 = (np.sum(sub * sub, axis=1)[:, None]
                  + np.sum(dst * dst, axis=1)[None, :]
                  - 2.0 * sub @ dst.T)
            idxs[i:i + chunk] = np.argmin(d2, axis=1)
        Bp = dst[idxs]
        # recalage rigide (Kabsch / SVD)
        ca = A.mean(axis=0)
        cb = Bp.mean(axis=0)
        H = (A - ca).T @ (Bp - cb)
        U, _, Vt = np.linalg.svd(H)
        D = np.eye(3)
        D[2, 2] = np.sign(np.linalg.det(Vt.T @ U.T))
        R = Vt.T @ D @ U.T
        t = cb - R @ ca
        X = (R @ X.T).T + t
        T_step = np.eye(4)
        T_step[:3, :3] = R
        T_step[:3, 3] = t
        T = T_step @ T
        cur = float(d.mean())
        if prev - cur < tol:
            break
        prev = cur
    return T, X


def compare_meshes(ref_path: str, curr_path: str, threshold: float = 0.05) -> dict:
    """Compare le nuage candidat au nuage de référence et renvoie un score
    d'authenticité dans [0,1] (fraction de points dans le seuil)."""
    ref = _normalize(_load_points(ref_path))
    cur = _normalize(_load_points(curr_path))

    # Recherche grossière en rotation autour de l'axe vertical (l'œuf tourné
    # à la main -> orientation azimuthale arbitraire). On choisit la rotation
    # qui minimise la distance de Chamfer avant ICP fin.
    best_T = None
    best_cur = None
    best_mean = np.inf
    n_steps = 24
    for k in range(n_steps):
        theta = 2.0 * np.pi * k / n_steps
        Rc = _rot_z(theta)
        moved = (Rc @ cur.T).T
        d_ab, d_ba = _chamfer(moved, ref)
        mean = 0.5 * (d_ab.mean() + d_ba.mean())
        if mean < best_mean:
            best_mean = mean
            best_T = np.eye(4)
            best_T[:3, :3] = Rc
            best_cur = moved

    # ICP de raffinement (sur le meilleur point de départ)
    Ticp, aligned = _icp(best_cur, ref, max_iter=40)

    d_ab, d_ba = _chamfer(aligned, ref)
    mean = float(0.5 * (d_ab.mean() + d_ba.mean()))
    maxd = float(d_ab.max())
    rmse = float(np.sqrt(0.5 * (np.mean(d_ab ** 2) + np.mean(d_ba ** 2))))
    within = float((d_ab < threshold).mean())

    # score global : moyenne géométrique du rappel dans les deux sens
    recall_ab = float((d_ab < threshold).mean())
    recall_ba = float((d_ba < threshold).mean())
    score = 0.0
    if recall_ab > 0 and recall_ba > 0:
        score = float(np.sqrt(recall_ab * recall_ba))

    return {
        "score": score,
        "recall_candidate": recall_ab,
        "recall_reference": recall_ba,
        "mean_distance_norm": mean,
        "max_distance_norm": maxd,
        "rmse_norm": rmse,
        "fraction_within_threshold": within,
        "threshold": threshold,
        "n_ref": int(len(ref)),
        "n_candidate": int(len(cur)),
    }


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python mesh_compare.py <ref.obj|ply> <candidat.obj|ply> [seuil]")
        sys.exit(1)
    thr = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
    res = compare_meshes(sys.argv[1], sys.argv[2], thr)
    print(json.dumps(res, indent=2))
