from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
from ..database import get_db
from ..models.egg_offer import EggOffer
from ..models.egg_identity import EggIdentity
from ..models.notification import Notification
from ..models.user import User
from ..services.auth_service import get_current_user


router = APIRouter(prefix="/egg-offers", tags=["egg-offers"])


class EggOfferCreate(BaseModel):
    target_egg_id: str
    offered_egg_id: str
    offered_pinceaux: int = 0


class EggOfferRespond(BaseModel):
    action: str  # "accept" or "decline"


def _create_notification(db: Session, user_id: str, type: str, egg_offer_id: str, content: str):
    notif = Notification(
        user_id=user_id,
        type=type,
        egg_offer_id=egg_offer_id,
        content=content,
    )
    db.add(notif)


@router.post("/")
def create_egg_offer(data: EggOfferCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    target_egg = db.query(EggIdentity).filter(EggIdentity.id == data.target_egg_id).first()
    if not target_egg:
        raise HTTPException(status_code=404, detail="Pierre cible introuvable")
    if not target_egg.current_owner_id:
        raise HTTPException(status_code=400, detail="Cette pierre n'a pas de propriétaire")
    if target_egg.current_owner_id == current_user.id:
        raise HTTPException(status_code=400, detail="Vous ne pouvez pas échanger avec vous-même")

    offered_egg = db.query(EggIdentity).filter(EggIdentity.id == data.offered_egg_id).first()
    if not offered_egg:
        raise HTTPException(status_code=404, detail="Pierre offerte introuvable")
    if offered_egg.current_owner_id != current_user.id:
        raise HTTPException(status_code=400, detail="Cette pierre ne vous appartient pas")

    if current_user.pinceaux_balance < data.offered_pinceaux:
        raise HTTPException(status_code=400, detail="Solde de pinceaux insuffisant")

    offer = EggOffer(
        from_user_id=current_user.id,
        to_user_id=target_egg.current_owner_id,
        target_egg_id=data.target_egg_id,
        offered_egg_id=data.offered_egg_id,
        offered_pinceaux=data.offered_pinceaux,
    )
    db.add(offer)
    db.flush()

    _create_notification(
        db, target_egg.current_owner_id, "egg_offer_received", offer.id,
        f"{current_user.pseudo} vous propose un échange pour {target_egg.display_number}"
    )

    db.commit()
    db.refresh(offer)
    return {
        "id": offer.id,
        "status": offer.status,
        "created_at": offer.created_at.isoformat() if offer.created_at else None,
    }


@router.post("/{offer_id}/respond")
def respond_egg_offer(offer_id: str, data: EggOfferRespond, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(EggOffer).filter(EggOffer.id == offer_id).first()
    if not offer:
        raise HTTPException(status_code=404, detail="Offre introuvable")
    if offer.to_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Pas votre offre")
    if offer.status != "pending":
        raise HTTPException(status_code=400, detail="Offre déjà traitée")

    if data.action == "accept":
        offer.status = "accepted"
        offer.responded_at = datetime.utcnow()

        target_egg = db.query(EggIdentity).filter(EggIdentity.id == offer.target_egg_id).first()
        offered_egg = db.query(EggIdentity).filter(EggIdentity.id == offer.offered_egg_id).first()

        if target_egg and offered_egg:
            target_egg.current_owner_id = offer.from_user_id
            offered_egg.current_owner_id = offer.to_user_id

            if offer.offered_pinceaux > 0:
                from_user = db.query(User).filter(User.id == offer.from_user_id).first()
                to_user = db.query(User).filter(User.id == offer.to_user_id).first()
                if from_user and to_user:
                    from_user.pinceaux_balance += offer.offered_pinceaux
                    to_user.pinceaux_balance -= offer.offered_pinceaux

        _create_notification(
            db, offer.from_user_id, "egg_offer_accepted", offer.id,
            f"{current_user.pseudo} a accepté votre échange"
        )

    elif data.action == "decline":
        offer.status = "declined"
        offer.responded_at = datetime.utcnow()

        _create_notification(
            db, offer.from_user_id, "egg_offer_declined", offer.id,
            f"{current_user.pseudo} a refusé votre échange"
        )
    else:
        raise HTTPException(status_code=400, detail="Action invalide")

    db.commit()
    return {"status": offer.status}


@router.get("/me")
def get_my_egg_offers(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offers = db.query(EggOffer).filter(
        (EggOffer.from_user_id == current_user.id) | (EggOffer.to_user_id == current_user.id)
    ).order_by(EggOffer.created_at.desc()).all()

    result = []
    for o in offers:
        target_egg = db.query(EggIdentity).filter(EggIdentity.id == o.target_egg_id).first()
        offered_egg = db.query(EggIdentity).filter(EggIdentity.id == o.offered_egg_id).first()
        from_user = db.query(User).filter(User.id == o.from_user_id).first()
        to_user = db.query(User).filter(User.id == o.to_user_id).first()
        result.append({
            "id": o.id,
            "from_user_id": o.from_user_id,
            "from_user_pseudo": from_user.pseudo if from_user else None,
            "to_user_id": o.to_user_id,
            "to_user_pseudo": to_user.pseudo if to_user else None,
            "target_egg_id": o.target_egg_id,
            "target_egg_display": target_egg.display_number if target_egg else None,
            "offered_egg_id": o.offered_egg_id,
            "offered_egg_display": offered_egg.display_number if offered_egg else None,
            "offered_pinceaux": o.offered_pinceaux,
            "status": o.status,
            "created_at": o.created_at.isoformat() if o.created_at else None,
        })
    return result


@router.get("/{offer_id}")
def get_egg_offer(offer_id: str, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(EggOffer).filter(EggOffer.id == offer_id).first()
    if not offer:
        raise HTTPException(status_code=404, detail="Offre introuvable")
    if offer.from_user_id != current_user.id and offer.to_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Pas votre offre")

    target_egg = db.query(EggIdentity).filter(EggIdentity.id == offer.target_egg_id).first()
    offered_egg = db.query(EggIdentity).filter(EggIdentity.id == offer.offered_egg_id).first()
    from_user = db.query(User).filter(User.id == offer.from_user_id).first()
    to_user = db.query(User).filter(User.id == offer.to_user_id).first()

    return {
        "id": offer.id,
        "from_user_id": offer.from_user_id,
        "from_user_pseudo": from_user.pseudo if from_user else None,
        "to_user_id": offer.to_user_id,
        "to_user_pseudo": to_user.pseudo if to_user else None,
        "target_egg_id": offer.target_egg_id,
        "target_egg_display": target_egg.display_number if target_egg else None,
        "offered_egg_id": offer.offered_egg_id,
        "offered_egg_display": offered_egg.display_number if offered_egg else None,
        "offered_pinceaux": offer.offered_pinceaux,
        "status": offer.status,
        "created_at": offer.created_at.isoformat() if offer.created_at else None,
    }
