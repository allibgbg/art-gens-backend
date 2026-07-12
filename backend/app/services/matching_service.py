import math
import base64
import io
import numpy as np
import cv2
from sqlalchemy.orm import Session
from ..models.piece import Piece
from ..services.piece_service import PieceService


class ColorMatchingService:
    """Filtre de pré-tri basé sur la signature couleur spatiale."""

    SEUIL_COULEUR = 0.45

    @staticmethod
    def _lab_distance(a1: float, b1: float, a2: float, b2: float) -> float:
        d = math.sqrt((a1 - a2) ** 2 + (b1 - b2) ** 2)
        return min(1.0, d / 200.0)

    @staticmethod
    def _match_zone(query_colors: list[dict], ref_colors: list[dict]) -> float:
        if not query_colors or not ref_colors:
            return 0.0
        scores = []
        for q in query_colors:
            qa, qb = q["a"], q["b"]
            best = min(
                ColorMatchingService._lab_distance(qa, qb, r["a"], r["b"])
                for r in ref_colors
            )
            scores.append(1.0 - best)
        return sum(scores) / len(scores) if scores else 0.0

    @staticmethod
    def _validate_spatial_signature(sig: dict) -> bool:
        return (
            "rows" in sig
            and "cols" in sig
            and "zones" in sig
            and len(sig["zones"]) == sig["rows"]
        )

    @staticmethod
    def _rotate_signature_180(sig: dict) -> dict:
        rows = sig["rows"]
        cols = sig["cols"]
        rotated_zones = [[None] * cols for _ in range(rows)]
        for r in range(rows):
            for c in range(cols):
                rotated_zones[rows - 1 - r][cols - 1 - c] = sig["zones"][r][c]
        return {"rows": rows, "cols": cols, "zones": rotated_zones}

    @staticmethod
    def _raw_compare(current: dict, reference: dict) -> float:
        rows = reference["rows"]
        cols = reference["cols"]
        zone_scores = []
        zone_weights = []
        for r in range(rows):
            for c in range(cols):
                ref_zone = reference["zones"][r][c]
                cur_zone = current["zones"][r][c]
                if not ref_zone:
                    continue
                score = ColorMatchingService._match_zone(cur_zone, ref_zone)
                weight = min(1.0, len(ref_zone) / 10.0)
                zone_scores.append(score)
                zone_weights.append(weight)
        if not zone_scores:
            return 0.0
        total_weight = sum(zone_weights)
        if total_weight == 0:
            return 0.0
        return sum(s * w for s, w in zip(zone_scores, zone_weights)) / total_weight

    @staticmethod
    def compare_signatures(current: dict, reference: dict) -> float:
        if not reference or not current:
            return 0.0
        if not ColorMatchingService._validate_spatial_signature(current) or \
           not ColorMatchingService._validate_spatial_signature(reference):
            return 0.0
        score_normal = ColorMatchingService._raw_compare(current, reference)
        rotated = ColorMatchingService._rotate_signature_180(current)
        score_rotated = ColorMatchingService._raw_compare(rotated, reference)
        return max(score_normal, score_rotated)


class TextureMatchingService:
    """Matching ORB + RANSAC sur le fond poncé (60% du score final)."""

    SEUIL_TEXTURE = 0.55
    MIN_FEATURES = 30
    MIN_GEOMETRIC_INLIERS = 8
    RANSAC_REPROJ_THRESHOLD = 5.0

    @staticmethod
    def _descriptors_to_np(desc_data: list[list[float]]) -> np.ndarray:
        return np.array(desc_data, dtype=np.uint8)

    @staticmethod
    def _keypoints_to_np(kp_data: list[dict]) -> np.ndarray | None:
        try:
            return np.array([[kp["x"], kp["y"]] for kp in kp_data], dtype=np.float32)
        except (KeyError, TypeError):
            return None

    @staticmethod
    def match(query: dict, reference: dict) -> tuple[float, int, int, bool]:
        if not query or not reference:
            return (0.0, 0, 0, False)
        q_desc = query.get("descriptors")
        r_desc = reference.get("descriptors")
        if not q_desc or not r_desc:
            return (0.0, 0, 0, False)
        try:
            q_np = TextureMatchingService._descriptors_to_np(q_desc)
            r_np = TextureMatchingService._descriptors_to_np(r_desc)
        except Exception:
            return (0.0, 0, 0, False)
        q_count = q_np.shape[0]
        r_count = r_np.shape[0]
        if q_count < TextureMatchingService.MIN_FEATURES or r_count < TextureMatchingService.MIN_FEATURES:
            return (0.0, min(q_count, r_count), 0, False)
        bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
        matches = bf.match(q_np, r_np)
        if not matches:
            return (0.0, 0, 0, False)
        raw_match_count = len(matches)
        q_kpts = TextureMatchingService._keypoints_to_np(query.get("keypoints") or [])
        r_kpts = TextureMatchingService._keypoints_to_np(reference.get("keypoints") or [])
        if (
            q_kpts is not None and r_kpts is not None
            and len(q_kpts) == q_count and len(r_kpts) == r_count
            and raw_match_count >= 3
        ):
            src_pts = np.array([q_kpts[m.queryIdx] for m in matches], dtype=np.float32)
            dst_pts = np.array([r_kpts[m.trainIdx] for m in matches], dtype=np.float32)
            _, inlier_mask = cv2.estimateAffinePartial2D(
                src_pts, dst_pts,
                method=cv2.RANSAC,
                ransacReprojThreshold=TextureMatchingService.RANSAC_REPROJ_THRESHOLD,
            )
            if inlier_mask is None:
                geometric_inliers = 0
                inlier_matches = []
            else:
                inlier_mask = inlier_mask.ravel().astype(bool)
                geometric_inliers = int(inlier_mask.sum())
                inlier_matches = [m for m, keep in zip(matches, inlier_mask) if keep]
            scoring_matches = inlier_matches if inlier_matches else matches
            distances = [m.distance for m in scoring_matches]
            avg_distance = sum(distances) / len(distances)
            score = max(0.0, min(1.0, 1.0 - (avg_distance / 256.0)))
            return (score, raw_match_count, geometric_inliers, True)
        distances = [m.distance for m in matches]
        avg_distance = sum(distances) / len(distances)
        score = max(0.0, min(1.0, 1.0 - (avg_distance / 256.0)))
        return (score, raw_match_count, 0, False)


class TopImageAnalysisService:
    """
    Analyse l'image du dessus (base64 stockée) pour deux signatures :
    - Forme du chiffre (moments de Hu) → 20% du score final
    - Texture locale autour du chiffre (LBP) → 20% du score final
    """

    SEUIL_HU = 0.6
    SEUIL_LBP = 0.5

    @staticmethod
    def _decode_image(top_image_b64: str) -> np.ndarray | None:
        try:
            data = base64.b64decode(top_image_b64)
            arr = np.frombuffer(data, dtype=np.uint8)
            return cv2.imdecode(arr, cv2.IMREAD_COLOR)
        except Exception:
            return None

    @staticmethod
    def _extract_digit_region(img: np.ndarray) -> tuple[np.ndarray | None, np.ndarray | None]:
        """
        Extrait le contour du chiffre (pour Hu) et la région autour (pour LBP).
        Retourne (binary_mask, gray_crop).
        """
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        # Otsu binarisation : le chiffre gravé est généralement plus foncé
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        kernel = np.ones((3, 3), np.uint8)
        binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)
        contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            return (None, None)
        # Prendre le plus grand contour (supposé être le chiffre)
        main = max(contours, key=cv2.contourArea)
        x, y, w, h = cv2.boundingRect(main)
        # Marge de 50% autour du chiffre pour le LBP
        margin = int(max(w, h) * 0.5)
        x1 = max(0, x - margin)
        y1 = max(0, y - margin)
        x2 = min(img.shape[1], x + w + margin)
        y2 = min(img.shape[0], y + h + margin)
        # Masque binaire du chiffre seul pour Hu
        mask = np.zeros(gray.shape, dtype=np.uint8)
        cv2.drawContours(mask, [main], -1, 255, -1)
        mask_crop = mask[y1:y2, x1:x2]
        # Crop gray pour LBP
        gray_crop = gray[y1:y2, x1:x2]
        return (mask_crop, gray_crop)

    @staticmethod
    def _hu_score(query_b64: str, ref_b64: str) -> float:
        """
        Compare deux images par leurs moments de Hu invariants.
        Score = 1.0 (identiques) à 0.0 (très différents).
        """
        img_q = TopImageAnalysisService._decode_image(query_b64)
        img_r = TopImageAnalysisService._decode_image(ref_b64)
        if img_q is None or img_r is None:
            return 0.0
        mask_q, _ = TopImageAnalysisService._extract_digit_region(img_q)
        mask_r, _ = TopImageAnalysisService._extract_digit_region(img_r)
        if mask_q is None or mask_r is None:
            return 0.0
        hu_q = cv2.HuMoments(cv2.moments(mask_q)).flatten()
        hu_r = cv2.HuMoments(cv2.moments(mask_r)).flatten()
        # Transformation log pour compensation d'échelle
        hu_q = -np.sign(hu_q) * np.log(np.abs(hu_q) + 1e-10)
        hu_r = -np.sign(hu_r) * np.log(np.abs(hu_r) + 1e-10)
        # Distance euclidienne normalisée
        dist = np.linalg.norm(hu_q - hu_r)
        score = 1.0 - min(1.0, dist / 10.0)
        return max(0.0, score)

    @staticmethod
    def _lbp_score(query_b64: str, ref_b64: str) -> float:
        """
        Compare la texture locale autour du chiffre via LBP (Local Binary Pattern).
        Implémentation manuelle (P=8, R=1) — pas de dépendance skimage.
        """
        img_q = TopImageAnalysisService._decode_image(query_b64)
        img_r = TopImageAnalysisService._decode_image(ref_b64)
        if img_q is None or img_r is None:
            return 0.0
        _, crop_q = TopImageAnalysisService._extract_digit_region(img_q)
        _, crop_r = TopImageAnalysisService._extract_digit_region(img_r)
        if crop_q is None or crop_r is None or crop_q.size < 64 or crop_r.size < 64:
            return 0.0

        def _lbp_hist(gray: np.ndarray) -> np.ndarray:
            h, w = gray.shape
            lbp = np.zeros((h - 2, w - 2), dtype=np.uint8)
            for r in range(1, h - 1):
                for c in range(1, w - 1):
                    center = gray[r, c]
                    code = 0
                    code |= (gray[r-1, c-1] > center) << 7
                    code |= (gray[r-1, c]   > center) << 6
                    code |= (gray[r-1, c+1] > center) << 5
                    code |= (gray[r,   c+1] > center) << 4
                    code |= (gray[r+1, c+1] > center) << 3
                    code |= (gray[r+1, c]   > center) << 2
                    code |= (gray[r+1, c-1] > center) << 1
                    code |= (gray[r,   c-1] > center) << 0
                    lbp[r-1, c-1] = code
            hist = cv2.calcHist([lbp.astype(np.float32)], [0], None, [256], [0, 256])
            cv2.normalize(hist, hist, 0, 1, cv2.NORM_MINMAX)
            return hist.flatten()

        hist_q = _lbp_hist(crop_q)
        hist_r = _lbp_hist(crop_r)
        # Corrélation : 1 = parfait, -1 = inverse
        corr = cv2.compareHist(hist_q, hist_r, cv2.HISTCMP_CORREL)
        return max(0.0, corr)

    @staticmethod
    def compare(query_b64: str, reference_b64: str) -> dict:
        return {
            "hu_score": TopImageAnalysisService._hu_score(query_b64, reference_b64),
            "lbp_score": TopImageAnalysisService._lbp_score(query_b64, reference_b64),
        }


class MatchingOrchestrator:
    """
    Scoring final à 3 composantes :
    - 60% : texture fond (ORB + RANSAC)
    - 20% : forme chiffre (moments de Hu)
    - 20% : motifs LBP invariants à l'éclairage
    """

    SEUIL_FINAL = 0.65
    POIDS_TEXTURE = 0.5
    POIDS_HU = 0.2
    POIDS_LBP = 0.15
    POIDS_COULEUR = 0.15

    @staticmethod
    def verify_piece(
        db: Session,
        piece: Piece,
        color_signature: dict | None = None,
        texture_signature: dict | None = None,
        query_top_image: str | None = None,
    ) -> dict:
        result = {
            "match": False,
            "color_score": None,
            "texture_score": None,
            "hu_score": None,
            "lbp_score": None,
            "match_count": 0,
            "geometric_inliers": 0,
            "geometry_verified": False,
        }

        if color_signature and piece.color_signature:
            result["color_score"] = ColorMatchingService.compare_signatures(
                color_signature, piece.color_signature
            )

        texture_score = 0.0
        hu_score = 0.0
        lbp_score = 0.0

        if texture_signature and piece.texture_signature:
            ts, mc, gi, gv = TextureMatchingService.match(
                texture_signature, piece.texture_signature
            )
            texture_score = ts
            result["texture_score"] = ts
            result["match_count"] = mc
            result["geometric_inliers"] = gi
            result["geometry_verified"] = gv

        # Analyse image du dessus (Hu + LBP) si disponibles
        if query_top_image and piece.top_image:
            scores = TopImageAnalysisService.compare(query_top_image, piece.top_image)
            hu_score = scores["hu_score"]
            lbp_score = scores["lbp_score"]
            result["hu_score"] = hu_score
            result["lbp_score"] = lbp_score

        # Score combiné pondéré (texture = décision finale, couleur = pré-tri intégré)
        combined = (
            MatchingOrchestrator.POIDS_TEXTURE * texture_score
            + MatchingOrchestrator.POIDS_HU * hu_score
            + MatchingOrchestrator.POIDS_LBP * lbp_score
            + (MatchingOrchestrator.POIDS_COULEUR * result["color_score"]
               if result["color_score"] is not None else 0.0)
        )
        result["combined_score"] = combined
        result["match"] = combined >= MatchingOrchestrator.SEUIL_FINAL

        return result
