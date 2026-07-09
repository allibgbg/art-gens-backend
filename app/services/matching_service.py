from datetime import datetime
from sqlalchemy.orm import Session
from ..models.trade_session import TradeSession, TradeStatus, DeltaDirection
from ..models.piece import Piece
from ..services.piece_service import PieceService


class ColorMatchingService:
    @staticmethod
    def extract_color_signature(capture_data: dict) -> dict:
        return capture_data.get("color_signature", {})

    @staticmethod
    def compare_signatures(current: dict, reference: dict) -> float:
        if not reference:
            return 0.0
        score = 0.0
        if current.get("primary") == reference.get("primary"):
            score += 0.3
        if current.get("secondary") == reference.get("secondary"):
            score += 0.2
        current_colors = set(current.get("colors", []))
        reference_colors = set(reference.get("colors", []))
        if reference_colors:
            intersection = current_colors & reference_colors
            score += 0.5 * (len(intersection) / len(reference_colors))
        return score

    @staticmethod
    def verify_and_update(db: Session, piece: Piece, new_signature: dict) -> bool:
        threshold = 0.6
        score = ColorMatchingService.compare_signatures(new_signature, piece.color_signature or {})
        is_match = score >= threshold

        PieceService.update_color_signature(db, piece.id, new_signature)
        return is_match
