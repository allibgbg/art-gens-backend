from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..schemas.user import UserResponse, UserUpdatePseudo
from ..models.user import User
from ..services.auth_service import get_current_user

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserResponse)
def get_me(current_user: User = Depends(get_current_user)):
    return current_user


@router.patch("/me/pseudo", response_model=UserResponse)
def update_pseudo(data: UserUpdatePseudo, db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    existing = db.query(User).filter(User.pseudo == data.pseudo, User.id != current_user.id).first()
    if existing:
        raise HTTPException(status_code=400, detail="Ce pseudo est déjà pris")
    current_user.pseudo = data.pseudo
    db.commit()
    db.refresh(current_user)
    return current_user


@router.patch("/me/onboarding", response_model=UserResponse)
def complete_onboarding(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    current_user.onboarding_completed = True
    db.commit()
    db.refresh(current_user)
    return current_user


@router.get("/me/pieces", response_model=list)
def get_my_pieces(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    from ..models.piece import Piece
    pieces = db.query(Piece).filter(Piece.current_owner_id == current_user.id).all()
    return pieces


@router.get("/me/offers", response_model=list)
def get_my_offers(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    from ..models.offer import Offer
    offers = db.query(Offer).filter(
        (Offer.from_user_id == current_user.id) | (Offer.to_user_id == current_user.id)
    ).all()
    return offers


@router.get("/me/wallet")
def get_wallet(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    from ..models.pinceaux_transaction import PinceauxTransaction
    transactions = db.query(PinceauxTransaction).filter(
        PinceauxTransaction.user_id == current_user.id
    ).order_by(PinceauxTransaction.timestamp.desc()).all()
    return {
        "balance": current_user.pinceaux_balance,
        "transactions": transactions,
    }
