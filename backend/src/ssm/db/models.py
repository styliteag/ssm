"""SQLAlchemy 2.0 models mirroring the Rust backend's Diesel schema.

Schema parity notes:
- Table names (``host``, ``user``, ``authorization``, ``user_key``, ``activity_log``)
  are the same as the Rust schema so a one-shot data copy works row-for-row.
- Boolean columns map to SQLite ``INTEGER`` (0/1) via SQLAlchemy's ``Boolean``.
- ``activity_log.timestamp`` defaults to the current unix epoch server-side.
"""

from __future__ import annotations

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ssm.db.base import Base


class Host(Base):
    __tablename__ = "host"
    __table_args__ = (UniqueConstraint("address", "port", name="unique_address_port"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    username: Mapped[str] = mapped_column(Text, nullable=False)
    address: Mapped[str] = mapped_column(Text, nullable=False)
    port: Mapped[int] = mapped_column(Integer, nullable=False)
    key_fingerprint: Mapped[str | None] = mapped_column(Text)
    jump_via: Mapped[int | None] = mapped_column(Integer, ForeignKey("host.id", ondelete="CASCADE"))
    disabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    comment: Mapped[str | None] = mapped_column(Text)

    jump_host: Mapped[Host | None] = relationship(
        "Host", remote_side="Host.id", foreign_keys=[jump_via]
    )


class User(Base):
    __tablename__ = "user"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    username: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    enabled: Mapped[bool] = mapped_column(
        Boolean,
        CheckConstraint("enabled IN (0, 1)", name="user_enabled_bool"),
        nullable=False,
        default=True,
    )
    comment: Mapped[str | None] = mapped_column(Text)


class Authorization(Base):
    __tablename__ = "authorization"
    __table_args__ = (
        UniqueConstraint("user_id", "host_id", "login", name="unique_user_host_login"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    host_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("host.id", ondelete="CASCADE"), nullable=False
    )
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("user.id", ondelete="CASCADE"), nullable=False
    )
    login: Mapped[str] = mapped_column(Text, nullable=False)
    options: Mapped[str | None] = mapped_column(Text)
    comment: Mapped[str | None] = mapped_column(Text)


class UserKey(Base):
    __tablename__ = "user_key"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    key_type: Mapped[str] = mapped_column(Text, nullable=False)
    key_base64: Mapped[str] = mapped_column(Text, unique=True, nullable=False)
    name: Mapped[str | None] = mapped_column(Text)
    extra_comment: Mapped[str | None] = mapped_column(Text)
    user_id: Mapped[int] = mapped_column(
        Integer, ForeignKey("user.id", ondelete="CASCADE"), nullable=False
    )


class ActivityLog(Base):
    __tablename__ = "activity_log"
    __table_args__ = (
        CheckConstraint(
            "activity_type IN ('key', 'host', 'user', 'auth')",
            name="activity_log_type_check",
        ),
        Index("idx_activity_log_timestamp", "timestamp"),
        Index("idx_activity_log_type", "activity_type"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    activity_type: Mapped[str] = mapped_column(String, nullable=False)
    action: Mapped[str] = mapped_column(Text, nullable=False)
    target: Mapped[str] = mapped_column(Text, nullable=False)
    user_id: Mapped[int | None] = mapped_column(Integer, ForeignKey("user.id", ondelete="SET NULL"))
    actor_username: Mapped[str] = mapped_column(Text, nullable=False)
    timestamp: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        server_default=func.strftime("%s", "now"),
    )
    meta: Mapped[str | None] = mapped_column("metadata", Text)
