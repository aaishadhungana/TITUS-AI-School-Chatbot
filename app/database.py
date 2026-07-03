
# app/database.py — Database Engine, Session Factory, and Declarative Base

# =============================================================================
# ARCHITECTURE DECISIONS:
#
# 1. ONE ENGINE: SQLAlchemy's create_engine() manages a connection pool.
#    Creating multiple engines = multiple pools = wasted connections.
#    We create it once here and import it everywhere.
#
# 2. ONE BASE: DeclarativeBase is the parent class all ORM models inherit.
#    Having one shared Base means Alembic can discover ALL models in one
#    place and generate migrations automatically.
#
# 3. SESSION FACTORY vs SESSION INSTANCE:
#    SessionLocal is a *factory* (a class). Calling SessionLocal() creates
#    a new session. The factory is created once; sessions are created per
#    request and closed when the request ends.
#
# 4. NO AUTOCOMMIT: We manually control transactions. This means if a
#    request fails halfway through, the entire transaction rolls back.
#    autocommit=True would commit each SQL statement immediately — very
#    dangerous for financial data like fees.
#
# =============================================================================

from collections.abc import Generator

from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import settings


# =============================================================================
# DATABASE ENGINE
# =============================================================================
#
# The engine is the core SQLAlchemy object. It manages:
#   - Connection pooling (reuse connections instead of open/close each time)
#   - SQL dialect (knows how to talk to PostgreSQL specifically)
#   - Connection string parsing
#
# CONNECTION POOL SETTINGS EXPLAINED:
#   pool_size=10       → Keep 10 connections open permanently
#   max_overflow=20    → Allow 20 MORE connections during traffic spikes
#                        Total max = pool_size + max_overflow = 30
#   pool_pre_ping=True → Before using a connection from the pool, send
#                        "SELECT 1" to verify it's alive. Prevents errors
#                        after PostgreSQL restarts or network blips.
#   pool_timeout=30    → If all connections are busy, wait 30s before
#                        raising a "connection pool exhausted" error.
#   pool_recycle=1800  → Force-recreate connections every 30 minutes.
#                        Prevents issues with database-side connection
#                        timeouts killing idle connections.
#
engine: Engine = create_engine(
    settings.database_url,
    pool_size=settings.db_pool_size,
    max_overflow=settings.db_max_overflow,
    pool_pre_ping=settings.db_pool_pre_ping,
    pool_timeout=30,
    pool_recycle=1800,
    # echo=True logs every SQL statement — useful for debugging, never in prod
    echo=settings.debug,
    # echo_pool=True logs connection pool events — too verbose, keep off
    echo_pool=False,
)


# =============================================================================
# SET POSTGRESQL-SPECIFIC OPTIONS
# =============================================================================
#
# We use SQLAlchemy events to run commands right after a connection is created.
# This ensures every connection in the pool uses these settings.
#
@event.listens_for(engine, "connect")
def set_pg_session_defaults(dbapi_connection: object, connection_record: object) -> None:
    """
    Run after every new database connection is established.

    timezone=UTC: Store all timestamps in UTC.
    CRITICAL: Never store timestamps in local time. When your server moves
    to a different timezone or daylight saving kicks in, local-time data
    becomes ambiguous and comparisons break.

    We always store UTC, always return UTC, and let the frontend convert
    to the user's local time for display.
    """
    # The type ignore is because dbapi_connection can be different types
    # depending on the DB driver — psycopg2 uses its own connection type
    cursor = dbapi_connection.cursor()  # type: ignore[attr-defined]
    cursor.execute("SET timezone='UTC'")
    cursor.close()


# =============================================================================
# SESSION FACTORY
# =============================================================================
#
# SessionLocal is a factory that produces database sessions.
#
# autocommit=False → We control when to commit (explicit is better than implicit)
# autoflush=False  → Don't automatically flush pending changes to DB before
#                    every query. We control flushing explicitly.
#                    This prevents surprising implicit SELECTs mid-request.
#
SessionLocal: sessionmaker[Session] = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine,
)


# =============================================================================
# DECLARATIVE BASE
# =============================================================================
#
# All SQLAlchemy ORM models inherit from this Base.
#
class Base(DeclarativeBase):
    """
    Shared declarative base for all ORM models.

    We configure a naming convention here so Alembic-generated migrations
    have predictable, consistent constraint names across all tables.
    This is critical for: ALTER TABLE, DROP CONSTRAINT operations in migrations.

    Without this, constraint names are auto-generated and differ between
    databases — causing migration failures when running on a fresh DB.
    """
    pass


# =============================================================================
# DATABASE DEPENDENCY (used in FastAPI routes via Depends())
# =============================================================================
#
# This generator function is a FastAPI "dependency". Here's how it works:
#
#   1. FastAPI calls get_db() for every request that uses it
#   2. A new Session is created from the SessionLocal factory
#   3. The session is yielded to the route handler (the `db` parameter)
#   4. The route handler runs (success or exception)
#   5. Code after `yield` ALWAYS runs (like a finally block)
#   6. Session is closed, connection returned to the pool
#
# The try/finally guarantees the session is ALWAYS closed, even if the
# route raises an exception. No leaked connections.
#
# Usage in a route:
#   @router.get("/items")
#   def get_items(db: Session = Depends(get_db)):
#       return db.query(Item).all()
#
def get_db() -> Generator[Session, None, None]:
    """
    FastAPI dependency that provides a database session per request.
    Session is automatically closed when the request finishes.
    """
    db = SessionLocal()
    try:
        yield db
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


# =============================================================================
# HEALTH CHECK UTILITY
# =============================================================================
#
# Used by the /health endpoint to verify DB connectivity.
# Returns True if we can successfully query the DB, False otherwise.
#
def check_database_health() -> bool:
    """
    Verify that the database is reachable and responding.
    Used by the /health endpoint for uptime monitoring.
    """
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return True
    except Exception:
        return False

