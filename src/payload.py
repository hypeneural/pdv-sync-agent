"""
Pydantic models for the sync payload v2.0.
Defines the complete JSON structure sent to the central API.

JSON structure:
  - agent: version, machine, timestamp
  - store: id, name, alias
  - window: from/to timestamps
  - turnos[]: per-turno data with sistema vs declarado totals
  - vendas[]: individual sale details with items and payments
  - resumo: aggregated totals (by_vendor, by_payment)
  - ops: operation IDs for deduplication
  - integrity: sync_id + warnings
"""

import hashlib
import platform
from datetime import datetime
from decimal import Decimal
from typing import Any, Optional

from pydantic import BaseModel, Field, computed_field

from . import __version__, SCHEMA_VERSION, BRT


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    """Attach BRT timezone to naive datetimes from SQL Server."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=BRT)
    return dt


# ──────────────────────────────────────────────
# Core Info Models
# ──────────────────────────────────────────────


class AgentInfo(BaseModel):
    """Information about the sync agent."""

    version: str = Field(default=__version__)
    machine: str = Field(default_factory=platform.node)
    sent_at: datetime = Field(default_factory=lambda: datetime.now(BRT))


class StoreInfo(BaseModel):
    """Information about the store (ponto_venda)."""

    id_ponto_venda: int
    nome: str
    alias: str


class WindowInfo(BaseModel):
    """Time window for the sync."""

    from_dt: datetime = Field(serialization_alias="from")
    to_dt: datetime = Field(serialization_alias="to")
    minutes: int


class OpsInfo(BaseModel):
    """Operations summary for deduplication."""

    count: int
    ids: list[int]


class IntegrityInfo(BaseModel):
    """Integrity and idempotency data."""

    sync_id: str
    warnings: list[str] = Field(default_factory=list)


# ──────────────────────────────────────────────
# Turno Models (NEW in v2.0)
# ──────────────────────────────────────────────


class OperatorInfo(BaseModel):
    """Operator or vendor info."""

    id_usuario: Optional[int] = None
    nome: Optional[str] = None


class PaymentTotal(BaseModel):
    """Total by payment method."""

    id_finalizador: Optional[int] = None
    meio: Optional[str] = None
    total: Decimal = Decimal("0.00")
    qtd_vendas: int = 0


class TurnoTotals(BaseModel):
    """System-calculated totals for a turno (from op=1 sales)."""

    total: Decimal = Decimal("0.00")
    qtd_vendas: int = 0
    por_pagamento: list[PaymentTotal] = Field(default_factory=list)


class ClosureTotals(BaseModel):
    """Values declared by operator at turno closing (op=9)."""

    total: Decimal = Decimal("0.00")
    por_pagamento: list[PaymentTotal] = Field(default_factory=list)


class ShortageTotals(BaseModel):
    """Cash shortage values — difference between system and declared (op=4)."""

    total: Decimal = Decimal("0.00")
    por_pagamento: list[PaymentTotal] = Field(default_factory=list)


class TurnoDetail(BaseModel):
    """Complete turno info with reconciliation data."""

    id_turno: Optional[str] = None
    sequencial: Optional[int] = None
    fechado: Optional[bool] = None
    data_hora_inicio: Optional[datetime] = None
    data_hora_termino: Optional[datetime] = None
    operador: OperatorInfo = Field(default_factory=OperatorInfo)
    totais_sistema: TurnoTotals = Field(default_factory=TurnoTotals)
    fechamento_declarado: Optional[ClosureTotals] = None
    falta_caixa: Optional[ShortageTotals] = None


# ──────────────────────────────────────────────
# Sale Detail Models (NEW in v2.0)
# ──────────────────────────────────────────────


class ProductItem(BaseModel):
    """Individual product item in a sale."""

    line_id: Optional[int] = None  # id_item_operacao_pdv (PK, stable)
    line_no: Optional[int] = None  # item sequence within the sale
    id_produto: int
    codigo_barras: Optional[str] = None
    nome: Optional[str] = None
    qtd: Decimal = Decimal("1")
    preco_unit: Decimal = Decimal("0.00")
    total: Decimal = Decimal("0.00")
    desconto: Decimal = Decimal("0.00")
    vendedor: Optional[OperatorInfo] = None


class SalePayment(BaseModel):
    """Payment entry in a sale."""

    line_id: Optional[int] = None  # id_finalizador_operacao_pdv (PK, stable)
    id_finalizador: Optional[int] = None
    meio: Optional[str] = None
    valor: Decimal = Decimal("0.00")
    troco: Decimal = Decimal("0.00")
    parcelas: Optional[int] = None


class SaleDetail(BaseModel):
    """Individual sale with items and payments."""

    id_operacao: int
    data_hora: Optional[datetime] = None
    id_turno: Optional[str] = None
    itens: list[ProductItem] = Field(default_factory=list)
    pagamentos: list[SalePayment] = Field(default_factory=list)
    total: Decimal = Decimal("0.00")


# ──────────────────────────────────────────────
# Resumo Models (kept from v1.0)
# ──────────────────────────────────────────────


class VendorSale(BaseModel):
    """Sales by vendor (seller)."""

    id_usuario: Optional[int] = None
    nome: Optional[str] = None
    qtd_cupons: int = 0
    total_vendido: Decimal = Decimal("0.00")


class PaymentMethod(BaseModel):
    """Sales by payment method (aggregated)."""

    id_finalizador: Optional[int] = None
    meio: Optional[str] = None
    total: Decimal = Decimal("0.00")


class SalesInfo(BaseModel):
    """Aggregated sales data (resumo)."""

    by_vendor: list[VendorSale] = Field(default_factory=list)
    by_payment: list[PaymentMethod] = Field(default_factory=list)


# ──────────────────────────────────────────────
# Legacy TurnoInfo (kept for backward compat)
# ──────────────────────────────────────────────


class TurnoInfo(BaseModel):
    """Legacy turno info (kept for reference, not used in v2 payload)."""

    id_turno: Optional[str] = None
    sequencial: Optional[int] = None
    fechado: Optional[bool] = None
    data_hora_inicio: Optional[datetime] = None
    data_hora_termino: Optional[datetime] = None
    id_usuario_operador: Optional[int] = None


# ──────────────────────────────────────────────
# Main Payload
# ──────────────────────────────────────────────


class SyncPayload(BaseModel):
    """Complete sync payload v2.0 sent to the API."""

    schema_version: str = Field(default=SCHEMA_VERSION)
    agent: AgentInfo = Field(default_factory=AgentInfo)
    store: StoreInfo
    window: WindowInfo
    turnos: list[TurnoDetail] = Field(default_factory=list)
    vendas: list[SaleDetail] = Field(default_factory=list)
    resumo: SalesInfo = Field(default_factory=SalesInfo)
    ops: OpsInfo
    integrity: IntegrityInfo

    model_config = {"populate_by_name": True}


# ──────────────────────────────────────────────
# Builder Functions
# ──────────────────────────────────────────────


def generate_sync_id(store_id: int, dt_from: datetime, dt_to: datetime) -> str:
    """
    Generate deterministic sync_id for idempotency.
    Uses SHA256 hash of store_id + from + to.
    """
    data = f"{store_id}|{dt_from.isoformat()}|{dt_to.isoformat()}"
    return hashlib.sha256(data.encode()).hexdigest()


def build_turno_detail(
    turno: dict[str, Any],
    system_payments: list[dict[str, Any]],
    closure_values: Optional[list[dict[str, Any]]] = None,
    shortage_values: Optional[list[dict[str, Any]]] = None,
) -> TurnoDetail:
    """Build a TurnoDetail from query results."""

    # Build system totals
    payment_totals = []
    total_sistema = Decimal("0")
    total_vendas = 0

    for row in system_payments:
        total = Decimal(str(row.get("total_pago", 0)))
        qtd = row.get("qtd_vendas", 0)
        payment_totals.append(
            PaymentTotal(
                id_finalizador=row.get("id_finalizador"),
                meio=row.get("meio_pagamento"),
                total=total,
                qtd_vendas=qtd,
            )
        )
        total_sistema += total
        total_vendas = max(total_vendas, qtd)  # qtd_vendas is per-method COUNT DISTINCT

    # Count total unique sales across all methods
    # We use the sum of distinct operations, but since one sale can have multiple
    # payment methods, we take the max count from any single method as approximation.
    # The exact count comes from ops.count.

    totais_sistema = TurnoTotals(
        total=total_sistema,
        qtd_vendas=total_vendas,
        por_pagamento=payment_totals,
    )

    # Build closure totals (op=9) if available
    fechamento = None
    if closure_values:
        closure_payments = []
        total_declarado = Decimal("0")
        for row in closure_values:
            total = Decimal(str(row.get("total_declarado", 0)))
            closure_payments.append(
                PaymentTotal(
                    id_finalizador=row.get("id_finalizador"),
                    meio=row.get("meio_pagamento"),
                    total=total,
                )
            )
            total_declarado += total
        fechamento = ClosureTotals(
            total=total_declarado,
            por_pagamento=closure_payments,
        )

    # Build shortage totals (op=4) if available
    falta = None
    if shortage_values:
        shortage_payments = []
        total_falta = Decimal("0")
        for row in shortage_values:
            total = Decimal(str(row.get("total_falta", 0)))
            shortage_payments.append(
                PaymentTotal(
                    id_finalizador=row.get("id_finalizador"),
                    meio=row.get("meio_pagamento"),
                    total=total,
                )
            )
            total_falta += total
        falta = ShortageTotals(
            total=total_falta,
            por_pagamento=shortage_payments,
        )

    return TurnoDetail(
        id_turno=str(turno.get("id_turno")) if turno.get("id_turno") else None,
        sequencial=turno.get("sequencial"),
        fechado=turno.get("fechado"),
        data_hora_inicio=_aware(turno.get("data_hora_inicio")),
        data_hora_termino=_aware(turno.get("data_hora_termino")),
        operador=OperatorInfo(
            id_usuario=turno.get("id_operador") or turno.get("id_usuario"),
            nome=turno.get("nome_operador"),
        ),
        totais_sistema=totais_sistema,
        fechamento_declarado=fechamento,
        falta_caixa=falta,
    )


def build_sale_details(
    sale_items: list[dict[str, Any]],
    sale_payments: list[dict[str, Any]],
) -> list[SaleDetail]:
    """
    Build individual SaleDetail objects from items and payments.
    Groups items and payments by id_operacao.
    """
    # Group items by id_operacao
    items_by_op: dict[int, list[dict]] = {}
    op_meta: dict[int, dict] = {}

    for row in sale_items:
        op_id = row["id_operacao"]
        if op_id not in items_by_op:
            items_by_op[op_id] = []
            op_meta[op_id] = {
                "data_hora": _aware(row.get("data_hora_termino")),
                "id_turno": str(row["id_turno"]) if row.get("id_turno") else None,
            }
        items_by_op[op_id].append(row)

    # Group payments by id_operacao
    payments_by_op: dict[int, list[dict]] = {}
    for row in sale_payments:
        op_id = row["id_operacao"]
        if op_id not in payments_by_op:
            payments_by_op[op_id] = []
        payments_by_op[op_id].append(row)

    # Build SaleDetail for each operation
    sales = []
    for op_id in sorted(items_by_op.keys()):
        items = items_by_op[op_id]
        meta = op_meta[op_id]

        # Build product items
        product_items = []
        total_venda = Decimal("0")
        for item in items:
            total_item = Decimal(str(item.get("total_item", 0)))
            product_items.append(
                ProductItem(
                    line_id=item.get("line_id"),
                    line_no=item.get("line_no"),
                    id_produto=item["id_produto"],
                    codigo_barras=item.get("codigo_barras"),
                    nome=item.get("nome_produto"),
                    qtd=Decimal(str(item.get("qtd", 1))),
                    preco_unit=Decimal(str(item.get("preco_unit", 0))),
                    total=total_item,
                    desconto=Decimal(str(item.get("desconto_item", 0))),
                    vendedor=OperatorInfo(
                        id_usuario=item.get("id_usuario_vendedor"),
                        nome=item.get("nome_vendedor"),
                    ) if item.get("id_usuario_vendedor") else None,
                )
            )
            total_venda += total_item

        # Build payments
        payment_list = []
        for pay in payments_by_op.get(op_id, []):
            payment_list.append(
                SalePayment(
                    line_id=pay.get("line_id"),
                    id_finalizador=pay.get("id_finalizador"),
                    meio=pay.get("meio_pagamento"),
                    valor=Decimal(str(pay.get("valor", 0))),
                    troco=Decimal(str(pay.get("valor_troco", 0))),
                    parcelas=pay.get("parcela"),
                )
            )

        sales.append(
            SaleDetail(
                id_operacao=op_id,
                data_hora=meta["data_hora"],
                id_turno=meta["id_turno"],
                itens=product_items,
                pagamentos=payment_list,
                total=total_venda,
            )
        )

    return sales


def build_payload(
    store_id: int,
    store_name: str,
    store_alias: str,
    dt_from: datetime,
    dt_to: datetime,
    window_minutes: int,
    turnos: list[TurnoDetail],
    vendas: list[SaleDetail],
    ops_ids: list[int],
    sales_by_vendor: list[dict[str, Any]],
    payments_by_method: list[dict[str, Any]],
    warnings: Optional[list[str]] = None,
) -> SyncPayload:
    """
    Build the complete sync payload v2.0 from query results.
    """
    # Build vendor sales (resumo)
    vendors = []
    for row in sales_by_vendor:
        vendors.append(
            VendorSale(
                id_usuario=row.get("id_usuario_vendedor"),
                nome=row.get("vendedor_nome"),
                qtd_cupons=row.get("qtd_cupons", 0),
                total_vendido=Decimal(str(row.get("total_vendido", 0))),
            )
        )

    # Build payment methods (resumo)
    payments = []
    for row in payments_by_method:
        payments.append(
            PaymentMethod(
                id_finalizador=row.get("id_finalizador"),
                meio=row.get("meio_pagamento"),
                total=Decimal(str(row.get("total_pago", 0))),
            )
        )

    # Generate sync_id
    sync_id = generate_sync_id(store_id, dt_from, dt_to)

    return SyncPayload(
        agent=AgentInfo(),
        store=StoreInfo(
            id_ponto_venda=store_id,
            nome=store_name,
            alias=store_alias,
        ),
        window=WindowInfo(
            from_dt=dt_from,
            to_dt=dt_to,
            minutes=window_minutes,
        ),
        turnos=turnos,
        vendas=vendas,
        resumo=SalesInfo(
            by_vendor=vendors,
            by_payment=payments,
        ),
        ops=OpsInfo(
            count=len(ops_ids),
            ids=ops_ids,
        ),
        integrity=IntegrityInfo(
            sync_id=sync_id,
            warnings=warnings or [],
        ),
    )
