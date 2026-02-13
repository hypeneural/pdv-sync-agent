"""Regenerate JSON schema from SyncPayload model."""
import sys, types, json

# Mock pyodbc to avoid driver dependency
mod = types.ModuleType('pyodbc')
mod.Connection = type('Connection', (), {})
mod.Error = Exception
sys.modules['pyodbc'] = mod

sys.path.insert(0, '.')
from src.payload import SyncPayload

schema = SyncPayload.model_json_schema()
with open('docs/schema_v2.0.json', 'w', encoding='utf-8') as f:
    json.dump(schema, f, indent=2, ensure_ascii=False)

print(f"OK: {len(json.dumps(schema))} bytes written to docs/schema_v2.0.json")
