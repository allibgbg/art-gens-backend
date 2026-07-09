from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..schemas.auth import TokenResponse, GoogleAuthRequest, FacebookAuthRequest
from ..services.auth_service import get_or_create_user, create_access_token
from ..models.user import User
import httpx

router = APIRouter(prefix="/auth", tags=["auth"])


class _HttpxResponse:
    """Minimal google.auth.transport.Response wrapper for httpx."""
    def __init__(self, r: httpx.Response):
        self._r = r
    @property
    def status(self) -> int:
        return self._r.status_code
    @property
    def headers(self):
        return self._r.headers
    @property
    def data(self) -> bytes:
        return self._r.content


class _HttpxRequest:
    """Minimal google.auth.transport.Request using httpx."""
    def __call__(self, url, method="GET", body=None, headers=None, timeout=None, **kwargs):
        try:
            r = httpx.request(method, url, content=body, headers=headers, timeout=timeout)
            return _HttpxResponse(r)
        except Exception as e:
            from google.auth.exceptions import TransportError
            raise TransportError(str(e)) from e


@router.post("/google", response_model=TokenResponse)
def google_auth(req: GoogleAuthRequest, db: Session = Depends(get_db)):
    from google.oauth2 import id_token as google_id_token
    from ..config import settings
    if not settings.google_client_id:
        raise HTTPException(status_code=500, detail="GOOGLE_CLIENT_ID non configuré sur le serveur")
    try:
        info = google_id_token.verify_oauth2_token(
            req.id_token,
            _HttpxRequest(),
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
