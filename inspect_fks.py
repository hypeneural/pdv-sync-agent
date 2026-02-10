from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

with db.cursor() as cursor:
    print("--- Ponto Venda ---")
    cursor.execute("SELECT TOP 1 id_ponto_venda FROM ponto_venda")
    print(cursor.fetchone())

    print("--- Turno ---")
    cursor.execute("SELECT TOP 1 id_turno FROM turno ORDER BY data_hora_inicio DESC")
    print(cursor.fetchone())

    print("--- Usuario ---")
    cursor.execute("SELECT TOP 1 id_usuario, nome FROM usuario")
    print(cursor.fetchone())

    print("--- Finalizador ---")
    cursor.execute("SELECT TOP 2 id_finalizador, nome FROM finalizador_pdv") # Assuming nome exists, catch if not
    try:
        print(cursor.fetchall())
    except:
        # Fallback to verify column name
        cursor.execute("SELECT TOP 1 * FROM finalizador_pdv")
        print(cursor.description)
