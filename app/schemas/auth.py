from pydantic import BaseModel


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str


class GoogleAuthRequest(BaseModel):
    id_token: str


class FacebookAuthRequest(BaseModel):
    access_token: str
    user_id: str
