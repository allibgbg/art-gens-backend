from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from ..database import get_db
from ..models.trade_message import TradeMessage
from ..models.egg_offer import EggOffer
from ..models.notification import Notification
from ..models.user import User
from ..services.auth_service import get_current_user


router = APIRouter(prefix="/egg-offers", tags=["messages"])


class MessageCreate(BaseModel):
    content: str


@router.post("/{offer_id}/messages")
def send_message(offer_id: str, data: MessageCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(EggOffer).filter(EggOffer.id == offer_id).first()
    if not offer:
        raise HTTPException(status_code=404, detail="Offre introuvable")
    if offer.from_user_id != current_user.id and offer.to_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Pas votre offre")
    if offer.status != "accepted":
        raise HTTPException(status_code=400, detail="Messages disponibles uniquement après acceptation")

    msg = TradeMessage(
        egg_offer_id=offer_id,
        sender_id=current_user.id,
        content=data.content,
    )
    db.add(msg)
    db.flush()

    recipient_id = offer.to_user_id if current_user.id == offer.from_user_id else offer.from_user_id
    notif = Notification(
        user_id=recipient_id,
        type="message_received",
        egg_offer_id=offer_id,
        content=f"Nouveau message de {current_user.pseudo}",
    )
    db.add(notif)

    db.commit()
    db.refresh(msg)
    return {
        "id": msg.id,
        "sender_id": msg.sender_id,
        "content": msg.content,
        "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }


@router.get("/{offer_id}/messages")
def list_messages(offer_id: str, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(EggOffer).filter(EggOffer.id == offer_id).first()
    if not offer:
        raise HTTPException(status_code=404, detail="Offre introuvable")
    if offer.from_user_id != current_user.id and offer.to_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Pas votre offre")

    messages = db.query(TradeMessage).filter(
        TradeMessage.egg_offer_id == offer_id
    ).order_by(TradeMessage.created_at.asc()).all()

    return [
        {
            "id": m.id,
            "sender_id": m.sender_id,
            "content": m.content,
            "created_at": m.created_at.isoformat() if m.created_at else None,
        }
        for m in messages
    ]
