"""
SQL queries for Hiper (Gestão) database.
Reads Hiper Loja sales (origem=2) which only exist in the Gestão database.

Key schema differences from HiperPdv:
  - operacao_pdv has 'origem' column (2 = Loja)
  - operacao_pdv has 'id_filial' instead of turno.id_ponto_venda
  - operacao_pdv has 'ValorTroco' (NOT in finalizador_operacao_pdv)
  - finalizador_operacao_pdv does NOT have 'valor_troco' column
  - IDs (usuario, finalizador, produto) are UNIVERSAL across both DBs
"""

from datetime import datetime
from typing import Any, Optional

from loguru import logger

from .db import DatabaseConnection


class GestaoQueryExecutor:
    """Executes queries against the Hiper (Gestão) database for Loja sales."""

    def __init__(self, db: DatabaseConnection):
        self.db = db

    # ──────────────────────────────────────────────
    # Operations in window (origem=2 only)
    # ──────────────────────────────────────────────

    def get_loja_operations_in_window(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[dict[str, Any]]:
        """
        Get all valid Loja sale operations (operacao=1, cancelado=0, origem=2)
        in the time window.
        """
        query = """
            SELECT
                op.id_operacao,
                op.id_filial,
                op.id_usuario,
                op.data_hora_inicio,
                op.data_hora_termino,
                op.operacao,
                op.cancelado,
                CONVERT(VARCHAR(36), op.id_turno) AS id_turno
            FROM dbo.operacao_pdv op
            WHERE op.operacao = 1
              AND op.cancelado = 0
              AND op.origem = 2
              AND op.data_hora_termino IS NOT NULL
              AND op.data_hora_termino >= ?
              AND op.data_hora_termino < ?
              AND op.id_filial = ?
            ORDER BY op.data_hora_termino
        """

        logger.debug(f"[Gestão] Fetching Loja operations from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        logger.info(f"[Gestão] Found {len(results)} Loja operations in window")
        return results

    # ──────────────────────────────────────────────
    # Operation IDs (for deduplication)
    # ──────────────────────────────────────────────

    def get_loja_operation_ids(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[int]:
        """
        Get just the operation IDs for Loja sales in the window.
        """
        query = """
            SELECT op.id_operacao
            FROM dbo.operacao_pdv op
            WHERE op.operacao = 1
              AND op.cancelado = 0
              AND op.origem = 2
              AND op.data_hora_termino IS NOT NULL
              AND op.data_hora_termino >= ?
              AND op.data_hora_termino < ?
              AND op.id_filial = ?
            ORDER BY op.id_operacao
        """

        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        return [row["id_operacao"] for row in results]

    # ──────────────────────────────────────────────
    # Sale items
    # ──────────────────────────────────────────────

    def get_loja_sale_items(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[dict[str, Any]]:
        """
        Get individual sale items for Loja sales with product names and vendor info.
        Each row = one item in one sale.
        """
        query = """
            WITH ops AS (
                SELECT id_operacao, id_turno, id_filial,
                       data_hora_termino
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND origem = 2
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
                  AND id_filial = ?
            )
            SELECT
                ops.id_operacao,
                CONVERT(VARCHAR(36), ops.id_turno) AS id_turno,
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

        logger.debug(f"[Gestão] Fetching Loja sale items from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        logger.info(f"[Gestão] Found {len(results)} Loja sale items in window")
        return results

    # ──────────────────────────────────────────────
    # Sale payments
    # NOTE: Gestão does NOT have valor_troco in finalizador_operacao_pdv
    #       Troco is in operacao_pdv.ValorTroco instead
    # ──────────────────────────────────────────────

    def get_loja_sale_payments(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[dict[str, Any]]:
        """
        Get payments per Loja sale.
        Each row = one payment in one sale.

        NOTE: valor_troco comes from operacao_pdv.ValorTroco (not finalizador_operacao_pdv).
        """
        query = """
            WITH ops AS (
                SELECT id_operacao, ISNULL(ValorTroco, 0) AS valor_troco_op
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND origem = 2
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
                  AND id_filial = ?
            ),
            pagamentos AS (
                SELECT
                    fo.id_finalizador_operacao_pdv AS line_id,
                    fo.id_operacao,
                    fo.id_finalizador,
                    fpv.nome AS meio_pagamento,
                    fo.valor,
                    ops.valor_troco_op,
                    fo.parcela,
                    ROW_NUMBER() OVER (
                        PARTITION BY fo.id_operacao
                        ORDER BY fo.id_finalizador ASC
                    ) AS rn
                FROM ops
                JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
                LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            )
            SELECT
                line_id,
                id_operacao,
                id_finalizador,
                meio_pagamento,
                valor,
                CASE WHEN rn = 1 THEN valor_troco_op ELSE 0 END AS valor_troco,
                parcela
            FROM pagamentos
            ORDER BY id_operacao, id_finalizador
        """

        logger.debug(f"[Gestão] Fetching Loja sale payments from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        logger.info(f"[Gestão] Found {len(results)} Loja sale payments in window")
        return results

    # ──────────────────────────────────────────────
    # Sales by vendor (resumo)
    # ──────────────────────────────────────────────

    def get_loja_sales_by_vendor(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[dict[str, Any]]:
        """
        Get Loja sales aggregated by vendor (seller) using CTE.
        """
        query = """
            WITH ops AS (
                SELECT id_operacao, id_filial,
                    CONVERT(VARCHAR(36), id_turno) AS id_turno
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND origem = 2
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
                  AND id_filial = ?
            )
            SELECT
                ops.id_filial AS id_ponto_venda,
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
                ops.id_filial,
                ops.id_turno,
                it.id_usuario_vendedor,
                u.nome
            ORDER BY total_vendido DESC
        """

        logger.debug(f"[Gestão] Fetching Loja sales by vendor from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        logger.info(f"[Gestão] Found {len(results)} Loja vendor aggregations")
        return results

    # ──────────────────────────────────────────────
    # Payments by method (resumo)
    # ──────────────────────────────────────────────

    def get_loja_payments_by_method(
        self,
        dt_from: datetime,
        dt_to: datetime,
        id_filial: int,
    ) -> list[dict[str, Any]]:
        """
        Get Loja payments aggregated by payment method using CTE.
        """
        query = """
            WITH ops AS (
                SELECT id_operacao, id_filial,
                    CONVERT(VARCHAR(36), id_turno) AS id_turno
                FROM dbo.operacao_pdv
                WHERE operacao = 1 AND cancelado = 0
                  AND origem = 2
                  AND data_hora_termino IS NOT NULL
                  AND data_hora_termino >= ?
                  AND data_hora_termino < ?
                  AND id_filial = ?
            )
            SELECT
                ops.id_filial AS id_ponto_venda,
                ops.id_turno,
                fo.id_finalizador,
                fpv.nome AS meio_pagamento,
                COUNT(DISTINCT ops.id_operacao) AS qtd_vendas,
                SUM(ISNULL(fo.valor, 0)) AS total_pago
            FROM ops
            JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
            LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
            GROUP BY
                ops.id_filial,
                ops.id_turno,
                fo.id_finalizador,
                fpv.nome
            ORDER BY total_pago DESC
        """

        logger.debug(f"[Gestão] Fetching Loja payments by method from {dt_from} to {dt_to}")
        results = self.db.execute_query(query, (dt_from, dt_to, id_filial))
        logger.info(f"[Gestão] Found {len(results)} Loja payment method aggregations")
        return results

    # ──────────────────────────────────────────────
    # Vendas snapshot (últimas N vendas Loja)
    # ──────────────────────────────────────────────

    def get_loja_vendas_snapshot(
        self,
        id_filial: int,
        limit: int = 10,
    ) -> list[dict[str, Any]]:
        """
        Get the last N completed Loja sales with summary for verification.
        Includes vendor, item count, and total.
        """
        query = f"""
            SELECT TOP {limit}
                op.id_operacao,
                op.data_hora_inicio,
                op.data_hora_termino,
                DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino)
                    AS duracao_segundos,
                CONVERT(VARCHAR(36), op.id_turno) AS id_turno,
                (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
                 WHERE i.id_operacao = op.id_operacao
                   AND i.cancelado = 0) AS qtd_itens,
                (SELECT ISNULL(SUM(i.valor_total_liquido), 0)
                 FROM dbo.item_operacao_pdv i
                 WHERE i.id_operacao = op.id_operacao
                   AND i.cancelado = 0) AS total_itens,
                (SELECT TOP 1 uv.id_usuario
                 FROM dbo.item_operacao_pdv iv
                 JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
                 WHERE iv.id_operacao = op.id_operacao
                   AND iv.cancelado = 0) AS id_vendedor,
                (SELECT TOP 1 uv.nome
                 FROM dbo.item_operacao_pdv iv
                 JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
                 WHERE iv.id_operacao = op.id_operacao
                   AND iv.cancelado = 0) AS nome_vendedor
            FROM dbo.operacao_pdv op
            WHERE op.operacao = 1 AND op.cancelado = 0
              AND op.origem = 2
              AND op.data_hora_termino IS NOT NULL
              AND op.id_filial = ?
            ORDER BY op.data_hora_termino DESC
        """

        logger.debug(f"[Gestão] Fetching Loja vendas snapshot (last {limit}) for store {id_filial}")
        results = self.db.execute_query(query, (id_filial,))
        logger.info(f"[Gestão] Loja vendas snapshot: {len(results)} recent sales")
        return results


def create_gestao_query_executor(db: DatabaseConnection) -> GestaoQueryExecutor:
    """Factory function to create GestaoQueryExecutor."""
    return GestaoQueryExecutor(db)
