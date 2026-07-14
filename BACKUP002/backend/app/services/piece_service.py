from sqlalchemy.orm import Session
from fastapi import HTTPException, status
from ..models.piece import Piece, PieceStatus
from ..models.scan_event import ScanEvent, ScanType
from ..models.provenance_event import ProvenanceEvent, EventType
from ..models.trade_session import TradeSession
from datetime import datetime


class PieceService:
    @staticmethod
    def create_piece(db: Session, piece_data: dict, artist_user_id: str) -> Piece:
        piece = Piece(**piece_data, status=PieceStatus.non_distribue)
        db.add(piece)
        db.commit()
        db.refresh(piece)
        return piece

    @staticmethod
    def get_all_pieces(db: Session, filters: dict = None) -> list[Piece]:
        query = db.query(Piece)
        if filters:
            if filters.get("series_value"):
                query = query.filter(Piece.series_value == filters["series_value"])
            if filters.get("color_primary"):
                query = query.filter(Piece.color_primary == filters["color_primary"])
            if filters.get("status"):
                query = query.filter(Piece.status == filters["status"])
        return query.all()

    @staticmethod
    def get_piece_by_id(db: Session, piece_id: str) -> Piece:
        piece = db.query(Piece).filter(Piece.id == piece_id).first()
        if not piece:
            raise HTTPException(status_code=404, detail="Pièce introuvable")
        return piece

    @staticmethod
    def assign_to_user(db: Session, piece_id: str, user_id: str) -> Piece:
        piece = PieceService.get_piece_by_id(db, piece_id)
        if piece.status != PieceStatus.non_distribue:
            raise HTTPException(status_code=400, detail="Cette pièce a déjà un propriétaire")

        piece.current_owner_id = user_id
        piece.status = PieceStatus.active
        db.commit()
        db.refresh(piece)

        provenance = ProvenanceEvent(
            piece_id=piece_id,
            to_user_id=user_id,
            event_type=EventType.don_initial,
        )
        db.add(provenance)
        db.commit()
        return piece

    @staticmethod
    def update_color_signature(db: Session, piece_id: str, color_signature: dict) -> Piece:
        piece = PieceService.get_piece_by_id(db, piece_id)
        history = piece.color_signature_history or []
        if piece.color_signature:
            history.append(piece.color_signature)
        piece.color_signature = color_signature
        piece.color_signature_history = history
        db.commit()
        db.refresh(piece)
        return piece
