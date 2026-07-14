import uuid
from datetime import datetime
from sqlalchemy import Column, String, DateTime, Boolean, Text
from ..database import Base


class Notification(Base):
    __tablename__ = "notifications"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), nullable=False, index=True)
    type = Column(String(32), nullable=False)  # egg_offer_received, egg_offer_accepted, egg_offer_declined, message_received
    egg_offer_id = Column(String(36), nullable=True)
    content = Column(Text, nullable=True)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
