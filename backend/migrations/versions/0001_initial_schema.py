"""Initial schema: host, user, authorization, user_key, activity_log.

Mirrors the Rust backend's Diesel migrations 1:1 so a one-shot data copy
from the old SQLite database lands without transformation.

Revision ID: 0001
Revises:
Create Date: 2026-04-14
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision: str | None = None
branch_labels: str | None = None
depends_on: str | None = None


def upgrade() -> None:
    op.create_table(
        "host",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("username", sa.Text(), nullable=False),
        sa.Column("address", sa.Text(), nullable=False),
        sa.Column("port", sa.Integer(), nullable=False),
        sa.Column("key_fingerprint", sa.Text(), nullable=True),
        sa.Column("jump_via", sa.Integer(), nullable=True),
        sa.Column("disabled", sa.Boolean(), nullable=False, server_default=sa.text("0")),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.UniqueConstraint("name", name="uq_host_name"),
        sa.UniqueConstraint("address", "port", name="unique_address_port"),
        sa.ForeignKeyConstraint(
            ["jump_via"], ["host.id"], ondelete="CASCADE", name="fk_host_jump_via"
        ),
    )

    op.create_table(
        "user",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("username", sa.Text(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.text("1")),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.UniqueConstraint("username", name="uq_user_username"),
        sa.CheckConstraint("enabled IN (0, 1)", name="user_enabled_bool"),
    )

    op.create_table(
        "authorization",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("host_id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("login", sa.Text(), nullable=False),
        sa.Column("options", sa.Text(), nullable=True),
        sa.Column("comment", sa.Text(), nullable=True),
        sa.UniqueConstraint("user_id", "host_id", "login", name="unique_user_host_login"),
        sa.ForeignKeyConstraint(
            ["host_id"],
            ["host.id"],
            ondelete="CASCADE",
            name="fk_authorization_host_id",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["user.id"],
            ondelete="CASCADE",
            name="fk_authorization_user_id",
        ),
    )

    op.create_table(
        "user_key",
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("key_type", sa.Text(), nullable=False),
        sa.Column("key_base64", sa.Text(), nullable=False),
        sa.Column("name", sa.Text(), nullable=True),
        sa.Column("extra_comment", sa.Text(), nullable=True),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.UniqueConstraint("key_base64", name="uq_user_key_key_base64"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["user.id"], ondelete="CASCADE", name="fk_user_key_user_id"
        ),
    )

    op.create_table(
        "activity_log",
        sa.Column(
            "id",
            sa.Integer(),
            primary_key=True,
            autoincrement=True,
            nullable=False,
        ),
        sa.Column("activity_type", sa.String(), nullable=False),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column("target", sa.Text(), nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=True),
        sa.Column("actor_username", sa.Text(), nullable=False),
        sa.Column(
            "timestamp",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("(strftime('%s', 'now'))"),
        ),
        sa.Column("metadata", sa.Text(), nullable=True),
        sa.CheckConstraint(
            "activity_type IN ('key', 'host', 'user', 'auth')",
            name="activity_log_type_check",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["user.id"],
            ondelete="SET NULL",
            name="fk_activity_log_user_id",
        ),
    )
    op.create_index("idx_activity_log_timestamp", "activity_log", ["timestamp"])
    op.create_index("idx_activity_log_type", "activity_log", ["activity_type"])


def downgrade() -> None:
    op.drop_index("idx_activity_log_type", table_name="activity_log")
    op.drop_index("idx_activity_log_timestamp", table_name="activity_log")
    op.drop_table("activity_log")
    op.drop_table("user_key")
    op.drop_table("authorization")
    op.drop_table("user")
    op.drop_table("host")
