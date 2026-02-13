"""
Configuration settings loaded from environment variables.
Uses pydantic-settings for validation and type safety.
Supports auto-detection of ODBC drivers across Windows 10/11.
"""

import winreg
from pathlib import Path
from typing import Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from loguru import logger


def detect_odbc_driver() -> str:
    """
    Auto-detect the best available ODBC driver for SQL Server.
    Checks for Driver 18 first, then 17, then 13.
    Returns the driver name or raises RuntimeError.
    """
    candidates = [
        "ODBC Driver 18 for SQL Server",
        "ODBC Driver 17 for SQL Server",
        "ODBC Driver 13 for SQL Server",
    ]

    try:
        # Read installed ODBC drivers from Windows Registry
        reg_path = r"SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers"
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, reg_path) as key:
            installed = []
            i = 0
            while True:
                try:
                    name, _, _ = winreg.EnumValue(key, i)
                    installed.append(name)
                    i += 1
                except OSError:
                    break

        for candidate in candidates:
            if candidate in installed:
                logger.info(f"ODBC Driver detected: {candidate}")
                return candidate

        logger.warning(f"No SQL Server ODBC driver found. Installed: {installed}")
        raise RuntimeError(
            "Nenhum driver ODBC do SQL Server encontrado.\n"
            "Instale o 'ODBC Driver 17 for SQL Server' ou '18'.\n"
            "Download: https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server"
        )

    except FileNotFoundError:
        raise RuntimeError(
            "Registro ODBC não encontrado. Nenhum driver ODBC instalado no sistema."
        )


class Settings(BaseSettings):
    """Application settings loaded from .env file."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # SQL Server
    sql_server_host: str = Field(default="localhost", alias="SQL_SERVER_HOST")
    sql_server_instance: str = Field(default="HIPER", alias="SQL_SERVER_INSTANCE")
    sql_database: str = Field(default="HiperPdv", alias="SQL_DATABASE")
    sql_database_gestao: str = Field(default="Hiper", alias="SQL_DATABASE_GESTAO")
    sql_username: Optional[str] = Field(default=None, alias="SQL_USERNAME")
    sql_password: Optional[str] = Field(default=None, alias="SQL_PASSWORD")
    sql_trusted_connection: bool = Field(default=False, alias="SQL_TRUSTED_CONNECTION")
    sql_driver: str = Field(default="auto", alias="SQL_DRIVER")

    # SQL Server encryption (Driver 18 defaults to Encrypt=yes, which breaks localhost)
    sql_encrypt: str = Field(default="no", alias="SQL_ENCRYPT")
    sql_trust_server_cert: str = Field(default="yes", alias="SQL_TRUST_SERVER_CERT")

    # Store
    store_id_ponto_venda: int = Field(default=10, alias="STORE_ID_PONTO_VENDA")
    store_alias: str = Field(default="Loja 01", alias="STORE_ALIAS")

    # API
    api_endpoint: str = Field(alias="API_ENDPOINT")
    api_token: str = Field(alias="API_TOKEN")
    request_timeout_seconds: int = Field(default=15, alias="REQUEST_TIMEOUT_SECONDS")

    # Sync
    sync_window_minutes: int = Field(default=10, alias="SYNC_WINDOW_MINUTES")

    # Paths (absolute paths for production, relative for dev)
    state_file: Path = Field(default=Path("./data/state.json"), alias="STATE_FILE")
    outbox_dir: Path = Field(default=Path("./data/outbox"), alias="OUTBOX_DIR")

    # Logging
    log_file: Path = Field(default=Path("./logs/agent.log"), alias="LOG_FILE")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")
    log_rotation: str = Field(default="10 MB", alias="LOG_ROTATION")
    log_retention: str = Field(default="30 days", alias="LOG_RETENTION")

    @field_validator("sql_username", "sql_password", mode="before")
    @classmethod
    def empty_str_to_none(cls, v: Optional[str]) -> Optional[str]:
        """Convert empty strings to None."""
        if v is None or v.strip() == "":
            return None
        return v

    @property
    def resolved_sql_driver(self) -> str:
        """Resolve 'auto' driver to an actual installed driver."""
        if self.sql_driver.lower() == "auto":
            return detect_odbc_driver()
        return self.sql_driver

    @property
    def sql_server_full(self) -> str:
        """Full server string with instance."""
        if self.sql_server_instance:
            return f"{self.sql_server_host}\\{self.sql_server_instance}"
        return self.sql_server_host

    def _build_connection_string(self, database: str) -> str:
        """Build ODBC connection string for a given database."""
        driver = self.resolved_sql_driver

        parts = [
            f"DRIVER={{{driver}}}",
            f"SERVER={self.sql_server_full}",
            f"DATABASE={database}",
        ]

        if self.sql_trusted_connection:
            parts.append("Trusted_Connection=yes")
        else:
            if self.sql_username and self.sql_password:
                parts.append(f"UID={self.sql_username}")
                parts.append(f"PWD={self.sql_password}")
            else:
                raise ValueError(
                    "SQL_USERNAME and SQL_PASSWORD required when "
                    "SQL_TRUSTED_CONNECTION=false"
                )

        # Encryption settings (critical for ODBC Driver 18 on localhost)
        parts.append(f"Encrypt={self.sql_encrypt}")
        if self.sql_trust_server_cert.lower() == "yes":
            parts.append("TrustServerCertificate=yes")

        return ";".join(parts)

    @property
    def odbc_connection_string(self) -> str:
        """ODBC connection string for HiperPdv (Caixa)."""
        return self._build_connection_string(self.sql_database)

    @property
    def odbc_connection_string_gestao(self) -> str:
        """ODBC connection string for Hiper (Gestão)."""
        return self._build_connection_string(self.sql_database_gestao)

    def log_config(self) -> None:
        """Log configuration (without sensitive data)."""
        auth_mode = (
            "Windows Authentication (Trusted)"
            if self.sql_trusted_connection
            else f"SQL Authentication (user: {self.sql_username})"
        )

        driver_display = self.sql_driver
        if self.sql_driver.lower() == "auto":
            try:
                driver_display = f"auto → {self.resolved_sql_driver}"
            except RuntimeError:
                driver_display = "auto → NOT FOUND"

        logger.info("=" * 60)
        logger.info("PDV Sync Agent Configuration")
        logger.info("=" * 60)
        logger.info(f"SQL Server: {self.sql_server_full}")
        logger.info(f"Database PDV: {self.sql_database}")
        logger.info(f"Database Gestão: {self.sql_database_gestao}")
        logger.info(f"Auth Mode: {auth_mode}")
        logger.info(f"ODBC Driver: {driver_display}")
        logger.info(f"Encrypt: {self.sql_encrypt} | TrustCert: {self.sql_trust_server_cert}")
        logger.info("-" * 60)
        logger.info(f"Store ID: {self.store_id_ponto_venda}")
        logger.info(f"Store Alias: {self.store_alias}")
        logger.info("-" * 60)
        logger.info(f"API Endpoint: {self.api_endpoint}")
        logger.info(f"API Token: {'*' * 8}...{self.api_token[-4:] if len(self.api_token) > 4 else '****'}")
        logger.info(f"Timeout: {self.request_timeout_seconds}s")
        logger.info("-" * 60)
        logger.info(f"Sync Window: {self.sync_window_minutes} minutes")
        logger.info(f"State File: {self.state_file}")
        logger.info(f"Outbox Dir: {self.outbox_dir}")
        logger.info(f"Log File: {self.log_file}")
        logger.info("=" * 60)


def load_settings(config_path: str = None) -> Settings:
    """
    Load and validate settings from environment.

    Args:
        config_path: Optional path to a .env file. If provided, overrides
                     the default .env in the current working directory.
                     Used for production deployments where the config lives
                     in C:\\ProgramData\\PDVSyncAgent\\.env
    """
    try:
        if config_path:
            resolved = Path(config_path).resolve()
            logger.info(f"Loading config from: {resolved}")
            settings = Settings(_env_file=str(resolved))
        else:
            settings = Settings()
        return settings
    except Exception as e:
        logger.error(f"Failed to load settings: {e}")
        raise
