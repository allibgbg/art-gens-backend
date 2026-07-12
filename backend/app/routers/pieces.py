import uuid as _uuid
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from typing import Optional, Any
from ..database import get_db
from ..schemas.piece import PieceCreate, PieceResponse, PieceScanSubmit
from ..models.piece import Piece, PieceStatus, ColorEnum
from ..models.user import User
from ..services.auth_service import get_current_user, get_current_artist
from ..services.piece_service import PieceService
from ..services.matching_service import MatchingOrchestrator
from pydantic import BaseModel


class PieceDraft(BaseModel):
    texture_signature: Optional[Any] = None
    digit_guess: Optional[str] = None
    top_image: Optional[str] = None


class PieceUpdate(BaseModel):
    top_image: Optional[str] = None
    color_signature: Optional[Any] = None
    texture_signature: Optional[Any] = None


class PieceFinalize(BaseModel):
    display_number: str
    series_value: int
    reference_pinceaux_value: int
    color_primary: str = "multicolore"
    color_secondary: Optional[str] = None
    material_notes: Optional[str] = None
    artist_note: Optional[str] = None


router = APIRouter(prefix="/pieces", tags=["pieces"])


# Routes à chemin fixe (doivent être AVANT les routes paramétrées /{piece_id})
@router.get("/")
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


@router.post("/")
def create_piece(data: PieceCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_artist)):
    return PieceService.create_piece(db, data.model_dump(), current_user.id)


    _PINCEAUX_BY_SERIES = {2: 40, 5: 100}


@router.post("/draft")
def draft_piece(data: PieceDraft, db: Session = Depends(get_db), current_user: User = Depends(get_current_artist)):
    pid = str(_uuid.uuid4())
    series_value = 0
    if data.digit_guess and data.digit_guess.isdigit():
        series_value = int(data.digit_guess)
    piece = Piece(
        id=pid,
        display_number=pid[:10],
        series_value=series_value,
        reference_pinceaux_value=_PINCEAUX_BY_SERIES.get(series_value, 0),
        color_primary=ColorEnum.multicolore,
        texture_signature=data.texture_signature,
        top_image=data.top_image,
        status=PieceStatus.non_distribue,
    )
    db.add(piece)
    db.commit()
    db.refresh(piece)
    return {"id": piece.id, "status": "draft"}


# Routes paramétrées
@router.get("/{piece_id}", response_model=PieceResponse)
def get_piece(piece_id: str, db: Session = Depends(get_db)):
    return PieceService.get_piece_by_id(db, piece_id)


@router.patch("/{piece_id}")
def update_piece(piece_id: str, data: PieceUpdate, db: Session = Depends(get_db), current_user: User = Depends(get_current_artist)):
    piece = PieceService.get_piece_by_id(db, piece_id)
    for key, val in data.model_dump(exclude_none=True).items():
        setattr(piece, key, val)
    db.commit()
    db.refresh(piece)
    return {"status": "ok", "piece_id": piece_id}


@router.post("/{piece_id}/finalize")
def finalize_piece(piece_id: str, data: PieceFinalize, db: Session = Depends(get_db), current_user: User = Depends(get_current_artist)):
    piece = PieceService.get_piece_by_id(db, piece_id)
    for key, val in data.model_dump().items():
        setattr(piece, key, val)
    piece.status = PieceStatus.non_distribue
    db.commit()
    db.refresh(piece)
    return {"status": "ok", "piece_id": piece_id}


@router.post("/{piece_id}/scan")
def scan_piece(piece_id: str, data: PieceScanSubmit, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    piece = PieceService.get_piece_by_id(db, piece_id)
    result = MatchingOrchestrator.verify_piece(
        db, piece,
        color_signature=data.color_signature,
        texture_signature=data.texture_signature,
        query_top_image=data.top_image,
    )
    return {
        "authenticity_match": result["match"],
        "piece_id": piece_id,
        "color_score": result["color_score"],
        "texture_score": result["texture_score"],
        "hu_score": result["hu_score"],
        "lbp_score": result["lbp_score"],
        "combined_score": result.get("combined_score"),
        "match_count": result["match_count"],
        "geometric_inliers": result["geometric_inliers"],
        "geometry_verified": result["geometry_verified"],
    }


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
