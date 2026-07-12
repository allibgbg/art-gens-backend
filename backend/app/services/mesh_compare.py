"""Comparaison de deux meshes 3D pour l'authentification d'objet.

On aligne le mesh candidat sur le mesh de référence (même objet, scanné
à des moments différents) via :
  - normalisation (centrage + échelle ramenée au diag de bbox = 1)
  - recalage global FPFH + RANSAC (rotation)
  - raffinement GeneralizedICP (translation + échelle + rotation fine)

Puis on mesure la distance point-à-mesh et on renvoie un score de similarité
(fraction de points candidat proches du mesh de référence). Espace normalisé
=> indépendant de l'échelle absolue de la reconstruction COLMAP.
"""
import sys
import json
import numpy as np


def _load_normalize(path: str, n: int = 30000):
    import open3d as o3d  # import paresseux

    mesh = o3d.io.read_triangle_mesh(path)
    if mesh.is_empty():
        raise ValueError(f"Mesh vide ou illisible: {path}")
    if not mesh.has_vertex_normals():
        mesh.compute_vertex_normals()
    pcd = mesh.sample_points_uniformly(number_of_points=n)
    pts = np.asarray(pcd.points, dtype=np.float64)
    pts = pts - pts.mean(axis=0)
    diag = float(np.linalg.norm(pts.max(axis=0) - pts.min(axis=0)))
    if diag <= 1e-9:
        raise ValueError("Objet dégénéré (diagonale nulle).")
    pts = pts / diag  # bbox diag = 1
    pcd.points = o3d.utility.Vector3dVector(pts)
    return pcd


VOXEL = 0.01  # 1% de la taille normalisée


def _preprocess(pcd):
    import open3d as o3d

    down = pcd.voxel_down_sample(VOXEL)
    down.estimate_normals(
        search_param=o3d.geometry.KDTreeSearchParamHybrid(radius=VOXEL * 2, max_nn=30)
    )
    fpfh = o3d.pipelines.registration.compute_fpfh_feature(
        down, o3d.geometry.KDTreeSearchParamHybrid(radius=VOXEL * 5, max_nn=100)
    )
    return down, fpfh


def compare_meshes(ref_path: str, curr_path: str, threshold: float = 0.02) -> dict:
    import open3d as o3d

    reg = o3d.pipelines.registration
    ref = _load_normalize(ref_path)
    cur = _load_normalize(curr_path)

    ref_d, ref_f = _preprocess(ref)
    cur_d, cur_f = _preprocess(cur)

    ransac = reg.registration_ransac_based_on_feature_matching(
        cur_d, ref_d, cur_f, ref_f,
        True,
        reg.TransformationEstimationPointToPoint(False),
        4,
        [
            reg.CorrespondenceCheckerBasedOnEdgeLength(0.9),
            reg.CorrespondenceCheckerBasedOnDistance(VOXEL * 10),
        ],
        reg.RANSACConvergenceCriteria(max_iteration=100000, confidence=0.999),
    )

    icp = reg.registration_icp(
        cur, ref, threshold, ransac.transformation,
        reg.TransformationEstimationForGeneralizedICP(),
    )
    cur.transform(icp.transformation)

    dists = np.asarray(cur.compute_point_cloud_distance(ref))
    mean = float(dists.mean())
    maxd = float(dists.max())
    rmse = float(np.sqrt(np.mean(dists ** 2)))
    within = float((dists < threshold).mean())

    return {
        "score": within,
        "mean_distance_norm": mean,
        "max_distance_norm": maxd,
        "rmse_norm": rmse,
        "fraction_within_threshold": within,
        "threshold": threshold,
        "ransac_fitness": float(ransac.fitness),
        "icp_fitness": float(icp.fitness),
        "transformation": np.asarray(icp.transformation).tolist(),
    }


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python mesh_compare.py <ref.obj> <candidat.obj> [seuil]")
        sys.exit(1)
    thr = float(sys.argv[3]) if len(sys.argv) > 3 else 0.02
    res = compare_meshes(sys.argv[1], sys.argv[2], thr)
    print(json.dumps(res, indent=2))
