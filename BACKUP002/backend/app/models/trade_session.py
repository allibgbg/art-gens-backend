import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, Enum, ForeignKey
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class DeltaDirection(str, enum.Enum):
    a_to_b = "a_to_b"
    b_to_a = "b_to_a"
    none = "none"


class TradeStatus(str, enum.Enum):
    pending = "pending"
    scanned_a = "scanned_a"
    scanned_b = "scanned_b"
    confirmed_a = "confirmed_a"
    confirmed_b = "confirmed_b"
    completed = "completed"
    cancelled = "cancelled"


class TradeSession(Base):
    __tablename__ = "trade_sessions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    appointment_id = Column(String(36), ForeignKey("appointments.id"), nullable=True)
    participant_a_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    participant_b_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    piece_a_id = Column(String(36), ForeignKey("pieces.id"), nullable=True)
    piece_b_id = Column(String(36), ForeignKey("pieces.id"), nullable=True)
    delta_pinceaux = Column(Integer, default=0)
    delta_direction = Column(Enum(DeltaDirection), default=DeltaDirection.none)
    status = Column(Enum(TradeStatus), default=TradeStatus.pending)
    created_at = Column(DateTime, default=datetime.utcnow)
    completed_at = Column(DateTime, nullable=True)

    scan_events = relationship("ScanEvent", back_populates="trade_session")
