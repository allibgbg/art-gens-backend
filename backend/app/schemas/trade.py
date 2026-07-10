from pydantic import BaseModel
from typing import Optional, Any
from datetime import datetime


class TradeSessionResponse(BaseModel):
    id: str
    participant_a_id: str
    participant_b_id: str
    piece_a_id: Optional[str] = None
    piece_b_id: Optional[str] = None
    delta_pinceaux: int = 0
    delta_direction: str = "none"
    status: str
    created_at: datetime
    completed_at: Optional[datetime] = None

    class Config:
        from_attributes = True


class TradeScanUpdate(BaseModel):
    trade_session_id: str
    piece_id: str
    capture_data: Any
    color_signature: Any


class TradeDeltaUpdate(BaseModel):
    trade_session_id: str
    delta_pinceaux: int
    delta_direction: str


class TradeConfirm(BaseModel):
    trade_session_id: str
