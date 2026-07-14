import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime
from ..database import Base


class EggOffer(Base):
    __tablename__ = "egg_offers"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    from_user_id = Column(String(36), nullable=False, index=True)
    to_user_id = Column(String(36), nullable=False, index=True)
    target_egg_id = Column(String(36), nullable=False)
    offered_egg_id = Column(String(36), nullable=False)
    offered_pinceaux = Column(Integer, default=0)
    status = Column(String(16), default="pending")  # pending, accepted, declined
    created_at = Column(DateTime, default=datetime.utcnow)
    responded_at = Column(DateTime, nullable=True)
