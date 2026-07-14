import uuid
from datetime import datetime
from sqlalchemy import Column, String, DateTime, Enum, ForeignKey
from sqlalchemy import Text
from ..database import Base
import enum


class AppointmentStatus(str, enum.Enum):
    proposed = "proposed"
    confirmed = "confirmed"
    completed = "completed"
    cancelled = "cancelled"
    missed = "missed"


class Appointment(Base):
    __tablename__ = "appointments"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    offer_id = Column(String(36), ForeignKey("offers.id"), nullable=False)
    location = Column(Text, nullable=True)
    scheduled_at = Column(DateTime, nullable=False)
    status = Column(Enum(AppointmentStatus), default=AppointmentStatus.proposed)
    created_at = Column(DateTime, default=datetime.utcnow)
