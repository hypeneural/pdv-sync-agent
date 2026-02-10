"""
SQL queries for HiperPdv database.
All queries use CTEs to avoid N×M multiplication when joining items and payments.
"""

from datetime import datetime
from typing import Any, Optional

from loguru import logger

from .db import DatabaseConnection


class QueryExecutor:
    """Executes queries against the HiperPdv database."""

    def __init__(self, db: DatabaseConnection):
        self.db = db

    def get_store_info(self, id_ponto_venda: int) -> Optional[dict[str, Any]]:
        """
        Get store information from ponto_venda table.
        Dynamically handles different column names (apelido, nome, etc.).
        """
        # Check which columns exist
        has_apelido = self.db.table_has_column("ponto_venda", "apelido")
        has_nome = self.db.table_has_column("ponto_venda", "nome")
        has_descricao = self.db.table_has_column("ponto_venda", "descricao")

        # Build SELECT clause dynamically
        name_column = "NULL"
        if has_apelido:
            name_column = "apelido"
        elif has_nome:
            name_column = "nome"
        elif has_descricao:
            name_column = "descricao"

        query = f"""
            SELECT
                id_ponto_venda,
                {name_column} AS nome
            FROM dbo.ponto_venda
            WHERE id_ponto_venda = ?
        """

        logger.debug(f"Fetching store info for id_ponto_venda={id_ponto_venda}")
        results = self.db.execute_query(query, (id_ponto_venda,))

        if results:
            store = results[0]
            # Fallback to id_ponto_venda if name is NULL
            if store["nome"] is None:
                store["nome"] = f"PDV {id_ponto_venda}"
            logger.info(f"Store: {store['nome']} (ID: {store['id_ponto_venda']})")
            return store

        logger.warning(f"Store not found: id_ponto_venda={id_ponto_venda}")
        return None

    def get_current_turno(self, id_ponto_venda: int) -> Optional[dict[str, Any]]:
        """
        Get the most recent turno for the store.
        """
        query = """
            SELECT TOP 1
                id_turno,
                id_ponto_venda,
                id_usuario,
                data_hora_inicio,
                data_hora_termino,
                fechado,
                sequencial
            FROM dbo.turno
            WHERE id_ponto_venda = ?
            ORDER BY data_hora_inicio DESC
        """

        logger.debug(f"Fetching current turno for store {id_ponto_venda}")
        results = self.db.execute_query(query, (id_ponto_venda,))

        if results:
            turno = results[0]
            logger.info(
                f"Current turno: {turno['id_turno']} "
                f"(sequencial={turno.get('sequencial')}, "
                f"fechado={turno.get('fechado')})"
            )
            return turno

        logger.warning(f"No turno found for store {id_ponto_venda}")
        return None

    def get_operations_in_window(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get all valid sale operations (operacao=1, cancelado=0) in the time window.
        """
        query = """
            SELECT
                op.id_operacao,
                op.id_ponto_venda,
                op.id_turno,
                op.id_usuario,
                op.data_hora_inicio,
                op.data_hora_termino,
                op.operacao,
                op.cancelado
            FROM dbo.operacao_pdv op
            WHERE op.operacao = 1
              AND op.cancelado = 0
              AND op.data_hora_termino IS NOT NULL
              AND op.data_hora_termino >= ?
              AND op.data_hora_termino < ?
            ORDER BY op.data_hora_termino
        """

        logger.debug(f"Fetching operations from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} operations in window")
        return results

    def get_sales_by_vendor(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get sales aggregated by vendor (seller) using CTE to avoid N×M.
        """
        query = """
            WITH ops AS (
                SELECT
                    op.id_operacao,
                    op.id_ponto_venda,
                    op.id_turno
                FROM dbo.operacao_pdv op
                WHERE op.operacao = 1
                  AND op.cancelado = 0
                  AND op.data_hora_termino IS NOT NULL
                  AND op.data_hora_termino >= ?
                  AND op.data_hora_termino < ?
            )
            SELECT
                ops.id_ponto_venda,
                ops.id_turno,
                it.id_usuario_vendedor,
                u.nome AS vendedor_nome,
                COUNT(DISTINCT ops.id_operacao) AS qtd_cupons,
                SUM(ISNULL(it.valor_total_liquido, 0)) AS total_vendido
            FROM ops
            JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao
            LEFT JOIN dbo.usuario u ON u.id_usuario = it.id_usuario_vendedor
            GROUP BY
                ops.id_ponto_venda,
                ops.id_turno,
                it.id_usuario_vendedor,
                u.nome
            ORDER BY total_vendido DESC
        """

        logger.debug(f"Fetching sales by vendor from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} vendor aggregations")
        return results

    def get_payments_by_method(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get payments aggregated by payment method using CTE.
        Maps id_finalizador to nome from finalizador_pdv.
        """
        # Check if finalizador_pdv has 'nome' or 'descricao' column
        has_nome = self.db.table_has_column("finalizador_pdv", "nome")
        has_descricao = self.db.table_has_column("finalizador_pdv", "descricao")

        name_column = "nome" if has_nome else ("descricao" if has_descricao else "NULL")

        query = f"""
            WITH ops AS (
                SELECT
                    op.id_operacao,
                    op.id_ponto_venda,
                    op.id_turno
                FROM dbo.operacao_pdv op
                WHERE op.operacao = 1
                  AND op.cancelado = 0
                  AND op.data_hora_termino IS NOT NULL
                  AND op.data_hora_termino >= ?
                  AND op.data_hora_termino < ?
            )
            SELECT
                ops.id_ponto_venda,
                ops.id_turno,
                fo.id_finalizador,
                fpv.{name_column} AS meio_pagamento,
                SUM(ISNULL(fo.valor, 0)) AS total_pago
            FROM ops
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
            LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            GROUP BY
                ops.id_ponto_venda,
                ops.id_turno,
                fo.id_finalizador,
                fpv.{name_column}
            ORDER BY total_pago DESC
        """

        logger.debug(f"Fetching payments by method from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} payment method aggregations")
        return results

    def get_operation_ids(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[int]:
        """
        Get just the operation IDs in the window (for deduplication).
        """
        query = """
            SELECT op.id_operacao
            FROM dbo.operacao_pdv op
            WHERE op.operacao = 1
              AND op.cancelado = 0
              AND op.data_hora_termino IS NOT NULL
              AND op.data_hora_termino >= ?
              AND op.data_hora_termino < ?
            ORDER BY op.id_operacao
        """

        results = self.db.execute_query(query, (dt_from, dt_to))
        return [row["id_operacao"] for row in results]


def create_query_executor(db: DatabaseConnection) -> QueryExecutor:
    """Factory function to create query executor."""
    return QueryExecutor(db)
