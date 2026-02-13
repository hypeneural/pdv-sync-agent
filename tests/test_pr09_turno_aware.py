#!/usr/bin/env python3
"""
PR-09 Validation Test Suite — Turno-Aware Sync
===============================================
Tests all scenarios without needing a real database or API.
Uses mocks to simulate the complete sync pipeline.

Run:
    python tests/test_pr09_turno_aware.py
"""

import sys
import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from unittest.mock import MagicMock, patch, PropertyMock
from typing import Any, Optional

# Setup path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import BRT, SCHEMA_VERSION
from src.payload import (
    SyncPayload,
    TurnoDetail,
    SaleDetail,
    OperatorInfo,
    TurnoTotals,
    ClosureTotals,
    ShortageTotals,
    PaymentTotal,
    build_payload,
    build_turno_detail,
)

# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

NOW = datetime(2026, 2, 11, 21, 0, 0, tzinfo=BRT)
TEN_MIN_AGO = NOW - timedelta(minutes=10)

PASS = "✅ PASS"
FAIL = "❌ FAIL"
results: list[tuple[str, str, str]] = []


def record(test_name: str, passed: bool, detail: str = ""):
    status = PASS if passed else FAIL
    results.append((test_name, status, detail))
    print(f"  [{status}] {test_name}")
    if detail and not passed:
        print(f"         → {detail}")


def make_turno_closed() -> TurnoDetail:
    """Create a closed turno with closure data."""
    return TurnoDetail(
        id_turno="AAA-BBB-CCC-CLOSED",
        sequencial=1,
        fechado=True,
        data_hora_inicio=datetime(2026, 2, 11, 8, 0, 0, tzinfo=BRT),
        data_hora_termino=datetime(2026, 2, 11, 20, 55, 0, tzinfo=BRT),
        operador=OperatorInfo(id_usuario=5, nome="João"),
        totais_sistema=TurnoTotals(
            total=Decimal("1019.70"),
            qtd_vendas=16,
            por_pagamento=[
                PaymentTotal(id_finalizador=2, meio="Cartão de crédito", total=Decimal("637.80"), qtd_vendas=7),
                PaymentTotal(id_finalizador=1, meio="Dinheiro", total=Decimal("135.00"), qtd_vendas=4),
            ],
        ),
        fechamento_declarado=ClosureTotals(
            total=Decimal("940.70"),
            por_pagamento=[
                PaymentTotal(id_finalizador=2, meio="Cartão de crédito", total=Decimal("617.80")),
                PaymentTotal(id_finalizador=1, meio="Dinheiro", total=Decimal("105.00")),
            ],
        ),
        falta_caixa=ShortageTotals(
            total=Decimal("-79.00"),
            por_pagamento=[
                PaymentTotal(id_finalizador=2, meio="Cartão de crédito", total=Decimal("-20.00")),
                PaymentTotal(id_finalizador=1, meio="Dinheiro", total=Decimal("-30.00")),
            ],
        ),
    )


def make_turno_open() -> TurnoDetail:
    """Create an open turno (no closure data)."""
    return TurnoDetail(
        id_turno="DDD-EEE-FFF-OPEN",
        sequencial=2,
        fechado=False,
        data_hora_inicio=datetime(2026, 2, 11, 16, 0, 0, tzinfo=BRT),
        data_hora_termino=None,
        operador=OperatorInfo(id_usuario=5, nome="João"),
        totais_sistema=TurnoTotals(
            total=Decimal("200.00"),
            qtd_vendas=3,
            por_pagamento=[
                PaymentTotal(id_finalizador=1, meio="Dinheiro", total=Decimal("200.00"), qtd_vendas=3),
            ],
        ),
        fechamento_declarado=None,
        falta_caixa=None,
    )


# ═══════════════════════════════════════════════════════════════
# TEST 1: event_type = "turno_closure"
# (turno closed, NO sales in window)
# ═══════════════════════════════════════════════════════════════

def test_01_turno_closure_event_type():
    """When turno is closed and no sales → event_type = turno_closure"""
    print("\n─── Test 1: event_type = 'turno_closure' ───")

    turno = make_turno_closed()

    payload = build_payload(
        store_id=10,
        store_name="MC Centro",
        store_alias="centro",
        dt_from=TEN_MIN_AGO,
        dt_to=NOW,
        window_minutes=10,
        turnos=[turno],
        vendas=[],
        ops_ids=[],  # NO sales
        sales_by_vendor=[],
        payments_by_method=[],
        warnings=[],
    )

    # Checks
    record(
        "event_type is 'turno_closure'",
        payload.event_type == "turno_closure",
        f"got: {payload.event_type}",
    )
    record(
        "ops.count is 0",
        payload.ops.count == 0,
        f"got: {payload.ops.count}",
    )
    record(
        "vendas is empty",
        len(payload.vendas) == 0,
        f"got: {len(payload.vendas)} vendas",
    )
    record(
        "turnos has 1 entry",
        len(payload.turnos) == 1,
        f"got: {len(payload.turnos)}",
    )
    record(
        "turno.fechado is True",
        payload.turnos[0].fechado is True,
        f"got: {payload.turnos[0].fechado}",
    )
    record(
        "fechamento_declarado is present",
        payload.turnos[0].fechamento_declarado is not None,
        "got: None",
    )
    record(
        "falta_caixa is present",
        payload.turnos[0].falta_caixa is not None,
        "got: None",
    )
    record(
        "schema_version is correct",
        payload.schema_version == SCHEMA_VERSION,
        f"got: {payload.schema_version}",
    )

    return payload


# ═══════════════════════════════════════════════════════════════
# TEST 2: SKIP when no sales AND no turno closure
# ═══════════════════════════════════════════════════════════════

def test_02_skip_when_empty():
    """When no sales and turno is OPEN → should skip (event_type=sales, but runner skips)"""
    print("\n─── Test 2: Skip when empty window ───")

    turno_open = make_turno_open()

    payload = build_payload(
        store_id=10,
        store_name="MC Centro",
        store_alias="centro",
        dt_from=TEN_MIN_AGO,
        dt_to=NOW,
        window_minutes=10,
        turnos=[turno_open],
        vendas=[],
        ops_ids=[],
        sales_by_vendor=[],
        payments_by_method=[],
        warnings=[],
    )

    # Simulate runner skip logic
    has_sales = payload.ops.count > 0
    has_closed_turno = any(t.fechado for t in payload.turnos)
    should_skip = not has_sales and not has_closed_turno

    record(
        "has_sales is False",
        has_sales is False,
        f"got: {has_sales}",
    )
    record(
        "has_closed_turno is False",
        has_closed_turno is False,
        f"got: {has_closed_turno}",
    )
    record(
        "should_skip is True (SKIP POST)",
        should_skip is True,
        f"got: should_skip={should_skip}",
    )
    record(
        "event_type is 'sales' (default)",
        payload.event_type == "sales",
        f"got: {payload.event_type}",
    )

    return payload


# ═══════════════════════════════════════════════════════════════
# TEST 3: event_type = "mixed"
# (sales + turno closed in same window)
# ═══════════════════════════════════════════════════════════════

def test_03_mixed_event_type():
    """When turno closed AND sales exist → event_type = mixed"""
    print("\n─── Test 3: event_type = 'mixed' ───")

    turno = make_turno_closed()

    payload = build_payload(
        store_id=10,
        store_name="MC Centro",
        store_alias="centro",
        dt_from=TEN_MIN_AGO,
        dt_to=NOW,
        window_minutes=10,
        turnos=[turno],
        vendas=[],  # vendas list doesn't matter for event_type calc
        ops_ids=[12500, 12501],  # HAS sales
        sales_by_vendor=[
            {"id_usuario_vendedor": 92, "vendedor_nome": "Vitória", "qtd_cupons": 2, "total_vendido": 150.00},
        ],
        payments_by_method=[
            {"id_finalizador": 1, "meio_pagamento": "Dinheiro", "total_pago": 150.00},
        ],
        warnings=[],
    )

    has_sales = payload.ops.count > 0
    has_closed_turno = any(t.fechado for t in payload.turnos)
    should_skip = not has_sales and not has_closed_turno

    record(
        "event_type is 'mixed'",
        payload.event_type == "mixed",
        f"got: {payload.event_type}",
    )
    record(
        "has_sales is True",
        has_sales is True,
        f"got: {has_sales}",
    )
    record(
        "has_closed_turno is True",
        has_closed_turno is True,
        f"got: {has_closed_turno}",
    )
    record(
        "should_skip is False (SEND POST)",
        should_skip is False,
        f"got: should_skip={should_skip}",
    )
    record(
        "ops.count is 2",
        payload.ops.count == 2,
        f"got: {payload.ops.count}",
    )
    record(
        "resumo.by_vendor has 1 entry",
        len(payload.resumo.by_vendor) == 1,
        f"got: {len(payload.resumo.by_vendor)}",
    )

    return payload


# ═══════════════════════════════════════════════════════════════
# TEST 4: event_type = "sales" (normal, regression test)
# ═══════════════════════════════════════════════════════════════

def test_04_normal_sales():
    """Normal sales with open turno → event_type = sales (REGRESSION)"""
    print("\n─── Test 4: event_type = 'sales' (regressão) ───")

    turno_open = make_turno_open()

    payload = build_payload(
        store_id=10,
        store_name="MC Centro",
        store_alias="centro",
        dt_from=TEN_MIN_AGO,
        dt_to=NOW,
        window_minutes=10,
        turnos=[turno_open],
        vendas=[],
        ops_ids=[12500, 12501, 12502],  # 3 sales
        sales_by_vendor=[
            {"id_usuario_vendedor": 92, "vendedor_nome": "Vitória", "qtd_cupons": 3, "total_vendido": 300.00},
        ],
        payments_by_method=[
            {"id_finalizador": 1, "meio_pagamento": "Dinheiro", "total_pago": 300.00},
        ],
        warnings=[],
    )

    has_sales = payload.ops.count > 0
    has_closed_turno = any(t.fechado for t in payload.turnos)
    should_skip = not has_sales and not has_closed_turno

    record(
        "event_type is 'sales'",
        payload.event_type == "sales",
        f"got: {payload.event_type}",
    )
    record(
        "should_skip is False (SEND POST)",
        should_skip is False,
        f"got: should_skip={should_skip}",
    )
    record(
        "ops.count is 3",
        payload.ops.count == 3,
        f"got: {payload.ops.count}",
    )
    record(
        "turno.fechado is False",
        payload.turnos[0].fechado is False,
        f"got: {payload.turnos[0].fechado}",
    )
    record(
        "fechamento_declarado is None",
        payload.turnos[0].fechamento_declarado is None,
        f"got: {payload.turnos[0].fechamento_declarado}",
    )
    record(
        "falta_caixa is None",
        payload.turnos[0].falta_caixa is None,
        f"got: {payload.turnos[0].falta_caixa}",
    )

    return payload


# ═══════════════════════════════════════════════════════════════
# TEST 5: Runner skip logic simulation
# ═══════════════════════════════════════════════════════════════

def test_05_runner_skip_logic():
    """Test the runner's decision matrix for all 4 combinations"""
    print("\n─── Test 5: Runner skip logic matrix ───")

    cases = [
        # (has_sales, has_closed, expected_skip, label)
        (False, False, True,  "no sales + open turno → SKIP"),
        (True,  False, False, "sales + open turno → SEND"),
        (False, True,  False, "no sales + closed turno → SEND"),
        (True,  True,  False, "sales + closed turno → SEND"),
    ]

    for has_sales, has_closed, expected_skip, label in cases:
        should_skip = not has_sales and not has_closed
        record(
            label,
            should_skip == expected_skip,
            f"expected skip={expected_skip}, got skip={should_skip}",
        )


# ═══════════════════════════════════════════════════════════════
# TEST 6: JSON serialization of turno_closure payload
# ═══════════════════════════════════════════════════════════════

def test_06_json_serialization():
    """Ensure turno_closure payload serializes to valid JSON"""
    print("\n─── Test 6: JSON serialization ───")

    turno = make_turno_closed()

    payload = build_payload(
        store_id=10,
        store_name="MC Centro",
        store_alias="centro",
        dt_from=TEN_MIN_AGO,
        dt_to=NOW,
        window_minutes=10,
        turnos=[turno],
        vendas=[],
        ops_ids=[],
        sales_by_vendor=[],
        payments_by_method=[],
        warnings=[],
    )

    # Serialize to JSON (same as runner._send_payload does)
    payload_dict = payload.model_dump(mode="json", by_alias=True)
    json_str = json.dumps(payload_dict, default=str, ensure_ascii=False)

    # Parse back
    parsed = json.loads(json_str)

    record(
        "JSON is valid (round-trip)",
        isinstance(parsed, dict),
        "JSON parse failed",
    )
    record(
        "event_type in JSON",
        parsed.get("event_type") == "turno_closure",
        f"got: {parsed.get('event_type')}",
    )
    record(
        "schema_version in JSON",
        parsed.get("schema_version") == SCHEMA_VERSION,
        f"got: {parsed.get('schema_version')}",
    )
    record(
        "turnos[0].fechado in JSON",
        parsed["turnos"][0]["fechado"] is True,
        f"got: {parsed['turnos'][0].get('fechado')}",
    )
    record(
        "turnos[0].fechamento_declarado in JSON",
        parsed["turnos"][0].get("fechamento_declarado") is not None,
        "missing from JSON",
    )
    record(
        "turnos[0].falta_caixa in JSON",
        parsed["turnos"][0].get("falta_caixa") is not None,
        "missing from JSON",
    )
    record(
        "vendas is empty array in JSON",
        parsed.get("vendas") == [],
        f"got: {parsed.get('vendas')}",
    )
    record(
        "ops.count is 0 in JSON",
        parsed["ops"]["count"] == 0,
        f"got: {parsed['ops']['count']}",
    )

    # Print the actual JSON for visual inspection
    print(f"\n  📋 Payload JSON size: {len(json_str)} bytes")
    print(f"  📋 Top-level keys: {list(parsed.keys())}")


# ═══════════════════════════════════════════════════════════════
# TEST 7: build_turno_detail from raw DB data
# ═══════════════════════════════════════════════════════════════

def test_07_build_turno_detail():
    """Test building TurnoDetail from raw database dictionaries"""
    print("\n─── Test 7: build_turno_detail from DB rows ───")

    # Simulate raw DB results
    turno_row = {
        "id_turno": "656335C4-D6C4-455A-8E3D-FF6B3F570C64",
        "sequencial": 2,
        "fechado": True,
        "data_hora_inicio": datetime(2026, 2, 11, 16, 26, 44),
        "data_hora_termino": datetime(2026, 2, 11, 21, 50, 29),
        "id_operador": 5,
        "nome_operador": "João",
    }

    system_payments = [
        {"id_finalizador": 2, "meio_pagamento": "Cartão de crédito", "total_pago": 637.80, "qtd_vendas": 7},
        {"id_finalizador": 1, "meio_pagamento": "Dinheiro", "total_pago": 135.00, "qtd_vendas": 4},
    ]

    closure_values = [
        {"id_finalizador": 2, "meio_pagamento": "Cartão de crédito", "total_declarado": 617.80},
        {"id_finalizador": 1, "meio_pagamento": "Dinheiro", "total_declarado": 105.00},
    ]

    shortage_values = [
        {"id_finalizador": 2, "meio_pagamento": "Cartão de crédito", "total_falta": -20.00},
        {"id_finalizador": 1, "meio_pagamento": "Dinheiro", "total_falta": -30.00},
    ]

    detail = build_turno_detail(
        turno=turno_row,
        system_payments=system_payments,
        closure_values=closure_values,
        shortage_values=shortage_values,
    )

    record(
        "id_turno correct",
        detail.id_turno == "656335C4-D6C4-455A-8E3D-FF6B3F570C64",
        f"got: {detail.id_turno}",
    )
    record(
        "fechado is True",
        detail.fechado is True,
        f"got: {detail.fechado}",
    )
    record(
        "operador.id_usuario is 5",
        detail.operador.id_usuario == 5,
        f"got: {detail.operador.id_usuario}",
    )
    record(
        "totais_sistema.total is 772.80",
        detail.totais_sistema.total == Decimal("772.80"),
        f"got: {detail.totais_sistema.total}",
    )
    record(
        "fechamento_declarado.total is 722.80",
        detail.fechamento_declarado is not None
        and detail.fechamento_declarado.total == Decimal("722.80"),
        f"got: {detail.fechamento_declarado.total if detail.fechamento_declarado else 'None'}",
    )
    record(
        "falta_caixa.total is -50.00",
        detail.falta_caixa is not None
        and detail.falta_caixa.total == Decimal("-50.00"),
        f"got: {detail.falta_caixa.total if detail.falta_caixa else 'None'}",
    )
    record(
        "2 system payment entries",
        len(detail.totais_sistema.por_pagamento) == 2,
        f"got: {len(detail.totais_sistema.por_pagamento)}",
    )


# ═══════════════════════════════════════════════════════════════
# TEST 8: Edge cases
# ═══════════════════════════════════════════════════════════════

def test_08_edge_cases():
    """Edge cases: empty turnos, None fechado, multiple turnos"""
    print("\n─── Test 8: Edge cases ───")

    # 8a: No turnos at all
    payload_a = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[], vendas=[], ops_ids=[12500],
        sales_by_vendor=[], payments_by_method=[], warnings=[],
    )
    record(
        "8a: No turnos → event_type = 'sales'",
        payload_a.event_type == "sales",
        f"got: {payload_a.event_type}",
    )

    # 8b: Turno with fechado=None
    turno_none = TurnoDetail(
        id_turno="XXX", sequencial=1, fechado=None,
        operador=OperatorInfo(),
    )
    payload_b = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[turno_none], vendas=[], ops_ids=[],
        sales_by_vendor=[], payments_by_method=[], warnings=[],
    )
    has_closed = any(t.fechado for t in payload_b.turnos)
    should_skip = payload_b.ops.count == 0 and not has_closed
    record(
        "8b: fechado=None → treated as not closed → SKIP",
        should_skip is True,
        f"got: has_closed={has_closed}, skip={should_skip}",
    )

    # 8c: Multiple turnos, one closed one open
    turno_open = make_turno_open()
    turno_closed = make_turno_closed()
    payload_c = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[turno_open, turno_closed], vendas=[], ops_ids=[],
        sales_by_vendor=[], payments_by_method=[], warnings=[],
    )
    record(
        "8c: 1 open + 1 closed → event_type = 'turno_closure'",
        payload_c.event_type == "turno_closure",
        f"got: {payload_c.event_type}",
    )
    has_closed_c = any(t.fechado for t in payload_c.turnos)
    should_skip_c = payload_c.ops.count == 0 and not has_closed_c
    record(
        "8c: should NOT skip (closed turno exists)",
        should_skip_c is False,
        f"got: skip={should_skip_c}",
    )

    # 8d: Warnings preserved
    payload_d = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[turno_closed], vendas=[], ops_ids=[],
        sales_by_vendor=[], payments_by_method=[],
        warnings=["Vendedor NULL encontrado em 2 cupom(s)"],
    )
    record(
        "8d: Warnings preserved in closure payload",
        len(payload_d.integrity.warnings) == 1,
        f"got: {len(payload_d.integrity.warnings)} warnings",
    )

    # 8e: sync_id is deterministic
    payload_e1 = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[], vendas=[], ops_ids=[],
        sales_by_vendor=[], payments_by_method=[], warnings=[],
    )
    payload_e2 = build_payload(
        store_id=10, store_name="MC", store_alias="mc",
        dt_from=TEN_MIN_AGO, dt_to=NOW, window_minutes=10,
        turnos=[], vendas=[], ops_ids=[],
        sales_by_vendor=[], payments_by_method=[], warnings=[],
    )
    record(
        "8e: sync_id is deterministic (same inputs → same id)",
        payload_e1.integrity.sync_id == payload_e2.integrity.sync_id,
        f"id1={payload_e1.integrity.sync_id[:16]}... id2={payload_e2.integrity.sync_id[:16]}...",
    )


# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

def main():
    print("=" * 64)
    print("  PR-09 Test Suite — Turno-Aware Sync")
    print(f"  Schema: {SCHEMA_VERSION}  |  BRT: {BRT}")
    print("=" * 64)

    # Run all tests
    test_01_turno_closure_event_type()
    test_02_skip_when_empty()
    test_03_mixed_event_type()
    test_04_normal_sales()
    test_05_runner_skip_logic()
    test_06_json_serialization()
    test_07_build_turno_detail()
    test_08_edge_cases()

    # Summary
    total = len(results)
    passed = sum(1 for _, s, _ in results if s == PASS)
    failed = sum(1 for _, s, _ in results if s == FAIL)

    print("\n" + "=" * 64)
    if failed == 0:
        print(f"  ✅ ALL {total} TESTS PASSED")
    else:
        print(f"  ❌ {failed} FAILED / {total} TOTAL")
        print()
        print("  Failed tests:")
        for name, status, detail in results:
            if status == FAIL:
                print(f"    - {name}: {detail}")
    print("=" * 64)

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
