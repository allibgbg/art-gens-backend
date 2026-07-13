from pydantic import BaseModel
from typing import Optional
from datetime import datetime


class OfferCreate(BaseModel):
    target_piece_id: str
    offered_piece_id: str
    offered_pinceaux: int = 0


class OfferResponse(BaseModel):
    id: str
    from_user_id: str
    to_user_id: str
    target_piece_id: str
    offered_piece_id: str
    offered_pinceaux: int
    status: str
    created_at: datetime

    class Config:
        from_attributes = True


class OfferAction(BaseModel):
    action: str  # accept / decline


class AppointmentCreate(BaseModel):
    offer_id: str
    location: str
    scheduled_at: datetime
