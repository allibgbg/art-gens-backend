import uuid
from datetime import datetime
from sqlalchemy import Column, String, DateTime, Text
from ..database import Base


class TradeMessage(Base):
    __tablename__ = "trade_messages"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    egg_offer_id = Column(String(36), nullable=False, index=True)
    sender_id = Column(String(36), nullable=False)
    content = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)
