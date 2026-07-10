from sqlalchemy.orm import Session
from fastapi import HTTPException
from ..models.trade_session import TradeSession, TradeStatus, DeltaDirection
from ..models.piece import Piece
from ..models.scan_event import ScanEvent, ScanType
from ..models.provenance_event import ProvenanceEvent, EventType
from ..models.pinceaux_transaction import PinceauxTransaction, TransactionType
from ..models.user import User


class TradeService:
    @staticmethod
    def create_session(db: Session, participant_a_id: str, participant_b_id: str) -> TradeSession:
        session = TradeSession(
            participant_a_id=participant_a_id,
            participant_b_id=participant_b_id,
        )
        db.add(session)
        db.commit()
        db.refresh(session)
        return session

    @staticmethod
    def get_session(db: Session, session_id: str) -> TradeSession:
        session = db.query(TradeSession).filter(TradeSession.id == session_id).first()
        if not session:
            raise HTTPException(status_code=404, detail="Session introuvable")
        return session

    @staticmethod
    def scan_piece(db: Session, session_id: str, piece_id: str, user_id: str, capture_data: dict, color_signature: dict) -> TradeSession:
        session = TradeService.get_session(db, session_id)
        piece = db.query(Piece).filter(Piece.id == piece_id).first()
        if not piece:
            raise HTTPException(status_code=404, detail="Pièce introuvable")

        if user_id == session.participant_a_id:
            session.piece_a_id = piece_id
            session.status = TradeStatus.scanned_a
        elif user_id == session.participant_b_id:
            session.piece_b_id = piece_id
            session.status = TradeStatus.scanned_b
        else:
            raise HTTPException(status_code=403, detail="Vous ne participez pas à cette session")

        if session.piece_a_id and session.piece_b_id:
            session.status = TradeStatus.confirmed_a if session.status == TradeStatus.scanned_a else TradeStatus.confirmed_b

        scan = ScanEvent(
            piece_id=piece_id,
            user_id=user_id,
            scan_type=ScanType.trade_verification,
            trade_session_id=session_id,
            capture_data=capture_data,
            color_signature=color_signature,
            authenticity_match=True,
        )
        db.add(scan)
        db.commit()
        db.refresh(session)
        return session

    @staticmethod
    def update_delta(db: Session, session_id: str, delta_pinceaux: int, delta_direction: str) -> TradeSession:
        session = TradeService.get_session(db, session_id)
        session.delta_pinceaux = delta_pinceaux
        session.delta_direction = delta_direction
        session.status = TradeStatus.pending
        db.commit()
        db.refresh(session)
        return session

    @staticmethod
    def confirm(db: Session, session_id: str, user_id: str) -> TradeSession:
        session = TradeService.get_session(db, session_id)

        if user_id == session.participant_a_id:
            session.status = TradeStatus.confirmed_a
        elif user_id == session.participant_b_id:
            session.status = TradeStatus.confirmed_b
        else:
            raise HTTPException(status_code=403, detail="Vous ne participez pas à cette session")

        if session.status in (TradeStatus.confirmed_a, TradeStatus.confirmed_b):
            other_status = TradeStatus.confirmed_b if session.status == TradeStatus.confirmed_a else TradeStatus.confirmed_a
            if db.query(TradeSession).filter(TradeSession.id == session_id).first().status == other_status:
                session.status = TradeStatus.completed
                session.completed_at = datetime.utcnow()
                TradeService._finalize_trade(db, session)

        db.commit()
        db.refresh(session)
        return session

    @staticmethod
    def _finalize_trade(db: Session, session: TradeSession):
        piece_a = db.query(Piece).filter(Piece.id == session.piece_a_id).first()
        piece_b = db.query(Piece).filter(Piece.id == session.piece_b_id).first()
        user_a = db.query(User).filter(User.id == session.participant_a_id).first()
        user_b = db.query(User).filter(User.id == session.participant_b_id).first()

        old_owner_a = piece_a.current_owner_id
        old_owner_b = piece_b.current_owner_id

        piece_a.current_owner_id = session.participant_b_id
        piece_b.current_owner_id = session.participant_a_id

        prov_a = ProvenanceEvent(
            piece_id=piece_a.id,
            from_user_id=old_owner_a,
            to_user_id=session.participant_b_id,
            event_type=EventType.trade,
            trade_session_id=session.id,
        )
        prov_b = ProvenanceEvent(
            piece_id=piece_b.id,
            from_user_id=old_owner_b,
            to_user_id=session.participant_a_id,
            event_type=EventType.trade,
            trade_session_id=session.id,
        )
        db.add(prov_a)
        db.add(prov_b)

        if session.delta_direction == DeltaDirection.a_to_b and session.delta_pinceaux > 0:
            user_a.pinceaux_balance -= session.delta_pinceaux
            user_b.pinceaux_balance += session.delta_pinceaux
            tx = PinceauxTransaction(
                user_id=user_a.id,
                amount=-session.delta_pinceaux,
                type=TransactionType.delta_echange,
                related_trade_session_id=session.id,
            )
            tx2 = PinceauxTransaction(
                user_id=user_b.id,
                amount=session.delta_pinceaux,
                type=TransactionType.delta_echange,
                related_trade_session_id=session.id,
            )
            db.add(tx)
            db.add(tx2)
        elif session.delta_direction == DeltaDirection.b_to_a and session.delta_pinceaux > 0:
            user_b.pinceaux_balance -= session.delta_pinceaux
            user_a.pinceaux_balance += session.delta_pinceaux
            tx = PinceauxTransaction(
                user_id=user_b.id,
                amount=-session.delta_pinceaux,
                type=TransactionType.delta_echange,
                related_trade_session_id=session.id,
            )
            tx2 = PinceauxTransaction(
                user_id=user_a.id,
                amount=session.delta_pinceaux,
                type=TransactionType.delta_echange,
                related_trade_session_id=session.id,
            )
            db.add(tx)
            db.add(tx2)
