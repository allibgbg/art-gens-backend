from datetime import datetime, timedelta
from typing import Optional
from jose import JWTError, jwt
from passlib.context import CryptContext
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from ..config import settings
from ..database import get_db
from ..models.user import User

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer()


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=settings.access_token_expire_minutes))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.secret_key, algorithm=settings.algorithm)


def verify_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        return payload
    except JWTError:
        return None


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db),
) -> User:
    payload = verify_token(credentials.credentials)
    if payload is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token invalide")
    user_id = payload.get("sub")
    user = db.query(User).filter(User.id == user_id).first()
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Utilisateur introuvable")
    return user


def get_or_create_user(db: Session, auth_provider: str, auth_provider_id: str, email: Optional[str] = None, pseudo: Optional[str] = None) -> User:
    user = db.query(User).filter(
        User.auth_provider == auth_provider,
        User.auth_provider_id == auth_provider_id,
    ).first()
    if user:
        return user

    if not pseudo:
        pseudo = f"user_{auth_provider_id[-6:]}"

    base_pseudo = pseudo
    counter = 1
    while db.query(User).filter(User.pseudo == pseudo).first():
        pseudo = f"{base_pseudo}{counter}"
        counter += 1

    user = User(
        auth_provider=auth_provider,
        auth_provider_id=auth_provider_id,
        pseudo=pseudo,
        email=email,
        pinceaux_balance=100,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user
