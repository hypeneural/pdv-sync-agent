from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

def inspect_table(table_name):
    print(f"\n--- {table_name} ---")
    try:
        query = f"""
        SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
        FROM INFORMATION_SCHEMA.COLUMNS 
        WHERE TABLE_NAME = '{table_name}'
        ORDER BY ORDINAL_POSITION
        """
        results = db.execute_query(query)
        if not results:
            print(f"Table '{table_name}' not found or empty schema.")
            return

        for row in results:
            # Highlight interesting columns
            name = row['COLUMN_NAME'].lower()
            interesting = any(k in name for k in ['cnpj', 'cpf', 'login', 'user', 'nome', 'fantasia', 'id_'])
            marker = "  <--" if interesting else ""
            print(f"{row['COLUMN_NAME']}: {row['DATA_TYPE']} {marker}")
            
    except Exception as e:
        print(f"Error inspecting {table_name}: {e}")

# Check tables relevant for robustness
inspect_table('empresa')
inspect_table('ponto_venda')
inspect_table('usuario')
inspect_table('loja') # Just in case
