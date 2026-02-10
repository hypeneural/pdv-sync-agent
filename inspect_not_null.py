from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

def inspect_not_null(table_name):
    print(f"--- {table_name} (NOT NULL COLUMNS) ---")
    query = f"""
    SELECT COLUMN_NAME, DATA_TYPE 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = '{table_name}' AND IS_NULLABLE = 'NO'
    ORDER BY ORDINAL_POSITION
    """
    results = db.execute_query(query)
    for row in results:
        # exclude identity if we are using identity insert off (which we are)
        # but better to know them all
        print(f"{row['COLUMN_NAME']} ({row['DATA_TYPE']})")

inspect_not_null('operacao_pdv')
inspect_not_null('item_operacao_pdv')
inspect_not_null('finalizador_operacao_pdv')
