import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, Enum, ForeignKey
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class OfferStatus(str, enum.Enum):
    pending = "pending"
    accepted = "accepted"
    declined = "declined"
    expired = "expired"


class Offer(Base):
    __tablename__ = "offers"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    from_user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    to_user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    target_piece_id = Column(String(36), ForeignKey("pieces.id"), nullable=False)
    offered_piece_id = Column(String(36), ForeignKey("pieces.id"), nullable=False)
    offered_pinceaux = Column(Integer, default=0)
    status = Column(Enum(OfferStatus), default=OfferStatus.pending)
    created_at = Column(DateTime, default=datetime.utcnow)

    from_user = relationship("User", foreign_keys=[from_user_id], back_populates="offers_made")
    to_user = relationship("User", foreign_keys=[to_user_id], back_populates="offers_received")
