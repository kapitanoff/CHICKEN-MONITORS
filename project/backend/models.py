from sqlalchemy import Column, String, Float, DateTime, Integer, ForeignKey, Index
from datetime import datetime, timezone
from database import Base


def _utcnow():
    return datetime.now(timezone.utc)


class Group(Base):
    __tablename__ = "groups"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(100), nullable=False)


class Chicken(Base):
    __tablename__ = "chickens"

    chicken_id = Column(String(32), primary_key=True)
    last_temperature = Column(Float, nullable=True)
    voltage = Column(Float, nullable=True)
    last_seen = Column(DateTime, default=_utcnow)
    group_id = Column(Integer, ForeignKey("groups.id", ondelete="SET NULL"), nullable=True)


class TemperatureReading(Base):
    __tablename__ = "temperature_readings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    chicken_id = Column(String(32), ForeignKey("chickens.chicken_id", ondelete="CASCADE"), nullable=False)
    temperature = Column(Float, nullable=False)
    voltage = Column(Float, nullable=True)
    recorded_at = Column(DateTime, default=_utcnow)

    __table_args__ = (
        Index('ix_readings_chicken_time', 'chicken_id', 'recorded_at'),
    )
