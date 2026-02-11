"""
SQL queries for HiperPdv database.
All queries use CTEs to avoid N×M multiplication when joining items and payments.

Operation Types (confirmed):
  0 = Abertura de Caixa (legacy)
  1 = Venda
  3 = Sangria / Lançamento de falta no Caixa
  4 = Falta de Caixa (diferença sistema vs declarado)
  8 = Raro
  9 = Fechamento de Turno (valores declarados pelo operador)
"""

from datetime import datetime
from typing import Any, Optional

from loguru import logger

from .db import DatabaseConnection


class QueryExecutor:
    """Executes queries against the HiperPdv database."""

    def __init__(self, db: DatabaseConnection):
        self.db = db

    # ──────────────────────────────────────────────
    # Store Info
    # ──────────────────────────────────────────────

    def get_store_info(self, id_ponto_venda: int) -> Optional[dict[str, Any]]:
        """
        Get store information from ponto_venda table.
        Dynamically handles different column names (apelido, nome, etc.).
        """
        has_apelido = self.db.table_has_column("ponto_venda", "apelido")
        has_nome = self.db.table_has_column("ponto_venda", "nome")
        has_descricao = self.db.table_has_column("ponto_venda", "descricao")

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
            if store["nome"] is None:
                store["nome"] = f"PDV {id_ponto_venda}"
            logger.info(f"Store: {store['nome']} (ID: {store['id_ponto_venda']})")
            return store

        logger.warning(f"Store not found: id_ponto_venda={id_ponto_venda}")
        return None

    # ──────────────────────────────────────────────
    # Turnos
    # ──────────────────────────────────────────────

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

    def get_turnos_in_window(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get all turnos that had sale activity in the time window.
        Includes operator name via JOIN with usuario table.
        """
        query = """
            SELECT DISTINCT
                t.id_turno,
                t.sequencial,
                t.fechado,
                t.data_hora_inicio,
                t.data_hora_termino,
                t.id_usuario AS id_operador,
                u.nome AS nome_operador
            FROM dbo.turno t
            LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
            WHERE t.id_turno IN (
                SELECT DISTINCT op.id_turno
                FROM dbo.operacao_pdv op
                WHERE op.operacao = 1
                  AND op.cancelado = 0
                  AND op.data_hora_termino IS NOT NULL
                  AND op.data_hora_termino >= ?
                  AND op.data_hora_termino < ?
            )
            ORDER BY t.data_hora_inicio
        """

        logger.debug(f"Fetching turnos in window {dt_from} -> {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} turno(s) with activity in window")
        return results

    # ──────────────────────────────────────────────
    # Turno Closure & Shortage
    # ──────────────────────────────────────────────

    def get_turno_closure_values(self, id_turno: str) -> list[dict[str, Any]]:
        """
        Get the values DECLARED by the operator at turno closing (operacao=9).
        These are what the employee says they have in the register.
        """
        has_nome = self.db.table_has_column("finalizador_pdv", "nome")
        name_column = "nome" if has_nome else "NULL"

        query = f"""
            SELECT
                fo.id_finalizador,
                fpv.{name_column} AS meio_pagamento,
                SUM(ISNULL(fo.valor, 0)) AS total_declarado
            FROM dbo.operacao_pdv op
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao
            JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            WHERE op.id_turno = ?
              AND op.operacao = 9
              AND op.cancelado = 0
            GROUP BY fo.id_finalizador, fpv.{name_column}
            ORDER BY total_declarado DESC
        """

        logger.debug(f"Fetching closure values for turno {str(id_turno)[:12]}...")
        results = self.db.execute_query(query, (str(id_turno),))
        logger.info(f"Found {len(results)} closure entries for turno")
        return results

    def get_turno_shortage_values(self, id_turno: str) -> list[dict[str, Any]]:
        """
        Get the cash shortage values (operacao=4) for a turno.
        This is the difference between system total and declared total.
        """
        has_nome = self.db.table_has_column("finalizador_pdv", "nome")
        name_column = "nome" if has_nome else "NULL"

        query = f"""
            SELECT
                fo.id_finalizador,
                fpv.{name_column} AS meio_pagamento,
                SUM(ISNULL(fo.valor, 0)) AS total_falta
            FROM dbo.operacao_pdv op
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao
            JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            WHERE op.id_turno = ?
              AND op.operacao = 4
              AND op.cancelado = 0
            GROUP BY fo.id_finalizador, fpv.{name_column}
            ORDER BY total_falta DESC
        """

        logger.debug(f"Fetching shortage values for turno {str(id_turno)[:12]}...")
        results = self.db.execute_query(query, (str(id_turno),))
        logger.info(f"Found {len(results)} shortage entries for turno")
        return results

    # ──────────────────────────────────────────────
    # Operations (aggregated, for resumo/legacy)
    # ──────────────────────────────────────────────

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
            WHERE it.cancelado = 0
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
                COUNT(DISTINCT ops.id_operacao) AS qtd_vendas,
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

    # ──────────────────────────────────────────────
    # Sale Details (individual, for extrato)
    # ──────────────────────────────────────────────

    def get_sale_items(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get individual sale items with product names and vendor info.
        Each row = one item in one sale.
        """
        query = """
            WITH ops AS (
                SELECT id_operacao, id_turno, id_ponto_venda,
                       data_hora_termino
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
            )
            SELECT
                ops.id_operacao,
                ops.id_turno,
                ops.data_hora_termino,
                it.id_item_operacao_pdv AS line_id,
                it.item AS line_no,
                it.id_produto,
                it.codigo_barras,
                p.nome AS nome_produto,
                it.quantidade_primaria AS qtd,
                it.valor_unitario_liquido AS preco_unit,
                it.valor_total_liquido AS total_item,
                ISNULL(it.valor_desconto, 0) AS desconto_item,
                it.id_usuario_vendedor,
                uv.nome AS nome_vendedor
            FROM ops
            JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao
            JOIN dbo.produto p ON p.id_produto = it.id_produto
            LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor
            WHERE it.cancelado = 0
            ORDER BY ops.data_hora_termino, ops.id_operacao, it.item
        """

        logger.debug(f"Fetching sale items from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} sale items in window")
        return results

    def get_sale_payments(
        self,
        dt_from: datetime,
        dt_to: datetime,
    ) -> list[dict[str, Any]]:
        """
        Get payments per sale with parcelas and troco (change).
        Each row = one payment in one sale.
        """
        has_nome = self.db.table_has_column("finalizador_pdv", "nome")
        name_column = "nome" if has_nome else "NULL"

        query = f"""
            WITH ops AS (
                SELECT id_operacao
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
            )
            SELECT
                fo.id_finalizador_operacao_pdv AS line_id,
                fo.id_operacao,
                fo.id_finalizador,
                fpv.{name_column} AS meio_pagamento,
                fo.valor,
                ISNULL(fo.valor_troco, 0) AS valor_troco,
                fo.parcela
            FROM ops
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
            JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            ORDER BY fo.id_operacao, fo.id_finalizador
        """

        logger.debug(f"Fetching sale payments from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to))
        logger.info(f"Found {len(results)} sale payments in window")
        return results

    # ──────────────────────────────────────────────
    # Payments by Method per Turno (for turno-level totals)
    # ──────────────────────────────────────────────

    def get_payments_by_method_for_turno(
        self,
        id_turno: str,
    ) -> list[dict[str, Any]]:
        """
        Get payment totals by method for a specific turno (op=1 only).
        Used to build totais_sistema per turno.
        """
        has_nome = self.db.table_has_column("finalizador_pdv", "nome")
        name_column = "nome" if has_nome else "NULL"

        query = f"""
            SELECT
                fo.id_finalizador,
                fpv.{name_column} AS meio_pagamento,
                COUNT(DISTINCT op.id_operacao) AS qtd_vendas,
                SUM(ISNULL(fo.valor, 0)) AS total_pago
            FROM dbo.operacao_pdv op
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao
            JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            WHERE op.id_turno = ?
              AND op.operacao = 1
              AND op.cancelado = 0
            GROUP BY fo.id_finalizador, fpv.{name_column}
            ORDER BY total_pago DESC
        """

        logger.debug(f"Fetching payments by method for turno {str(id_turno)[:12]}...")
        results = self.db.execute_query(query, (str(id_turno),))
        return results


def create_query_executor(db: DatabaseConnection) -> QueryExecutor:
    """Factory function to create query executor."""
    return QueryExecutor(db)
