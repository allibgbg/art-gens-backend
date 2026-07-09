import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, Float, Boolean, DateTime, Enum
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class AuthProvider(str, enum.Enum):
    google = "google"
    facebook = "facebook"


class User(Base):
    __tablename__ = "users"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    auth_provider = Column(Enum(AuthProvider), nullable=False)
    auth_provider_id = Column(String(255), nullable=False)
    pseudo = Column(String(50), unique=True, nullable=False)
    email = Column(String(255), nullable=True)
    avatar_url = Column(String(500), nullable=True)
    pinceaux_balance = Column(Integer, default=0)
    reputation_score = Column(Float, default=1.0)
    onboarding_completed = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)

    owned_pieces = relationship("Piece", back_populates="current_owner")
    scan_events = relationship("ScanEvent", back_populates="user")
    offers_made = relationship("Offer", foreign_keys="Offer.from_user_id", back_populates="from_user")
    offers_received = relationship("Offer", foreign_keys="Offer.to_user_id", back_populates="to_user")
    transactions = relationship("PinceauxTransaction", back_populates="user")
