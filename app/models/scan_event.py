import uuid
from datetime import datetime
from sqlalchemy import Column, String, DateTime, Enum, ForeignKey, JSON, Boolean
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class ScanType(str, enum.Enum):
    enregistrement = "enregistrement"
    premiere_acquisition = "premiere_acquisition"
    trade_verification = "trade_verification"


class ScanEvent(Base):
    __tablename__ = "scan_events"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    piece_id = Column(String(36), ForeignKey("pieces.id"), nullable=False)
    user_id = Column(String(36), ForeignKey("users.id"), nullable=True)
    scan_type = Column(Enum(ScanType), nullable=False)
    trade_session_id = Column(String(36), ForeignKey("trade_sessions.id"), nullable=True)
    capture_data = Column(JSON, nullable=True)
    color_signature = Column(JSON, nullable=True)
    authenticity_match = Column(Boolean, nullable=True)
    timestamp = Column(DateTime, default=datetime.utcnow)

    piece = relationship("Piece", back_populates="scan_events")
    user = relationship("User", back_populates="scan_events")
