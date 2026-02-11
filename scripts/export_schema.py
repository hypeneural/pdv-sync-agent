"""
Export JSON Schema from Pydantic SyncPayload model.
Usage: python scripts/export_schema.py [output_path]
"""

import json
import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from src import SCHEMA_VERSION
from src.payload import SyncPayload


def export_schema(output_path: str | None = None) -> None:
    """Generate and save JSON Schema from SyncPayload."""
    schema = SyncPayload.model_json_schema()

    # Add metadata
    schema["$id"] = f"https://maiscapinhas.com/schemas/pdv-sync/v{SCHEMA_VERSION}"
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"

    if output_path is None:
        docs_dir = Path(__file__).resolve().parent.parent / "docs"
        docs_dir.mkdir(exist_ok=True)
        output_path = str(docs_dir / f"schema_v{SCHEMA_VERSION}.json")

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(schema, f, indent=2, ensure_ascii=False)

    print(f"Schema exported to: {output_path}")
    print(f"Schema version: {SCHEMA_VERSION}")
    print(f"Definitions: {len(schema.get('$defs', {}))}")


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else None
    export_schema(path)
