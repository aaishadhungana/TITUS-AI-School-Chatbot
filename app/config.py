# app/config.py — Application Configuration

from functools import lru_cache
from typing import Literal

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    All application settings loaded from environment variables / .env file.

    Priority order (highest to lowest):
      1. Actual environment variables (set in shell or Docker)
      2. Values in .env file
      3. Default values defined here

    This means production can override .env by setting real env vars,
    which is the correct behavior for containerized deployments.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ─── Application ─────────────────────────────────────────────────────────
    app_name: str = "TITUS AI School Chatbot API"
    app_version: str = "1.0.0"
    debug: bool = False
    environment: Literal["development", "staging", "production"] = "development"
    api_v1_prefix: str = "/api/v1"

    # ─── Database ─────────────────────────────────────────────────────────────
    # No default and if this is missing, the app should fail immediately
    database_url: str
    db_pool_size: int = 10
    db_max_overflow: int = 20
    db_pool_pre_ping: bool = True

    # ─── JWT Authentication ───────────────────────────────────────────────────
    # No default and must be set explicitly. Prevents running with an insecure key.
    secret_key: str
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_days: int = 7

    # ─── CORS ─────────────────────────────────────────────────────────────────
    # In .env: ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173
    allowed_origins: list[str] = ["http://localhost:3000"]

    # ─── Logging ──────────────────────────────────────────────────────────────
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    log_format: Literal["json", "text"] = "text"

    # ─── File Uploads ─────────────────────────────────────────────────────────
    max_upload_size_mb: int = 10
    upload_temp_dir: str = "./uploads/temp"

    # =========================================================================
    # VALIDATORS
    # These run at startup. If they fail, the app refuses to start.
    # =========================================================================

    @field_validator("secret_key")
    @classmethod
    def secret_key_must_be_strong(cls, v: str) -> str:
        """
        Enforce that the SECRET_KEY is at least 32 characters.
        A short key means JWTs are trivially brute-forceable.
        'openssl rand -hex 32' generates a 64-char key so use that.
        """
        if len(v) < 32:
            raise ValueError(
                "SECRET_KEY must be at least 32 characters long. "
                "Generate one with: openssl rand -hex 32"
            )
        return v

    @field_validator("database_url")
    @classmethod
    def database_url_must_be_postgres(cls, v: str) -> str:
        """
        We only support PostgreSQL. Prevent accidental SQLite usage
        """
        if not v.startswith(("postgresql://", "postgresql+psycopg2://")):
            raise ValueError(
                "DATABASE_URL must be a PostgreSQL URL. "
                "Format: postgresql://user:password@host:port/dbname"
            )
        return v

    @model_validator(mode="after")
    def validate_production_settings(self) -> "Settings":
        """
        Extra validation that only applies to production.
        In production, debug mode must be off.
        This prevents a developer accidentally deploying with DEBUG=True.
        """
        if self.environment == "production" and self.debug:
            raise ValueError(
                "DEBUG must be False in production. "
                "Set ENVIRONMENT=production only on your production server."
            )
        return self

    # =========================================================================
    # COMPUTED PROPERTIES
    # Derived values that don't need to be in .env
    # =========================================================================

    @property
    def access_token_expire_seconds(self) -> int:
        """Convenience: access token expiry in seconds (for cookie max-age)."""
        return self.access_token_expire_minutes * 60

    @property
    def is_development(self) -> bool:
        """Shorthand used in middleware and logging setup."""
        return self.environment == "development"

    @property
    def is_production(self) -> bool:
        """Shorthand used to enable production-only behaviors."""
        return self.environment == "production"

    @property
    def max_upload_size_bytes(self) -> int:
        """Convert MB to bytes for use in file size validation."""
        return self.max_upload_size_mb * 1024 * 1024


# =============================================================================
# SINGLETON PATTERN WITH lru_cache
# =============================================================================

@lru_cache()
def get_settings() -> Settings:
    """
    Returns the cached application settings singleton.
    Use this function everywhere — don't instantiate Settings() directly.
    """
    return Settings()  # type: ignore[call-arg]


# =============================================================================
# MODULE-LEVEL SINGLETON
# =============================================================================

settings = get_settings()
