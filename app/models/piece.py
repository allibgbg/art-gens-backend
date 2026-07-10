import uuid
from datetime import datetime
from sqlalchemy import Column, String, Integer, DateTime, Enum, Text, ForeignKey, JSON
from sqlalchemy.orm import relationship
from ..database import Base
import enum


class PieceStatus(str, enum.Enum):
    non_distribue = "non_distribue"
    active = "active"
    lost = "lost"


class ColorEnum(str, enum.Enum):
    blanc = "blanc"
    gris = "gris"
    noir = "noir"
    jaune = "jaune"
    bleu = "bleu"
    vert = "vert"
    rouge = "rouge"
    magenta = "magenta"
    multicolore = "multicolore"


class Piece(Base):
    __tablename__ = "pieces"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    display_number = Column(String(10), unique=True, nullable=False)
    series_value = Column(Integer, nullable=False)
    reference_pinceaux_value = Column(Integer, nullable=False)
    color_primary = Column(Enum(ColorEnum), nullable=False)
    color_secondary = Column(Enum(ColorEnum), nullable=True)
    color_signature = Column(JSON, nullable=True)
    color_signature_history = Column(JSON, default=list)
    texture_signature = Column(JSON, nullable=True)
    top_image = Column(Text, nullable=True)
    material_notes = Column(Text, nullable=True)
    creation_date = Column(DateTime, default=datetime.utcnow)
    artist_note = Column(Text, nullable=True)
    current_owner_id = Column(String(36), ForeignKey("users.id"), nullable=True)
    status = Column(Enum(PieceStatus), default=PieceStatus.non_distribue)
    photo_url = Column(String(500), nullable=True)

    current_owner = relationship("User", back_populates="owned_pieces")
    scan_events = relationship("ScanEvent", back_populates="piece")
    provenance_events = relationship("ProvenanceEvent", back_populates="piece")
