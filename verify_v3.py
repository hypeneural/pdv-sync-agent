from datetime import datetime, timedelta
from src.settings import load_settings
from src.db import create_db_connection, create_gestao_db_connection
from src.queries import create_query_executor
from src.runner import create_runner
import json
import logging

# Configure basic logging
logging.basicConfig(level=logging.INFO)

def verify_v3_payload():
    print("--- Verifying v3.0 Payload with CNPJ and Login ---")
    settings = load_settings()
    
    # Create runner using factory
    runner = create_runner(settings)
    
    # Define a window (last 24 hours to ensure we catch something)
    dt_to = datetime.now()
    dt_from = dt_to - timedelta(days=5) # Look back 5 days to be sure
    
    print(f"Building payload for window: {dt_from} -> {dt_to}")
    
    # Hack: We can't easily call _build_payload directly because it's internal, 
    # but we can duplicate the logic or just modify it temporarily. 
    # Actually, let's just use the components like runner does.
    
    payload = runner._build_payload(dt_from, dt_to)
    
    if not payload:
        print("❌ Failed to build payload (None returned)")
        return

    # Check Store CNPJ
    print(f"\n[STORE] CNPJ: {payload.store.cnpj}")
    if payload.store.cnpj:
        print("✅ CNPJ Found!")
    else:
        print("❌ CNPJ MISSING!")
        
    # Check Operators/Logins
    print(f"\n[TURNOS] Checking for logins...")
    for t in payload.turnos:
        print(f"  - Turno {t.id_turno}: Operador={t.operador.nome} (Login={t.operador.login})")
        if t.operador.login:
            print("    ✅ Turno Operator Login Found!")
        else:
            print("    ⚠️ Turno Operator Login Missing")

    print(f"\n[VENDAS] Checking for vendor logins...")
    found_any_vendor_login = False
    for v in payload.vendas:
        for item in v.itens:
            if item.vendedor:
                print(f"  - Item {item.line_id}: Vendedor={item.vendedor.nome} (Login={item.vendedor.login})")
                if item.vendedor.login:
                    found_any_vendor_login = True
    
    if found_any_vendor_login:
        print("✅ Found at least one sale item with vendor login!")
    else:
        print("⚠️ No sale items with vendor info found (or logins missing).")

    # Serialize to check JSON structure
    json_str = payload.model_dump_json(by_alias=True, indent=2)
    print("\n--- JSON Preview (Head) ---")
    print(json_str[:500])
    
    # Save to file for inspection
    with open("verify_payload_output.json", "w", encoding="utf-8") as f:
        f.write(json_str)
    print("\nFull payload saved to verify_payload_output.json")

if __name__ == "__main__":
    verify_v3_payload()
