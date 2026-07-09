from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..schemas.auth import TokenResponse, GoogleAuthRequest, FacebookAuthRequest
from ..services.auth_service import get_or_create_user, create_access_token
from ..models.user import User

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/google", response_model=TokenResponse)
def google_auth(req: GoogleAuthRequest, db: Session = Depends(get_db)):
    from google.oauth2 import id_token as google_id_token
    from google.auth.transport import requests
    from ..config import settings
    try:
        info = google_id_token.verify_oauth2_token(
            req.id_token,
            requests.Request(),
            settings.google_client_id,
        )
        sub = info.get("sub", "")
        email = info.get("email", "")
        name = info.get("name", "")

        user = get_or_create_user(db, "google", sub, email, name)
        token = create_access_token({"sub": user.id})
        return TokenResponse(access_token=token, user_id=user.id)
    except ValueError:
        raise HTTPException(status_code=401, detail="Token Google invalide")


@router.post("/facebook", response_model=TokenResponse)
def facebook_auth(req: FacebookAuthRequest, db: Session = Depends(get_db)):
    import httpx
    try:
        resp = httpx.get(
            f"https://graph.facebook.com/{req.user_id}",
            params={"access_token": req.access_token, "fields": "id,name,email"},
        )
        data = resp.json()
        if "error" in data:
            raise HTTPException(status_code=401, detail="Token Facebook invalide")

        user = get_or_create_user(db, "facebook", data["id"], data.get("email"), data.get("name"))
        token = create_access_token({"sub": user.id})
        return TokenResponse(access_token=token, user_id=user.id)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=401, detail="Token Facebook invalide")
