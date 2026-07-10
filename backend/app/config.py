from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "sqlite:///./art_gens.db"
    secret_key: str = "change-me-in-production-abc123"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 1440
    google_client_id: str = ""
    google_client_secret: str = ""
    facebook_client_id: str = ""
    facebook_client_secret: str = ""
    artist_email: str = ""

    class Config:
        env_file = ".env"


settings = Settings()
