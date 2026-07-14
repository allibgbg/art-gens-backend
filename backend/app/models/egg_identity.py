import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, Text, JSON
from ..database import Base


class EggIdentity(Base):
    __tablename__ = "egg_identities"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    display_number = Column(String(32), nullable=False)
    series_value = Column(Integer, nullable=False)
    reference_pinceaux_value = Column(Integer, nullable=False, default=0)
    digit_number = Column(String(16), nullable=True)
    notes = Column(Text, nullable=True)
    face_photo = Column(Text, nullable=True)  # base64 JPEG
    identity_data = Column(JSON, nullable=False)  # {version, image_w, image_h, quality, points: [...]}
    current_owner_id = Column(String(36), nullable=True)  # user id du propriétaire
    created_at = Column(DateTime, default=datetime.utcnow)
    created_by = Column(String(36), nullable=True)  # user id
