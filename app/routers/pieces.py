from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from typing import Optional
from ..database import get_db
from ..schemas.piece import PieceCreate, PieceResponse, PieceScanSubmit
from ..models.piece import Piece, PieceStatus
from ..models.user import User
from ..services.auth_service import get_current_user
from ..services.piece_service import PieceService
from ..services.matching_service import ColorMatchingService

router = APIRouter(prefix="/pieces", tags=["pieces"])


@router.get("/", response_model=list[PieceResponse])
def list_pieces(
    series_value: Optional[int] = Query(None),
    color_primary: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    db: Session = Depends(get_db),
):
    filters = {}
    if series_value: filters["series_value"] = series_value
    if color_primary: filters["color_primary"] = color_primary
    if status: filters["status"] = status
    return PieceService.get_all_pieces(db, filters)


@router.get("/{piece_id}", response_model=PieceResponse)
def get_piece(piece_id: str, db: Session = Depends(get_db)):
    return PieceService.get_piece_by_id(db, piece_id)


@router.post("/", response_model=PieceResponse)
def create_piece(data: PieceCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return PieceService.create_piece(db, data.model_dump(), current_user.id)


@router.post("/{piece_id}/scan")
def scan_piece(piece_id: str, data: PieceScanSubmit, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    piece = PieceService.get_piece_by_id(db, piece_id)
    is_match = ColorMatchingService.verify_and_update(db, piece, data.color_signature)
    return {"authenticity_match": is_match, "piece_id": piece_id}


@router.post("/{piece_id}/assign")
def assign_piece(piece_id: str, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    piece = PieceService.assign_to_user(db, piece_id, current_user.id)
    return {"status": "ok", "piece_id": piece.id}


@router.get("/{piece_id}/provenance")
def get_provenance(piece_id: str, db: Session = Depends(get_db)):
    from ..models.provenance_event import ProvenanceEvent
    events = db.query(ProvenanceEvent).filter(
        ProvenanceEvent.piece_id == piece_id
    ).order_by(ProvenanceEvent.timestamp.asc()).all()
    return events
