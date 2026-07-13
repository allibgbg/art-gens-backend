import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, Enum, ForeignKey
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class TransactionType(str, enum.Enum):
    achat = "achat"
    delta_echange = "delta_echange"
    bonus_inscription = "bonus_inscription"


class PinceauxTransaction(Base):
    __tablename__ = "pinceaux_transactions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    amount = Column(Integer, nullable=False)
    type = Column(Enum(TransactionType), nullable=False)
    related_trade_session_id = Column(String(36), ForeignKey("trade_sessions.id"), nullable=True)
    timestamp = Column(DateTime, default=datetime.utcnow)

    user = relationship("User", back_populates="transactions")
