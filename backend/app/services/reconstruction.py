"""Reconstruction 3D photogrammétrique à partir d'un dossier de photos.

Deux moteurs (le 1er disponible est utilisé) :
  A. pycolmap (pip, tourne en CPU, SANS GPU ni binaire COLMAP séparé)
     -> SfM sparse -> nuage de points -> mesh Poisson (Open3D).
  B. COLMAP CLI (binaire `colmap` dans le PATH) -> pipeline complet
     feature -> matching -> mapper -> dense MVS (GPU) -> fusion -> Poisson.

pycolmap et open3d sont dans requirements.txt (installés sur le backend
Render). Ils sont importés paresseusement (uniquement lors d'une requête
/scan3d/reconstruct) pour ne pas alourdir le démarrage.
"""
import os
import sys
import json
import shutil
import logging
import subprocess
import tempfile

logger = logging.getLogger(__name__)

COLMAP_BIN = os.environ.get("COLMAP_BIN", "colmap")


class ReconstructionUnavailable(Exception):
    """Aucun moteur de reconstruction n'est utilisables (pycolmap en échec
    et/ou binaire colmap absent). Renvoie une 501 claire, pas une 500 opaque."""


def colmap_available() -> bool:
    # 1) binaire COLMAP CLI (qualité supérieure, dense si GPU)
    try:
        subprocess.run([COLMAP_BIN, "--help"], capture_output=True, timeout=20)
        return True
    except Exception:
        pass
    # 2) moteur pycolmap (CPU, pip) — c'est celui utilisé sur le backend Render
    try:
        import pycolmap  # noqa: F401

        return True
    except Exception:
        return False


def _colmap_cli_available() -> bool:
    try:
        subprocess.run([COLMAP_BIN, "--help"], capture_output=True, timeout=20)
        return True
    except Exception:
        return False


def reconstruct_folder(images_dir: str, output_dir: str = None, dense: bool = True) -> dict:
    images_dir = os.path.abspath(images_dir)
    if not os.path.isdir(images_dir):
        raise FileNotFoundError(f"Dossier introuvable: {images_dir}")

    imgs = [
        f for f in os.listdir(images_dir)
        if f.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))
    ]
    if len(imgs) < 3:
        raise ValueError(
            f"Au moins 3 photos requises pour la reconstruction (trouvé {len(imgs)})."
        )

    if output_dir is None:
        output_dir = tempfile.mkdtemp(prefix="artgens_recon_")
    os.makedirs(output_dir, exist_ok=True)

    # 1) pycolmap (CPU) en priorité : pas de GPU ni de binaire à installer.
    try:
        return _reconstruct_pycolmap(images_dir, output_dir, len(imgs))
    except ImportError:
        logger.info("pycolmap non installé, tentative COLMAP CLI.")
    except ReconstructionUnavailable:
        raise
    except Exception as e:
        logger.warning("pycolmap a échoué au runtime: %s", e)
        raise ReconstructionUnavailable("pycolmap a échoué au runtime: %s" % e)

    # 2) COLMAP CLI (qualité supérieure, dense si GPU) — uniquement si le
    # binaire existe réellement. Sinon on renvoie une 501 claire plutôt
    # que de planter sur un `colmap` introuvable.
    if _colmap_cli_available():
        return _reconstruct_colmap_cli(images_dir, output_dir, dense, len(imgs))

    raise ReconstructionUnavailable(
        "Aucun moteur de reconstruction disponible (pycolmap en échec, "
        "binaire colmap absent)."
    )


def _reconstruct_pycolmap(images_dir: str, output_dir: str, num_images: int) -> dict:
    # Limite les threads OpenMP/BLAS à 1 pour tenir dans la RAM du plan
    # gratuit (512 Mo) et éviter les OOM kills pendant SfM.
    os.environ["OMP_NUM_THREADS"] = "1"
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    os.environ["MKL_NUM_THREADS"] = "1"

    import pathlib
    import tempfile
    import numpy as np
    import pycolmap
    import open3d as o3d
    import cv2

    # Pré-traitement garde-fou pour la RAM du plan gratuit (512 Mo).
    # La sélection des ~40 meilleures vues ET le recadrage sur le cercle
    # (qualité maximale, petit fichier) sont faits côté app : on ne fait PAS
    # de réduction agressive de résolution ici. On garde juste un cap de
    # sécurité au cas où l'app enverrait trop d'images.
    MAX_DIM = 1600
    MAX_IMAGES = 40
    src = sorted(
        p
        for p in pathlib.Path(images_dir).iterdir()
        if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp")
    )
    if len(src) > MAX_IMAGES:
        step = len(src) / MAX_IMAGES
        src = [src[int(i * step)] for i in range(MAX_IMAGES)]

    proc_dir = pathlib.Path(tempfile.mkdtemp(prefix="artgens_proc_"))
    used = 0
    for i, p in enumerate(src):
        img = cv2.imread(str(p))
        if img is None:
            continue
        h, w = img.shape[:2]
        scale = min(1.0, MAX_DIM / max(h, w))
        if scale < 1.0:
            img = cv2.resize(img, (int(w * scale), int(h * scale)))
        cv2.imwrite(str(proc_dir / f"img_{i:04d}.jpg"), img)
        used += 1
    if used < 3:
        raise ValueError(
            f"Au moins 3 photos exploitables requises (trouvé {used})."
        )

    img_dir = proc_dir
    out = pathlib.Path(output_dir)
    db = out / "database.db"

    pycolmap.extract_features(db, img_dir)
    pycolmap.match_exhaustive(db)
    maps = pycolmap.incremental_mapping(db, img_dir, out)
    if not maps:
        raise RuntimeError("pycolmap: aucune reconstruction (pas assez de points communs).")

    recon = list(maps.values())[0]
    pts = [p.xyz for p in recon.points3D.values()]
    if len(pts) < 50:
        raise RuntimeError("pycolmap: nuage trop sparse pour un mesh fiable.")

    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(np.array(pts, dtype=np.float64))
    pcd.estimate_normals(
        search_param=o3d.geometry.KDTreeSearchParamHybrid(radius=0.02, max_nn=30)
    )
    mesh, _ = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(pcd, depth=8)
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    mesh_path = os.path.join(output_dir, "model.obj")
    o3d.io.write_triangle_mesh(mesh_path, mesh)
    return {
        "mesh": mesh_path,
        "point_cloud": None,
        "output_dir": output_dir,
        "dense": False,
        "engine": "pycolmap",
        "num_images": used,
        "num_points": len(pts),
    }


def _reconstruct_colmap_cli(images_dir: str, output_dir: str, dense: bool, num_images: int) -> dict:
    db = os.path.join(output_dir, "database.db")
    sparse = os.path.join(output_dir, "sparse")
    dense_dir = os.path.join(output_dir, "dense")
    os.makedirs(sparse, exist_ok=True)
    os.makedirs(dense_dir, exist_ok=True)

    _run([
        "feature_extractor",
        "--database_path", db,
        "--image_path", images_dir,
        "--ImageReader.camera_model", "SIMPLE_RADIAL",
    ])
    _run(["exhaustive_matcher", "--database_path", db])
    _run([
        "mapper",
        "--database_path", db,
        "--image_path", images_dir,
        "--output_path", sparse,
    ])

    model = os.path.join(sparse, "0")
    if not os.path.isdir(model):
        sub = [d for d in os.listdir(sparse) if os.path.isdir(os.path.join(sparse, d))]
        if not sub:
            raise RuntimeError("Reconstruction sparse échouée (aucun modèle produit).")
        model = os.path.join(sparse, sorted(sub)[0])

    if dense:
        _run([
            "image_undistorter",
            "--image_path", images_dir,
            "--input_path", model,
            "--output_path", dense_dir,
            "--output_type", "COLMAP",
        ])
        _run([
            "patch_match_stereo",
            "--workspace_path", dense_dir,
            "--workspace_format", "COLMAP",
        ])
        fused = os.path.join(output_dir, "fused.ply")
        _run(["stereo_fusion", "--workspace_path", dense_dir, "--output_path", fused])
        point_cloud = fused
    else:
        point_cloud = os.path.join(output_dir, "sparse.ply")
        _run([
            "model_converter",
            "--input_path", model,
            "--output_path", point_cloud,
            "--output_type", "PLY",
        ])

    mesh = _poisson_mesh(point_cloud, os.path.join(output_dir, "model.obj"))
    return {
        "mesh": mesh,
        "point_cloud": point_cloud,
        "output_dir": output_dir,
        "dense": dense,
        "engine": "colmap-cli",
        "num_images": num_images,
    }


def _run(args, cwd=None):
    logger.info("colmap %s", " ".join(args))
    r = subprocess.run(
        [COLMAP_BIN] + args, capture_output=True, text=True, cwd=cwd, timeout=1800
    )
    if r.returncode != 0:
        raise RuntimeError(
            f"colmap {' '.join(args)} a échoué (code {r.returncode}):\n{r.stderr}"
        )
    return r


def _poisson_mesh(ply_path: str, out_obj: str) -> str:
    import open3d as o3d

    pcd = o3d.io.read_point_cloud(ply_path)
    if pcd.is_empty():
        raise RuntimeError(f"Nuage de points vide: {ply_path}")
    if not pcd.has_normals():
        pcd.estimate_normals(
            search_param=o3d.geometry.KDTreeSearchParamHybrid(radius=0.02, max_nn=30)
        )
    pcd.orient_normals_consistent_towards_camera_location([0, 0, 0])
    mesh, _ = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(pcd, depth=9)
    mesh.remove_degenerate_triangles()
    mesh.remove_duplicated_vertices()
    mesh.remove_unreferenced_vertices()
    mesh.compute_vertex_normals()
    o3d.io.write_triangle_mesh(out_obj, mesh)
    return out_obj


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python reconstruction.py <dossier_photos> [--sparse]")
        sys.exit(1)
    folder = sys.argv[1]
    use_dense = "--sparse" not in sys.argv
    try:
        res = reconstruct_folder(folder, dense=use_dense)
    except RuntimeError as e:
        print("ÉCHEC:", e)
        sys.exit(2)
    print(json.dumps({k: v for k, v in res.items() if k != "mesh"}, indent=2))
    print("MESH:", res["mesh"])
