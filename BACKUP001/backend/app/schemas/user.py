from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from uuid import uuid4


class UserCreate(BaseModel):
    auth_provider: str
    auth_provider_id: str
    email: Optional[str] = None
    pseudo: str


class UserResponse(BaseModel):
    id: str
    pseudo: str
    email: Optional[str] = None
    avatar_url: Optional[str] = None
    pinceaux_balance: int = 0
    reputation_score: float = 1.0
    onboarding_completed: bool = False
    created_at: datetime

    class Config:
        from_attributes = True


class UserUpdatePseudo(BaseModel):
    pseudo: str = Field(min_length=2, max_length=50)


class UserUpdateOnboarding(BaseModel):
    onboarding_completed: bool = True
