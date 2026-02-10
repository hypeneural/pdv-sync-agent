from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

def get_defaults(data_type):
    dt = data_type.lower()
    if 'int' in dt or 'decimal' in dt or 'numeric' in dt or 'bit' in dt:
        return '0'
    elif 'char' in dt or 'text' in dt:
        return "''"
    elif 'date' in dt or 'time' in dt:
        return "getdate()"
    elif 'uniqueidentifier' in dt:
        return "newid()"
    return "NULL"

def generate_insert(table_name):
    print(f"--- Generating INSERT for {table_name} ---")
    query = f"""
    SELECT COLUMN_NAME, DATA_TYPE, COLUMN_DEFAULT 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = ? AND IS_NULLABLE = 'NO' 
      AND COLUMNPROPERTY(object_id(TABLE_NAME), COLUMN_NAME, 'IsIdentity') = 0
      AND COLUMN_DEFAULT IS NULL
    ORDER BY ORDINAL_POSITION
    """
    results = db.execute_query(query, (table_name,))
    
    cols = []
    vals = []
    
    for row in results:
        col = row['COLUMN_NAME']
        default_val = row['COLUMN_DEFAULT']
        
        cols.append(col)
        
        if default_val:
            vals.append("DEFAULT") # Or the actual default if we could parse it, but DEFAULT keyword works in VALUES? No.
            # actually we can just omit it if it has a default?
            # But the previous errors showed columns that likely DON'T have defaults.
            # So I will use my defaults.
            vals.append(get_defaults(row['DATA_TYPE']))
        else:
            vals.append(get_defaults(row['DATA_TYPE']))

    print(f"INSERT INTO {table_name} ({', '.join(cols)}) VALUES ({', '.join(vals)})")

generate_insert('item_operacao_pdv')
generate_insert('finalizador_operacao_pdv')
