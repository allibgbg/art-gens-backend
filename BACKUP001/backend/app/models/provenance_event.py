import uuid
from datetime import datetime
from sqlalchemy import Column, String, DateTime, Enum, ForeignKey
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class EventType(str, enum.Enum):
    don_initial = "don_initial"
    trade = "trade"


class ProvenanceEvent(Base):
    __tablename__ = "provenance_events"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    piece_id = Column(String(36), ForeignKey("pieces.id"), nullable=False)
    from_user_id = Column(String(36), ForeignKey("users.id"), nullable=True)
    to_user_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    event_type = Column(Enum(EventType), nullable=False)
    trade_session_id = Column(String(36), ForeignKey("trade_sessions.id"), nullable=True)
    timestamp = Column(DateTime, default=datetime.utcnow)

    piece = relationship("Piece", back_populates="provenance_events")
