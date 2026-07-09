import math
from datetime import datetime
from sqlalchemy.orm import Session
from ..models.trade_session import TradeSession, TradeStatus, DeltaDirection
from ..models.piece import Piece
from ..services.piece_service import PieceService


class ColorMatchingService:
    @staticmethod
    def _extract_hsv(signature: dict, key: str) -> list[float]:
        if key in signature:
            return signature[key]
        return [0.0, 0.0, 0.0]

    @staticmethod
    def _hsv_distance(hsv1: list[float], hsv2: list[float]) -> float:
        if len(hsv1) < 3 or len(hsv2) < 3:
            return 1.0
        dh = abs(hsv1[0] - hsv2[0])
        if dh > 0.5:
            dh = 1.0 - dh
        ds = abs(hsv1[1] - hsv2[1])
        dv = abs(hsv1[2] - hsv2[2])
        return (dh + ds + dv) / 3.0

    @staticmethod
    def _best_match_hsv(query: list[float], references: list[list[float]]) -> float:
        if not references:
            return 1.0
        return min(ColorMatchingService._hsv_distance(query, ref) for ref in references)

    @staticmethod
    def extract_color_signature(capture_data: dict) -> dict:
        return capture_data.get("color_signature", {})

    @staticmethod
    def compare_signatures(current: dict, reference: dict) -> float:
        if not reference:
            return 0.0

        current_primary = ColorMatchingService._extract_hsv(current, "primary_hsv")
        ref_primary = ColorMatchingService._extract_hsv(reference, "primary_hsv")
        primary_dist = ColorMatchingService._hsv_distance(current_primary, ref_primary)

        current_colors = current.get("colors_hsv", [])
        ref_colors = reference.get("colors_hsv", [])
        if not current_colors or not ref_colors:
            return max(0.0, 1.0 - primary_dist)

        avg_color_dist = 0.0
        for q in current_colors:
            avg_color_dist += ColorMatchingService._best_match_hsv(q, ref_colors)
        avg_color_dist /= len(current_colors)

        weighted_primary = 0.4 * (1.0 - primary_dist)
        weighted_colors = 0.6 * (1.0 - avg_color_dist)
        return weighted_primary + weighted_colors

    @staticmethod
    def verify_and_update(db: Session, piece: Piece, new_signature: dict) -> bool:
        threshold = 0.6
        reference = piece.color_signature or {}
        score = ColorMatchingService.compare_signatures(new_signature, reference)

        if score >= threshold:
            PieceService.update_color_signature(db, piece.id, new_signature)

        return score >= threshold
