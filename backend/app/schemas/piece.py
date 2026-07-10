from pydantic import BaseModel
from typing import Optional, Any
from datetime import datetime


class PieceCreate(BaseModel):
    display_number: str
    series_value: int
    reference_pinceaux_value: int
    color_primary: str
    color_secondary: Optional[str] = None
    color_signature: Optional[Any] = None
    texture_signature: Optional[Any] = None
    top_image: Optional[str] = None
    material_notes: Optional[str] = None
    artist_note: Optional[str] = None


class PieceResponse(BaseModel):
    id: str
    display_number: str
    series_value: int
    reference_pinceaux_value: int
    color_primary: str
    color_secondary: Optional[str] = None
    color_signature: Optional[Any] = None
    texture_signature: Optional[Any] = None
    top_image: Optional[str] = None
    material_notes: Optional[str] = None
    creation_date: datetime
    artist_note: Optional[str] = None
    current_owner_id: Optional[str] = None
    status: str
    photo_url: Optional[str] = None

    class Config:
        from_attributes = True


class PieceScanSubmit(BaseModel):
    piece_id: str
    capture_data: Any
    color_signature: Optional[Any] = None
    texture_signature: Optional[Any] = None
    top_image: Optional[str] = None
