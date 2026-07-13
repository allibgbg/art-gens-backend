from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..schemas.trade import TradeSessionResponse, TradeScanUpdate, TradeDeltaUpdate, TradeConfirm
from ..models.trade_session import TradeSession
from ..models.user import User
from ..services.auth_service import get_current_user
from ..services.trade_service import TradeService

router = APIRouter(prefix="/trades", tags=["trades"])


@router.post("/", response_model=TradeSessionResponse)
def create_trade(participant_b_id: str, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    if current_user.id == participant_b_id:
        raise HTTPException(status_code=400, detail="Impossible de créer un échange avec soi-même")
    return TradeService.create_session(db, current_user.id, participant_b_id)


@router.get("/{session_id}", response_model=TradeSessionResponse)
def get_trade(session_id: str, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    session = TradeService.get_session(db, session_id)
    if current_user.id not in (session.participant_a_id, session.participant_b_id):
        raise HTTPException(status_code=403, detail="Accès refusé")
    return session


@router.post("/{session_id}/scan")
def scan_in_trade(session_id: str, data: TradeScanUpdate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    session = TradeService.scan_piece(db, session_id, data.piece_id, current_user.id, data.capture_data, data.color_signature)
    return session


@router.post("/{session_id}/delta")
def update_delta(session_id: str, data: TradeDeltaUpdate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    session = TradeService.update_delta(db, session_id, data.delta_pinceaux, data.delta_direction)
    return session


@router.post("/{session_id}/confirm")
def confirm_trade(session_id: str, data: TradeConfirm, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    session = TradeService.confirm(db, session_id, current_user.id)
    return session
