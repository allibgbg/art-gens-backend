import traceback
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .database import engine, Base, SessionLocal
from .models.user import User
from .models.piece import Piece
from .models.scan_event import ScanEvent
from .models.provenance_event import ProvenanceEvent
from .models.offer import Offer
from .models.appointment import Appointment
from .models.trade_session import TradeSession
from .models.pinceaux_transaction import PinceauxTransaction
from .routers import auth, users, pieces, offers, trades, scan
from .websocket.trade_handler import router as ws_router

Base.metadata.create_all(bind=engine)

# Migration manuelle : ajout de la colonne top_image si elle n'existe pas
from sqlalchemy import inspect, text
inspector = inspect(engine)
if "pieces" in inspector.get_table_names():
    columns = {c["name"] for c in inspector.get_columns("pieces")}
    if "top_image" not in columns:
        with engine.connect() as conn:
            conn.execute(text("ALTER TABLE pieces ADD COLUMN top_image TEXT"))
            conn.commit()

app = FastAPI(
    title="Art-gens API",
    description="Backend du projet Art-gens — échange d'objets d'art avec monnaie interne",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(users.router)
app.include_router(pieces.router)
app.include_router(offers.router)
app.include_router(trades.router)
app.include_router(scan.router)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    tb = traceback.format_exc()
    return JSONResponse(
        status_code=500,
        content={
            "error": type(exc).__name__,
            "detail": str(exc),
            "traceback": tb.split("\n"),
        },
    )

@app.get("/health")
def health():
    return {"status": "ok", "project": "Art-gens"}
