"""
Pydantic models for the sync payload.
Defines the complete JSON structure sent to the central API.
"""

import hashlib
import platform
from datetime import datetime
from decimal import Decimal
from typing import Any, Optional

from pydantic import BaseModel, Field, computed_field

from . import __version__


class AgentInfo(BaseModel):
    """Information about the sync agent."""

    version: str = Field(default=__version__)
    machine: str = Field(default_factory=platform.node)
    sent_at: datetime = Field(default_factory=datetime.now)


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


class TurnoInfo(BaseModel):
    """Information about the current turno."""

    id_turno: Optional[str] = None
    sequencial: Optional[int] = None
    fechado: Optional[bool] = None
    data_hora_inicio: Optional[datetime] = None
    data_hora_termino: Optional[datetime] = None
    id_usuario_operador: Optional[int] = None


class OpsInfo(BaseModel):
    """Operations summary."""

    count: int
    ids: list[int]


class VendorSale(BaseModel):
    """Sales by vendor (seller)."""

    id_usuario: Optional[int] = None
    nome: Optional[str] = None
    qtd_cupons: int = 0
    total_vendido: Decimal = Decimal("0.00")


class PaymentMethod(BaseModel):
    """Sales by payment method."""

    id_finalizador: Optional[int] = None
    meio: Optional[str] = None
    total: Decimal = Decimal("0.00")


class SalesInfo(BaseModel):
    """Aggregated sales data."""

    by_vendor: list[VendorSale] = Field(default_factory=list)
    by_payment: list[PaymentMethod] = Field(default_factory=list)


class IntegrityInfo(BaseModel):
    """Integrity and idempotency data."""

    sync_id: str
    warnings: list[str] = Field(default_factory=list)


class SyncPayload(BaseModel):
    """Complete sync payload sent to the API."""

    agent: AgentInfo = Field(default_factory=AgentInfo)
    store: StoreInfo
    window: WindowInfo
    turno: Optional[TurnoInfo] = None
    ops: OpsInfo
    sales: SalesInfo
    integrity: IntegrityInfo

    model_config = {"populate_by_name": True}


def generate_sync_id(store_id: int, dt_from: datetime, dt_to: datetime) -> str:
    """
    Generate deterministic sync_id for idempotency.
    Uses SHA256 hash of store_id + from + to.
    """
    data = f"{store_id}|{dt_from.isoformat()}|{dt_to.isoformat()}"
    return hashlib.sha256(data.encode()).hexdigest()


def build_payload(
    store_id: int,
    store_name: str,
    store_alias: str,
    dt_from: datetime,
    dt_to: datetime,
    window_minutes: int,
    turno: Optional[dict[str, Any]],
    ops_ids: list[int],
    sales_by_vendor: list[dict[str, Any]],
    payments_by_method: list[dict[str, Any]],
    warnings: Optional[list[str]] = None,
) -> SyncPayload:
    """
    Build the complete sync payload from query results.
    """
    # Build vendor sales
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
        # Check for NULL vendor warning
        if row.get("id_usuario_vendedor") is None:
            if warnings is None:
                warnings = []
            warnings.append(
                f"Vendedor NULL em {row.get('qtd_cupons', 0)} cupom(s)"
            )

    # Build payment methods
    payments = []
    for row in payments_by_method:
        payments.append(
            PaymentMethod(
                id_finalizador=row.get("id_finalizador"),
                meio=row.get("meio_pagamento"),
                total=Decimal(str(row.get("total_pago", 0))),
            )
        )

    # Build turno info
    turno_info = None
    if turno:
        turno_info = TurnoInfo(
            id_turno=str(turno.get("id_turno")) if turno.get("id_turno") else None,
            sequencial=turno.get("sequencial"),
            fechado=turno.get("fechado"),
            data_hora_inicio=turno.get("data_hora_inicio"),
            data_hora_termino=turno.get("data_hora_termino"),
            id_usuario_operador=turno.get("id_usuario"),
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
        turno=turno_info,
        ops=OpsInfo(
            count=len(ops_ids),
            ids=ops_ids,
        ),
        sales=SalesInfo(
            by_vendor=vendors,
            by_payment=payments,
        ),
        integrity=IntegrityInfo(
            sync_id=sync_id,
            warnings=warnings or [],
        ),
    )
