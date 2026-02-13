"""
Database connection utilities for SQL Server via ODBC.
Includes human-friendly error messages for common connection failures.
"""

from contextlib import contextmanager
from typing import Any, Generator, Optional

import pyodbc
from loguru import logger

from .settings import Settings


# Common pyodbc error codes mapped to human-friendly messages
_ERROR_MESSAGES = {
    "08001": (
        "❌ Não foi possível conectar ao SQL Server.\n"
        "   Possíveis causas:\n"
        "   • Instância '{instance}' não encontrada ou não está rodando\n"
        "   • Serviço SQL Server Browser parado (necessário para instâncias nomeadas)\n"
        "   • Firewall bloqueando porta TCP 1433\n"
        "   → Verifique: services.msc → SQL Server (HIPER) está rodando?"
    ),
    "28000": (
        "❌ Login falhou no SQL Server.\n"
        "   Possíveis causas:\n"
        "   • Usuário/senha incorretos no .env\n"
        "   • Se usando Trusted_Connection=yes com SYSTEM: NT AUTHORITY\\SYSTEM não tem login no SQL Server\n"
        "   → Solução: Use SQL Auth com usuário dedicado (ex: pdv_sync) ou crie login para SYSTEM"
    ),
    "42000": (
        "❌ Sem permissão no banco de dados '{database}'.\n"
        "   O usuário conectou no SQL Server mas não tem acesso ao banco.\n"
        "   → Solução: GRANT SELECT ON SCHEMA::dbo TO [pdv_sync]"
    ),
    "IM002": (
        "❌ Driver ODBC não encontrado.\n"
        "   O driver '{driver}' não está instalado nesta máquina.\n"
        "   → Instale: https://learn.microsoft.com/sql/connect/odbc/download-odbc-driver-for-sql-server\n"
        "   → Ou defina SQL_DRIVER=auto no .env para detecção automática"
    ),
    "HYT00": (
        "❌ Timeout ao conectar ao SQL Server.\n"
        "   O servidor não respondeu em 30 segundos.\n"
        "   → Verifique se o SQL Server está rodando e acessível"
    ),
}


def _friendly_error(e: pyodbc.Error, settings: Settings) -> str:
    """Generate a human-friendly error message for common pyodbc errors."""
    error_str = str(e)

    # Extract SQL state from error
    for code, template in _ERROR_MESSAGES.items():
        if code in error_str:
            return template.format(
                instance=settings.sql_server_full,
                database=settings.sql_database,
                driver=settings.sql_driver,
            )

    # Fallback: return original error
    return f"❌ Erro de conexão: {e}"


class DatabaseConnection:
    """Manages SQL Server database connections."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._connection: Optional[pyodbc.Connection] = None
        self._connection_string_override: Optional[str] = None
        self._column_cache: dict[str, list[str]] = {}

    def connect(self) -> pyodbc.Connection:
        """Establish database connection."""
        if self._connection is not None:
            try:
                # Test if connection is still alive
                self._connection.execute("SELECT 1")
                return self._connection
            except pyodbc.Error:
                self._connection = None

        conn_string = self._connection_string_override or self.settings.odbc_connection_string
        # Extract database name for logging
        db_name = "unknown"
        for part in conn_string.split(";"):
            if part.upper().startswith("DATABASE="):
                db_name = part.split("=", 1)[1]
                break

        logger.info(f"Connecting to SQL Server: {self.settings.sql_server_full}")
        logger.info(f"Database: {db_name}")

        try:
            self._connection = pyodbc.connect(
                conn_string,
                timeout=30,
            )
            logger.success(f"Database connection established ({db_name})")
            return self._connection
        except pyodbc.Error as e:
            friendly = _friendly_error(e, self.settings)
            logger.error(friendly)
            raise

    def close(self) -> None:
        """Close database connection."""
        if self._connection is not None:
            try:
                self._connection.close()
                logger.info("Database connection closed")
            except pyodbc.Error as e:
                logger.warning(f"Error closing connection: {e}")
            finally:
                self._connection = None

    @contextmanager
    def cursor(self) -> Generator[pyodbc.Cursor, None, None]:
        """Context manager for database cursor."""
        conn = self.connect()
        cursor = conn.cursor()
        try:
            yield cursor
        finally:
            cursor.close()

    def execute_query(
        self, query: str, params: tuple = ()
    ) -> list[dict[str, Any]]:
        """Execute a query and return results as list of dicts."""
        with self.cursor() as cursor:
            cursor.execute(query, params)
            columns = [column[0] for column in cursor.description]
            rows = cursor.fetchall()
            return [dict(zip(columns, row)) for row in rows]

    def execute_scalar(
        self, query: str, params: tuple = ()
    ) -> Optional[Any]:
        """Execute a query and return a single value."""
        with self.cursor() as cursor:
            cursor.execute(query, params)
            row = cursor.fetchone()
            return row[0] if row else None

    def get_table_columns(self, table_name: str) -> list[str]:
        """Get list of column names for a table (cached per connection instance)."""
        if table_name in self._column_cache:
            return self._column_cache[table_name]

        query = """
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
        """
        with self.cursor() as cursor:
            cursor.execute(query, (table_name,))
            columns = [row[0] for row in cursor.fetchall()]
            self._column_cache[table_name] = columns
            return columns

    def table_has_column(self, table_name: str, column_name: str) -> bool:
        """Check if a table has a specific column."""
        columns = self.get_table_columns(table_name)
        return column_name.lower() in [c.lower() for c in columns]

    def test_connection(self) -> tuple[bool, str]:
        """
        Test database connection and return (success, message).
        Used by --doctor mode.
        """
        try:
            conn = self.connect()
            cursor = conn.cursor()
            cursor.execute("SELECT TOP 1 @@VERSION")
            version = cursor.fetchone()[0]
            cursor.close()
            short_version = version.split("\n")[0][:80]
            return True, f"SQL Server: {short_version}"
        except Exception as e:
            return False, _friendly_error(e, self.settings) if isinstance(e, pyodbc.Error) else str(e)


def create_db_connection(settings: Settings) -> DatabaseConnection:
    """Factory function to create HiperPdv (Caixa) database connection."""
    return DatabaseConnection(settings)


def create_gestao_db_connection(settings: Settings) -> DatabaseConnection:
    """Factory function to create Hiper (Gestão) database connection.

    Uses the same Settings but overrides the connection string to point
    to the Gestão database.
    """
    db = DatabaseConnection(settings)
    # Override connection to use Gestão database
    db._connection_string_override = settings.odbc_connection_string_gestao
    return db

