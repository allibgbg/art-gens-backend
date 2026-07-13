import uuid as _uuid
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from typing import Optional, List
from pydantic import BaseModel
from ..database import get_db
from ..models.egg_identity import EggIdentity
from ..services.auth_service import get_current_artist


class EggIdentityCreate(BaseModel):
    display_number: str
    series_value: int
    digit_number: Optional[str] = None
    notes: Optional[str] = None
    face_photo: Optional[str] = None  # base64 JPEG
    identity_data: dict  # {version, image_w, image_h, quality, points: [...]}


class EggIdentityUpdate(BaseModel):
    display_number: Optional[str] = None
    series_value: Optional[int] = None
    digit_number: Optional[str] = None
    notes: Optional[str] = None


router = APIRouter(prefix="/egg-identity", tags=["egg-identity"])


@router.post("/")
def create_egg_identity(
    data: EggIdentityCreate,
    db: Session = Depends(get_db),
):
    egg = EggIdentity(
        id=str(_uuid.uuid4()),
        display_number=data.display_number,
        series_value=data.series_value,
        digit_number=data.digit_number,
        notes=data.notes,
        face_photo=data.face_photo,
        identity_data=data.identity_data,
    )
    db.add(egg)
    db.commit()
    db.refresh(egg)
    return {"id": egg.id, "status": "ok"}


@router.get("/")
def list_egg_identities(
    series_value: Optional[int] = Query(None),
    db: Session = Depends(get_db),
):
    q = db.query(EggIdentity)
    if series_value is not None:
        q = q.filter(EggIdentity.series_value == series_value)
    eggs = q.order_by(EggIdentity.created_at.desc()).all()
    return [
        {
            "id": e.id,
            "display_number": e.display_number,
            "series_value": e.series_value,
            "digit_number": e.digit_number,
            "notes": e.notes,
            "has_face_photo": e.face_photo is not None,
            "has_identity": e.identity_data is not None,
            "points_count": len(e.identity_data.get("points", [])) if e.identity_data else 0,
            "created_at": e.created_at.isoformat() if e.created_at else None,
        }
        for e in eggs
    ]


@router.get("/{egg_id}")
def get_egg_identity(egg_id: str, db: Session = Depends(get_db)):
    egg = db.query(EggIdentity).filter(EggIdentity.id == egg_id).first()
    if not egg:
        return {"error": "not_found"}
    return {
        "id": egg.id,
        "display_number": egg.display_number,
        "series_value": egg.series_value,
        "digit_number": egg.digit_number,
        "notes": egg.notes,
        "face_photo": egg.face_photo,
        "identity_data": egg.identity_data,
        "created_at": egg.created_at.isoformat() if egg.created_at else None,
    }


@router.patch("/{egg_id}")
def update_egg_identity(egg_id: str, data: EggIdentityUpdate, db: Session = Depends(get_db)):
    egg = db.query(EggIdentity).filter(EggIdentity.id == egg_id).first()
    if not egg:
        return {"error": "not_found"}
    for key, val in data.model_dump(exclude_none=True).items():
        setattr(egg, key, val)
    db.commit()
    return {"status": "ok"}


@router.delete("/{egg_id}")
def delete_egg_identity(egg_id: str, db: Session = Depends(get_db)):
    egg = db.query(EggIdentity).filter(EggIdentity.id == egg_id).first()
    if not egg:
        return {"error": "not_found"}
    db.delete(egg)
    db.commit()
    return {"status": "deleted"}
