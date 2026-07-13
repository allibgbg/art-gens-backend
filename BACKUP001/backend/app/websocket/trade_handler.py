from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy.orm import Session
from ..database import SessionLocal
from ..services.trade_service import TradeService
from ..services.auth_service import verify_token

router = APIRouter()


class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, dict[str, WebSocket]] = {}

    async def connect(self, trade_session_id: str, user_id: str, ws: WebSocket):
        await ws.accept()
        if trade_session_id not in self.active_connections:
            self.active_connections[trade_session_id] = {}
        self.active_connections[trade_session_id][user_id] = ws

    def disconnect(self, trade_session_id: str, user_id: str):
        if trade_session_id in self.active_connections:
            self.active_connections[trade_session_id].pop(user_id, None)
            if not self.active_connections[trade_session_id]:
                del self.active_connections[trade_session_id]

    async def broadcast(self, trade_session_id: str, message: dict, exclude_user_id: str = None):
        if trade_session_id not in self.active_connections:
            return
        for uid, ws in self.active_connections[trade_session_id].items():
            if uid != exclude_user_id:
                try:
                    await ws.send_json(message)
                except Exception:
                    pass


manager = ConnectionManager()


@router.websocket("/ws/trade/{trade_session_id}")
async def trade_websocket(ws: WebSocket, trade_session_id: str, token: str):
    payload = verify_token(token)
    if not payload:
        await ws.close(code=4001)
        return
    user_id = payload.get("sub")

    db = SessionLocal()
    try:
        session = TradeService.get_session(db, trade_session_id)
        if user_id not in (session.participant_a_id, session.participant_b_id):
            await ws.close(code=4003)
            return
    except Exception:
        await ws.close(code=4004)
        return
    finally:
        db.close()

    await manager.connect(trade_session_id, user_id, ws)
    await manager.broadcast(trade_session_id, {
        "type": "user_connected",
        "user_id": user_id,
    })

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type")

            if msg_type == "scan":
                await manager.broadcast(trade_session_id, {
                    "type": "scan_update",
                    "user_id": user_id,
                    "piece_id": data.get("piece_id"),
                }, exclude_user_id=user_id)

            elif msg_type == "delta":
                await manager.broadcast(trade_session_id, {
                    "type": "delta_update",
                    "user_id": user_id,
                    "delta_pinceaux": data.get("delta_pinceaux"),
                    "delta_direction": data.get("delta_direction"),
                }, exclude_user_id=user_id)

            elif msg_type == "confirm":
                await manager.broadcast(trade_session_id, {
                    "type": "confirm_update",
                    "user_id": user_id,
                }, exclude_user_id=user_id)

            elif msg_type == "chat":
                await manager.broadcast(trade_session_id, {
                    "type": "chat",
                    "user_id": user_id,
                    "message": data.get("message"),
                })

    except WebSocketDisconnect:
        manager.disconnect(trade_session_id, user_id)
        await manager.broadcast(trade_session_id, {
            "type": "user_disconnected",
            "user_id": user_id,
        })
