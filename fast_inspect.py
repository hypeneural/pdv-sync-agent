import pyodbc

conn_str = (
    "DRIVER={ODBC Driver 17 for SQL Server};"
    "SERVER=DESKTOP-EGBRLLG\\HIPER;"
    "DATABASE=HiperPdv;"
    "Trusted_Connection=yes;"
    "Encrypt=no;"
    "TrustServerCertificate=yes;"
)

def inspect_table(cursor, table_name):
    print(f"\n=== {table_name} ===")
    try:
        cursor.execute(f"SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '{table_name}' ORDER BY COLUMN_NAME")
        rows = cursor.fetchall()
        if not rows:
            print("Table not found.")
            return
        for row in rows:
            name = row.COLUMN_NAME.lower()
            if any(k in name for k in ['cnpj', 'cpf', 'login', 'user', 'nome', 'id_']):
                print(f"{row.COLUMN_NAME}: {row.DATA_TYPE}")
    except Exception as e:
        print(f"Error: {e}")

try:
    print("Connecting...")
    conn = pyodbc.connect(conn_str, timeout=10)
    cursor = conn.cursor()
    print("Connected!")
    
    inspect_table(cursor, 'empresa')
    inspect_table(cursor, 'ponto_venda')
    inspect_table(cursor, 'usuario')
    inspect_table(cursor, 'loja')

    conn.close()
except Exception as e:
    print(f"Connection failed: {e}")
