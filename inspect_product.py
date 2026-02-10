from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

print("--- Valid Product ---")
# Need a product that has a variation (or join them)
# Assuming table name is 'produto' and 'produto_variacao'
# Or maybe just 'produto' has 'id_variacao'?
# The error mentioned table "dbo.produto_variacao"
# So let's query that.

try:
    query = """
    SELECT TOP 1 id_produto, id_variacao 
    FROM produto_variacao
    """
    rows = db.execute_query(query)
    if rows:
        print(f"Product: {rows[0]}")
    else:
        print("No products found in produto_variacao")
except Exception as e:
    print(f"Error querying produto_variacao: {e}")
