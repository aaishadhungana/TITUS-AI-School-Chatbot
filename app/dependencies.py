
# app/dependencies.py — Shared FastAPI Dependencies
# =============================================================================
#
# This file holds CROSS-CUTTING dependencies used across multiple domains:
#   - Pagination parsing
#   - get_current_user — the auth dependency every protected route in 
#     every future module (Students, Fees, Attendance, ...) will use
#
# =============================================================================

import uuid
from dataclasses import dataclass

from fastapi import Depends, HTTPException, Query, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.config import settings
from app.core.security import InvalidTokenError, TokenType, decode_token
from app.database import get_db
from app.models.user import User
from app.repositories.user_repository import user_repository

# =============================================================================
# OAUTH2 SCHEME
# =============================================================================
#
# OAuth2PasswordBearer does two things for us:
#   1. It tells FastAPI/Swagger UI how to render the "Authorize" button
#      and where to send the username/password to obtain a token
#      (tokenUrl — purely for documentation/testing convenience in /docs).
#   2. At request time, it extracts the raw token string from the
#      `Authorization: Bearer <token>` header. If that header is missing
#      or malformed, FastAPI automatically returns 401 before our code
#      even runs.
#
# tokenUrl must match the actual login route path so Swagger's "Try it
# out" flow works correctly against our real /auth/login endpoint.
#
oauth2_scheme = OAuth2PasswordBearer(tokenUrl=f"{settings.api_v1_prefix}/auth/login")


def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    """
    The core auth dependency. Add `current_user: User = Depends(get_current_user)`
    to ANY route to require a valid access token and get the authenticated
    User object injected directly — no manual token parsing in route code.

    FLOW:
      1. oauth2_scheme already extracted the raw token string from the
         Authorization header (or raised 401 if missing).
      2. We decode it, requiring it to be an ACCESS token specifically
         (a refresh token submitted here is correctly rejected).
      3. We re-fetch the user from the database — same reasoning as in
         AuthService.refresh_access_token: never trust a stale claim for
         active/inactive status across the token's lifetime.

    WHY RAISE HTTPException HERE BUT DomainError IN THE SERVICE LAYER?
    This function IS the API layer (a FastAPI dependency), not the service
    layer — it's the correct place for HTTPException, exactly mirroring
    how route handlers themselves are allowed to know about HTTP.
    """
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        payload = decode_token(token, expected_type=TokenType.ACCESS)
    except InvalidTokenError as exc:
        raise credentials_exception from exc

    try:
        user_id = uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise credentials_exception from exc

    user = user_repository.get_by_id_any(db, user_id)
    if user is None:
        raise credentials_exception

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This account has been deactivated",
        )

    return user


# =============================================================================
# PAGINATION DEPENDENCY
# =============================================================================
#
# Every list endpoint (students, fees, attendance, etc.) needs pagination.
# Instead of repeating `page: int = Query(1)` `page_size: int = Query(20)`
# in every single route, we define it once and inject it everywhere.
#
@dataclass
class PaginationParams:
    """
    Standard pagination parameters used across all list endpoints.

    Usage in a route:
        @router.get("/students")
        def list_students(pagination: PaginationParams = Depends(get_pagination_params)):
            offset = pagination.offset
            limit = pagination.limit
    """
    page: int
    page_size: int

    @property
    def offset(self) -> int:
        """Convert page number to SQL OFFSET value."""
        return (self.page - 1) * self.page_size

    @property
    def limit(self) -> int:
        """Convert page_size to SQL LIMIT value."""
        return self.page_size


def get_pagination_params(
    page: int = Query(default=1, ge=1, description="Page number, starting at 1"),
    page_size: int = Query(
        default=20, ge=1, le=100, description="Items per page (max 100)"
    ),
) -> PaginationParams:
    """
    FastAPI dependency that parses and validates pagination query params.

    WHY le=100 (max page_size)?
    Without an upper bound, a client (or attacker) could request
    page_size=1000000 and force the DB to load an enormous result set into
    memory, potentially causing an outage. Capping at 100 protects the server.
    """
    return PaginationParams(page=page, page_size=page_size)
