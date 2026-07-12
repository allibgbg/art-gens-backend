from fastapi import APIRouter, Depends
from typing import List
from pydantic import BaseModel
from ..models.user import User
from ..services.auth_service import get_current_artist
from ..services import digit_auth as digit_auth_service

router = APIRouter(prefix="/digits", tags=["digits"])


class DigitHu(BaseModel):
    value: str
    hu: List[float]


@router.post("/verify")
def verify_digit(
    body: DigitHu,
    current_user: User = Depends(get_current_artist),
):
    """Vérifie qu'un chiffre détecté correspond au moule officiel (auth)."""
    return digit_auth_service.verify(body.value, body.hu)


@router.post("/reference")
def set_reference(
    body: DigitHu,
    current_user: User = Depends(get_current_artist),
):
    """Définit la référence officielle d'un moule (à faire sur objet authentique)."""
    digit_auth_service.set_reference(body.value, body.hu)
    return {"ok": True, "value": body.value}
