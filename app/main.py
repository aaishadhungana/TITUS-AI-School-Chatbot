
# app/main.py — FastAPI Application Factory
# =============================================================================

from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.v1.router import api_router
from app.config import settings
from app.database import check_database_health


# =============================================================================
# LIFESPAN EVENTS
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """
    Runs once when the app starts, and once when it shuts down.
    Code before `yield` = startup. Code after `yield` = shutdown.
    """
    # ─── STARTUP ──────────────────────────────────────────────────────────────
    print(f"🚀 Starting {settings.app_name} v{settings.app_version}")
    print(f"   Environment: {settings.environment}")
    print(f"   Debug mode:  {settings.debug}")

    if not check_database_health():
        raise RuntimeError(
            "Database health check failed at startup. "
            "Verify DATABASE_URL and that PostgreSQL is running."
        )
    print("   Database:    ✅ connected")

    yield  

    # ─── SHUTDOWN ─────────────────────────────────────────────────────────────
    print(f"🛑 Shutting down {settings.app_name}")


# =============================================================================
# APPLICATION FACTORY
# =============================================================================
def create_app() -> FastAPI:
    """
    Builds and configures the FastAPI application instance.
    Call this once, at the module level below, to produce the `app` object
    that uvicorn serves.
    """
    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        description=(
            "Backend API for the TITUS AI School Chatbot. "
            "Provides authentication, student management, fees, attendance, "
            "homework, marks, complaints, and request handling."
        ),
        # In production, hide interactive docs to reduce attack surface.
        # Anyone with the URL can otherwise explore your entire API schema.
        docs_url="/docs" if not settings.is_production else None,
        redoc_url="/redoc" if not settings.is_production else None,
        openapi_url="/openapi.json" if not settings.is_production else None,
        lifespan=lifespan,
    )

    # =========================================================================
    # MIDDLEWARE
    # =========================================================================

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type"],
    )

    # =========================================================================
    # GLOBAL EXCEPTION HANDLERS
    # =========================================================================
    
    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        """
        Catches Pydantic validation errors (e.g., missing required field,
        wrong type) and returns a consistent, frontend-friendly format
        instead of FastAPI's default verbose error shape.

        """
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content=jsonable_encoder(
                {
                    "error": {
                        "code": "VALIDATION_ERROR",
                        "message": "Request validation failed.",
                        "details": exc.errors(),
                    }
                }
            ),
        )

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(
        request: Request, exc: Exception
    ) -> JSONResponse:
        """
        Catches anything that wasn't explicitly handled, the safety net.

        """
        if settings.debug:
            detail = str(exc)
        else:
            detail = "An unexpected error occurred. Please try again later."

        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={
                "error": {
                    "code": "INTERNAL_SERVER_ERROR",
                    "message": detail,
                }
            },
        )

    # =========================================================================
    # ROOT & HEALTH CHECK ENDPOINTS
    # =========================================================================
    #
    @app.get("/", tags=["Root"])
    async def root() -> dict[str, str]:
        """Basic liveness indicator — confirms the API process is running."""
        return {
            "service": settings.app_name,
            "version": settings.app_version,
            "status": "running",
        }

    @app.get("/health", tags=["Root"])
    async def health_check() -> JSONResponse:
        """
        Readiness check — confirms the API AND its database dependency
        are both healthy. Returns 503 if the database is unreachable so
        load balancers stop routing traffic to this instance.
        """
        db_healthy = check_database_health()
        status_code = (
            status.HTTP_200_OK if db_healthy else status.HTTP_503_SERVICE_UNAVAILABLE
        )
        return JSONResponse(
            status_code=status_code,
            content={
                "status": "healthy" if db_healthy else "unhealthy",
                "database": "connected" if db_healthy else "disconnected",
            },
        )

    # =========================================================================
    # ROUTERS
    # =========================================================================
    #
    app.include_router(api_router, prefix=settings.api_v1_prefix)

    return app


# =============================================================================
# MODULE-LEVEL APP INSTANCE
# =============================================================================
#
app = create_app()
