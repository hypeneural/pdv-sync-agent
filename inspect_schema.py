from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

def inspect_table(table_name):
    print(f"--- {table_name} ---")
    query = f"""
    SELECT COLUMN_NAME, IS_NULLABLE, DATA_TYPE 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = '{table_name}'
    ORDER BY ORDINAL_POSITION
    """
    results = db.execute_query(query)
    for row in results:
        print(f"{row['COLUMN_NAME']}: {row['IS_NULLABLE']} ({row['DATA_TYPE']})")

inspect_table('operacao_pdv')
inspect_table('item_operacao_pdv')
inspect_table('finalizador_operacao_pdv')
