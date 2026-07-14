from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..schemas.offer import OfferCreate, OfferResponse, OfferAction, AppointmentCreate
from ..models.offer import Offer, OfferStatus
from ..models.appointment import Appointment, AppointmentStatus
from ..models.piece import Piece
from ..models.user import User
from ..services.auth_service import get_current_user

router = APIRouter(prefix="/offers", tags=["offers"])


@router.post("/", response_model=OfferResponse)
def create_offer(data: OfferCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    target = db.query(Piece).filter(Piece.id == data.target_piece_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="Pièce cible introuvable")
    if not target.current_owner_id:
        raise HTTPException(status_code=400, detail="Cette pièce n'a pas encore de propriétaire")
    if target.current_owner_id == current_user.id:
        raise HTTPException(status_code=400, detail="Vous ne pouvez pas faire une offre sur votre propre pièce")

    offered = db.query(Piece).filter(Piece.id == data.offered_piece_id).first()
    if not offered:
        raise HTTPException(status_code=404, detail="Pièce proposée introuvable")
    if offered.current_owner_id != current_user.id:
        raise HTTPException(status_code=400, detail="Vous ne possédez pas cette pièce")

    offer = Offer(
        from_user_id=current_user.id,
        to_user_id=target.current_owner_id,
        target_piece_id=data.target_piece_id,
        offered_piece_id=data.offered_piece_id,
        offered_pinceaux=data.offered_pinceaux,
    )
    db.add(offer)
    db.commit()
    db.refresh(offer)
    return offer


@router.post("/{offer_id}/respond")
def respond_offer(offer_id: str, data: OfferAction, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(Offer).filter(Offer.id == offer_id).first()
    if not offer:
        raise HTTPException(status_code=404, detail="Offre introuvable")
    if offer.to_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Cette offre ne vous est pas adressée")

    if data.action == "accept":
        offer.status = OfferStatus.accepted
    elif data.action == "decline":
        offer.status = OfferStatus.declined
    else:
        raise HTTPException(status_code=400, detail="Action invalide (accept/decline)")

    db.commit()
    return {"status": offer.status.value}


@router.post("/{offer_id}/appointment")
def create_appointment(offer_id: str, data: AppointmentCreate, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    offer = db.query(Offer).filter(Offer.id == offer_id).first()
    if not offer or offer.status != OfferStatus.accepted:
        raise HTTPException(status_code=400, detail="L'offre doit être acceptée d'abord")

    appointment = Appointment(
        offer_id=offer_id,
        location=data.location,
        scheduled_at=data.scheduled_at,
    )
    db.add(appointment)
    db.commit()
    return {"status": "ok", "appointment_id": appointment.id}
