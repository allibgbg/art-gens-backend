"""Réception des erreurs client (app mobile) côté backend.

L'app Flutter envoie ses erreurs (attrapées ou non) en POST /logs.
On les conserve de deux façons :
  1. dans un fichier JSONL `client_errors/client_errors.jsonl` (le "dossier
     d'erreurs" voulu par l'utilisateur — persistant tant que l'instance tourne) ;
  2. dans les logs serveur via logging (marqueur `CLIENT_ERROR`), ce qui finit
     dans les logs Render et reste consultable même après redémarrage.

Un GET /logs renvoie les N dernières entrées (utile pour un export rapide).
"""
import os
import json
import threading
import logging
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from fastapi import APIRouter, Request
from pydantic import BaseModel

logger = logging.getLogger("client_errors")

_LOGS_DIR = os.environ.get("CLIENT_ERRORS_DIR", "client_errors")
os.makedirs(_LOGS_DIR, exist_ok=True)
_LOG_FILE = os.path.join(_LOGS_DIR, "client_errors.jsonl")
_lock = threading.Lock()

router = APIRouter(prefix="/logs", tags=["logs"])


class ClientErrorReport(BaseModel):
    level: str = "error"
    source: Optional[str] = None
    message: str
    stack: Optional[str] = None
    device: Optional[Dict[str, Any]] = None
    app_version: Optional[str] = None
    user_id: Optional[str] = None
    ts: Optional[str] = None


def _persist(entry: dict) -> None:
    line = json.dumps(entry, ensure_ascii=False)
    # 1) fichier "dossier d'erreurs"
    try:
        with _lock:
            with open(_LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
    except Exception:
        pass
    # 2) log serveur (consultable via l'API logs Render -> marqueur CLIENT_ERROR)
    logger.error("CLIENT_ERROR %s", line)


@router.post("")
def post_error(report: ClientErrorReport, request: Request):
    entry = {
        "level": report.level,
        "source": report.source,
        "message": report.message,
        "stack": report.stack,
        "device": report.device,
        "app_version": report.app_version,
        "user_id": report.user_id,
        "ts": report.ts,
        "received_at": datetime.now(timezone.utc).isoformat(),
        "client_ip": request.client.host if request.client else None,
    }
    # garde-fou anti-abus : borne la taille du message
    if len(entry.get("message") or "") > 8000:
        entry["message"] = entry["message"][:8000]
    _persist(entry)
    return {"ok": True}


@router.get("")
def get_errors(limit: int = 100):
    limit = max(1, min(int(limit), 500))
    try:
        with _lock:
            with open(_LOG_FILE, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
    except FileNotFoundError:
        return []
    out = []
    for ln in lines[-limit:]:
        try:
            out.append(json.loads(ln))
        except Exception:
            continue
    return out
