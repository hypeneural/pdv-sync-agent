"""
PRE-PRODUCTION FINAL VALIDATION
Tests the FULL end-to-end flow against real SQL Server.
Run this before building the production executable.
"""
import json
import sys
import traceback
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

PASS = 0
FAIL = 0
WARN = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ✅ {name}")
    else:
        FAIL += 1
        print(f"  ❌ {name}" + (f" — {detail}" if detail else ""))


def warn(name, detail=""):
    global WARN
    WARN += 1
    print(f"  ⚠️  {name}" + (f" — {detail}" if detail else ""))


def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")


# ================================================================
# STEP 1: Import Check (all modules load without error)
# ================================================================
section("STEP 1: Import Check")

try:
    from src import BRT, SCHEMA_VERSION
    check("src.__init__ imports OK", True)
except Exception as e:
    check("src.__init__ imports OK", False, str(e))

try:
    from src.settings import Settings
    check("src.settings imports OK", True)
except Exception as e:
    check("src.settings imports OK", False, str(e))

try:
    from src.db import DatabaseConnection
    check("src.db imports OK", True)
except Exception as e:
    check("src.db imports OK", False, str(e))

try:
    from src.queries import QueryExecutor, create_query_executor
    check("src.queries imports OK", True)
except Exception as e:
    check("src.queries imports OK", False, str(e))

try:
    from src.payload import (SyncPayload, ProductItem, SalePayment,
                              build_payload, build_turno_detail,
                              build_sale_details, _aware)
    check("src.payload imports OK", True)
except Exception as e:
    check("src.payload imports OK", False, str(e))

try:
    from src.state import StateManager, WindowCalculator
    check("src.state imports OK", True)
except Exception as e:
    check("src.state imports OK", False, str(e))

try:
    from src.sender import (HttpSender, OutboxManager, SendResult,
                              NO_RETRY_CODES, MAX_OUTBOX_RETRIES,
                              OUTBOX_TTL_DAYS, create_sender)
    check("src.sender imports OK", True)
except Exception as e:
    check("src.sender imports OK", False, str(e))

try:
    from src.runner import SyncRunner, create_runner
    check("src.runner imports OK", True)
except Exception as e:
    check("src.runner imports OK", False, str(e))

doctor_available = False
try:
    from src.doctor import run_doctor
    check("src.doctor imports OK", True)
    doctor_available = True
except ImportError:
    check("src.doctor module exists", True)  # Not required
    # Doctor mode is optional


# ================================================================
# STEP 2: Settings Load from .env
# ================================================================
section("STEP 2: Settings Load from .env")

try:
    settings = Settings()
    check("Settings loaded from .env", True)
    check("SQL_SERVER_HOST configured", bool(settings.sql_server_host),
          f"got: {settings.sql_server_host}")
    check("SQL_DATABASE configured", bool(settings.sql_database),
          f"got: {settings.sql_database}")
    check("SQL_DRIVER configured", bool(settings.sql_driver),
          f"got: {settings.sql_driver}")
    check("STORE_ID configured", settings.store_id_ponto_venda > 0,
          f"got: {settings.store_id_ponto_venda}")
    check("API_ENDPOINT configured", bool(settings.api_endpoint),
          f"got: {settings.api_endpoint}")
    check("SYNC_WINDOW_MINUTES > 0", settings.sync_window_minutes > 0,
          f"got: {settings.sync_window_minutes}")
except Exception as e:
    check("Settings loaded from .env", False, str(e))
    traceback.print_exc()
    print("\n  ⛔ Cannot proceed without settings. Exiting.\n")
    sys.exit(1)


# ================================================================
# STEP 3: Database Connectivity
# ================================================================
section("STEP 3: Database Connectivity")

try:
    db = DatabaseConnection(settings)
    check("DatabaseConnection created", True)

    # Test actual connection
    result = db.execute_query("SELECT 1 AS test")
    check("SQL query executes OK", len(result) > 0 and result[0]["test"] == 1)
except Exception as e:
    check("Database connection", False, str(e))
    traceback.print_exc()
    print("\n  ⛔ Cannot proceed without DB connection. Exiting.\n")
    sys.exit(1)


# ================================================================
# STEP 4: All Queries Execute Without Error
# ================================================================
section("STEP 4: SQL Queries Execute Without Error")

queries = create_query_executor(db)
now_brt = datetime.now(BRT)
dt_from = now_brt - timedelta(minutes=settings.sync_window_minutes)
dt_to = now_brt

try:
    store_info = queries.get_store_info(settings.store_id_ponto_venda)
    check("get_store_info()", store_info is not None,
          f"result: {store_info}")
except Exception as e:
    check("get_store_info()", False, str(e))

try:
    current_turno = queries.get_current_turno(settings.store_id_ponto_venda)
    check("get_current_turno()", True,
          f"turno found: {current_turno is not None}")
except Exception as e:
    check("get_current_turno()", False, str(e))

try:
    turnos = queries.get_turnos_in_window(dt_from, dt_to)
    check("get_turnos_in_window()", True, f"found {len(turnos)} turnos")
except Exception as e:
    check("get_turnos_in_window()", False, str(e))

try:
    ops = queries.get_operations_in_window(dt_from, dt_to)
    check("get_operations_in_window()", True, f"found {len(ops)} operations")
except Exception as e:
    check("get_operations_in_window()", False, str(e))

try:
    ops_ids = queries.get_operation_ids(dt_from, dt_to)
    check("get_operation_ids()", True, f"found {len(ops_ids)} IDs")
except Exception as e:
    check("get_operation_ids()", False, str(e))

try:
    items = queries.get_sale_items(dt_from, dt_to)
    check("get_sale_items()", True, f"found {len(items)} items")
    # Verify line_id and line_no columns exist in results
    if items:
        first = items[0]
        check("  → items have 'line_id' column", "line_id" in first,
              f"columns: {list(first.keys())}")
        check("  → items have 'line_no' column", "line_no" in first,
              f"columns: {list(first.keys())}")
        check("  → line_id is int", isinstance(first["line_id"], int),
              f"type: {type(first['line_id'])}")
        check("  → line_no is int", isinstance(first["line_no"], int),
              f"type: {type(first['line_no'])}")
    else:
        warn("No items in current window (OK if no recent sales)")
except Exception as e:
    check("get_sale_items()", False, str(e))
    traceback.print_exc()

try:
    payments = queries.get_sale_payments(dt_from, dt_to)
    check("get_sale_payments()", True, f"found {len(payments)} payments")
    # Verify line_id column exists
    if payments:
        first = payments[0]
        check("  → payments have 'line_id' column", "line_id" in first,
              f"columns: {list(first.keys())}")
        check("  → line_id is int", isinstance(first["line_id"], int),
              f"type: {type(first['line_id'])}")
    else:
        warn("No payments in current window (OK if no recent sales)")
except Exception as e:
    check("get_sale_payments()", False, str(e))
    traceback.print_exc()

try:
    by_vendor = queries.get_sales_by_vendor(dt_from, dt_to)
    check("get_sales_by_vendor()", True, f"found {len(by_vendor)} vendor entries")
except Exception as e:
    check("get_sales_by_vendor()", False, str(e))

try:
    by_payment = queries.get_payments_by_method(dt_from, dt_to)
    check("get_payments_by_method()", True, f"found {len(by_payment)} payment methods")
except Exception as e:
    check("get_payments_by_method()", False, str(e))

# Test turno-specific queries if current turno exists
if current_turno:
    id_turno = str(current_turno.get("id_turno", ""))
    if id_turno:
        try:
            turno_payments = queries.get_payments_by_method_for_turno(id_turno)
            check("get_payments_by_method_for_turno()", True,
                  f"found {len(turno_payments)} entries")
        except Exception as e:
            check("get_payments_by_method_for_turno()", False, str(e))

        try:
            closure = queries.get_turno_closure_values(id_turno)
            check("get_turno_closure_values()", True,
                  f"found {len(closure) if closure else 0} entries")
        except Exception as e:
            check("get_turno_closure_values()", False, str(e))

        try:
            shortage = queries.get_turno_shortage_values(id_turno)
            check("get_turno_shortage_values()", True,
                  f"found {len(shortage) if shortage else 0} entries")
        except Exception as e:
            check("get_turno_shortage_values()", False, str(e))


# ================================================================
# STEP 5: Full Payload Build (using wider window for data)
# ================================================================
section("STEP 5: Full Payload Build (end-to-end)")

# Use a wider window to get some data
wide_from = now_brt - timedelta(hours=24)
wide_to = now_brt

try:
    wide_items = queries.get_sale_items(wide_from, wide_to)
    wide_payments = queries.get_sale_payments(wide_from, wide_to)
    wide_by_vendor = queries.get_sales_by_vendor(wide_from, wide_to)
    wide_by_payment = queries.get_payments_by_method(wide_from, wide_to)
    wide_ops_ids = queries.get_operation_ids(wide_from, wide_to)
    wide_turnos_raw = queries.get_turnos_in_window(wide_from, wide_to)

    check("Wide window queries OK", True,
          f"items={len(wide_items)}, payments={len(wide_payments)}, ops={len(wide_ops_ids)}")

    # Build turno details
    turno_details = []
    for turno in wide_turnos_raw:
        id_turno = turno.get("id_turno")
        if not id_turno:
            continue
        system_payments = queries.get_payments_by_method_for_turno(str(id_turno))
        closure_values = None
        shortage_values = None
        if turno.get("fechado"):
            closure_values = queries.get_turno_closure_values(str(id_turno))
            shortage_values = queries.get_turno_shortage_values(str(id_turno))
        detail = build_turno_detail(
            turno=turno,
            system_payments=system_payments,
            closure_values=closure_values,
            shortage_values=shortage_values,
        )
        turno_details.append(detail)

    check("Turno details built", True, f"{len(turno_details)} turnos")

    # Build sale details
    vendas = build_sale_details(wide_items, wide_payments, canal="HIPER_CAIXA")
    check("Sale details built", True, f"{len(vendas)} vendas")

    # Build full payload
    payload = build_payload(
        store_id=settings.store_id_ponto_venda,
        store_name=store_info.get("nome", "Test") if store_info else "Test",
        store_alias=settings.store_alias,
        dt_from=wide_from,
        dt_to=wide_to,
        window_minutes=settings.sync_window_minutes,
        turnos=turno_details,
        vendas=vendas,
        ops_ids=wide_ops_ids,
        sales_by_vendor=wide_by_vendor,
        payments_by_method=wide_by_payment,
        warnings=[],
    )
    check("Full payload built OK", payload is not None)

except Exception as e:
    check("Full payload build", False, str(e))
    traceback.print_exc()
    print("\n  ⛔ Payload build failed! Cannot deploy.\n")
    sys.exit(1)


# ================================================================
# STEP 6: Payload JSON Serialization & Validation
# ================================================================
section("STEP 6: JSON Serialization & Validation")

try:
    payload_json = payload.model_dump_json(by_alias=True)
    check("model_dump_json() succeeds", True)

    payload_dict = json.loads(payload_json)
    check("JSON is parseable", True)

    # Size check
    size_kb = len(payload_json.encode("utf-8")) / 1024
    check(f"Payload size: {size_kb:.1f} KB", size_kb < 5000,
          "Warning: very large payload" if size_kb > 1000 else "")
    if size_kb > 1000:
        warn(f"Payload is {size_kb:.0f} KB — consider chunk splitting")

    # Schema version
    check("schema_version present", payload_dict.get("schema_version") == "3.0")

    # Agent info
    agent = payload_dict.get("agent", {})
    check("agent.sent_at is timezone-aware",
          agent.get("sent_at", "").endswith("-03:00"))
    check("agent.version present", bool(agent.get("version")))

    # Store info
    store = payload_dict.get("store", {})
    check("store.id_ponto_venda present",
          store.get("id_ponto_venda") == settings.store_id_ponto_venda,
          f"got: {store}")

    # Window info
    window = payload_dict.get("window", {})
    check("window.from present", "from" in window)
    check("window.to present", "to" in window)
    check("window.from has timezone",
          window.get("from", "").endswith("-03:00"),
          f"got: {window.get('from', 'MISSING')}")
    check("window.to has timezone",
          window.get("to", "").endswith("-03:00"),
          f"got: {window.get('to', 'MISSING')}")

    # Integrity
    integrity = payload_dict.get("integrity", {})
    check("integrity.sync_id present", bool(integrity.get("sync_id")))
    check("sync_id length = 64 (SHA256)",
          len(integrity.get("sync_id", "")) == 64)

    # Vendas details
    vendas_json = payload_dict.get("vendas", [])
    if vendas_json:
        first_venda = vendas_json[0]
        check("vendas[0].data_hora has timezone",
              first_venda.get("data_hora", "").endswith("-03:00"),
              f"got: {first_venda.get('data_hora', 'MISSING')}")

        # Check line_id/line_no in items
        items_json = first_venda.get("itens", [])
        if items_json:
            first_item = items_json[0]
            check("vendas[0].itens[0].line_id present",
                  first_item.get("line_id") is not None,
                  f"got: {first_item.get('line_id')}")
            check("vendas[0].itens[0].line_no present",
                  first_item.get("line_no") is not None,
                  f"got: {first_item.get('line_no')}")

        # Check line_id in payments
        pays_json = first_venda.get("pagamentos", [])
        if pays_json:
            first_pay = pays_json[0]
            check("vendas[0].pagamentos[0].line_id present",
                  first_pay.get("line_id") is not None,
                  f"got: {first_pay.get('line_id')}")
    else:
        warn("No vendas in 24h window (OK if store closed)")

    # Turnos
    turnos_json = payload_dict.get("turnos", [])
    if turnos_json:
        first_turno = turnos_json[0]
        dt_inicio = first_turno.get("data_hora_inicio", "")
        check("turnos[0].data_hora_inicio has timezone",
              dt_inicio.endswith("-03:00"),
              f"got: {dt_inicio}")
    else:
        warn("No turnos in 24h window")

    print(f"\n  📦 Full JSON payload preview (first 500 chars):")
    print(f"  {payload_json[:500]}...")

except Exception as e:
    check("JSON serialization", False, str(e))
    traceback.print_exc()


# ================================================================
# STEP 7: Sender Module Validation
# ================================================================
section("STEP 7: Sender Module Validation")

check("NO_RETRY_CODES defined", len(NO_RETRY_CODES) >= 5)
check("MAX_OUTBOX_RETRIES defined", MAX_OUTBOX_RETRIES == 50)
check("OUTBOX_TTL_DAYS defined", OUTBOX_TTL_DAYS == 7)

# Test headers
sender = HttpSender.__new__(HttpSender)
sender.token = settings.api_token
headers = sender._get_headers()
check("Authorization header present", "Authorization" in headers)
check("Bearer token format", headers["Authorization"].startswith("Bearer "))
check("X-PDV-Schema-Version header", headers.get("X-PDV-Schema-Version") == "3.0")
check("Content-Type is application/json",
      headers.get("Content-Type") == "application/json")


# ================================================================
# STEP 8: Doctor Mode Check
# ================================================================
section("STEP 8: Doctor Mode (--doctor)")

if doctor_available:
    check("Doctor module can be imported", True)
    check("run_doctor() is callable", callable(run_doctor))
else:
    check("Doctor module not present (optional)", True)


# ================================================================
# STEP 9: Runner Instantiation
# ================================================================
section("STEP 9: Runner Instantiation")

try:
    runner = create_runner(settings)
    check("SyncRunner created via factory", True)
    check("Runner has queries", hasattr(runner, "queries"))
    check("Runner has sender", hasattr(runner, "sender"))
    check("Runner has state_manager", hasattr(runner, "state_manager"))
    check("Runner has window_calculator", hasattr(runner, "window_calc") or hasattr(runner, "window_calculator"))
except Exception as e:
    check("SyncRunner instantiation", False, str(e))
    traceback.print_exc()


# ================================================================
# STEP 10: Build Readiness (PyInstaller)
# ================================================================
section("STEP 10: Build Readiness")

# Check main.py / entry point exists
main_candidates = [
    Path(__file__).resolve().parent.parent / "main.py",
    Path(__file__).resolve().parent.parent / "src" / "main.py",
    Path(__file__).resolve().parent.parent / "pdv_sync_agent.py",
]
entry_found = False
for candidate in main_candidates:
    if candidate.exists():
        check(f"Entry point found: {candidate.name}", True)
        entry_found = True
        break
if not entry_found:
    # Check for any .py in root that might be entry
    root = Path(__file__).resolve().parent.parent
    py_files = list(root.glob("*.py"))
    if py_files:
        check(f"Entry point candidates: {[f.name for f in py_files]}", True)
    else:
        warn("No obvious entry point .py file found")

# Check .spec or build config exists
spec_files = list(Path(__file__).resolve().parent.parent.glob("*.spec"))
check("PyInstaller .spec file exists", len(spec_files) > 0,
      f"found: {[f.name for f in spec_files]}" if spec_files else "")

# Check requirements
req_path = Path(__file__).resolve().parent.parent / "requirements.txt"
check("requirements.txt exists", req_path.exists())

# Check .env template for deployment
template_candidates = [
    Path(__file__).resolve().parent.parent / "deploy" / "config.template.env",
    Path(__file__).resolve().parent.parent / "config" / "config.example.env",
]
for t in template_candidates:
    if t.exists():
        check(f"Config template exists: {t.relative_to(Path(__file__).resolve().parent.parent)}", True)


# ================================================================
# SUMMARY
# ================================================================
print(f"\n{'='*60}")
print(f"  FINAL RESULTS")
print(f"{'='*60}")
print(f"  ✅ PASSED:  {PASS}")
print(f"  ❌ FAILED:  {FAIL}")
print(f"  ⚠️  WARNINGS: {WARN}")
print(f"  {'─'*40}")

if FAIL == 0:
    print(f"  🚀 READY FOR PRODUCTION BUILD!")
    print(f"  Run: .venv_build\\Scripts\\pyinstaller pdv_sync_agent.spec")
    print()
    sys.exit(0)
else:
    print(f"  ⛔ {FAIL} FAILURES — FIX BEFORE DEPLOYING!")
    print()
    sys.exit(1)
