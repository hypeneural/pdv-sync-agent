from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

print("Checking table access...")
try:
    count = db.execute_scalar("SELECT COUNT(*) FROM operacao_pdv WITH (NOLOCK)")
    print(f"Table row count (read uncommitted): {count}")
    
    count_locked = db.execute_scalar("SELECT COUNT(*) FROM operacao_pdv") # Will block if locked
    print(f"Table row count (read committed): {count_locked}")
except Exception as e:
    print(f"Error accessing table: {e}")
