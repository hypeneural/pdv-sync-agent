import random
import hashlib
import uuid
from datetime import datetime
from src.settings import load_settings
from src.db import create_db_connection

settings = load_settings()
db = create_db_connection(settings)

ID_PONTO_VENDA = 10
ID_TURNO = '6A91E9F2-FF8C-4E40-BA90-8BF04B889A57'
ID_USUARIO = 1
ID_FINALIZADOR = 1

def seed():
    with db.connect() as conn:
        cursor = conn.cursor()
        print(f"Starting insertions with full schema compliance (v3)...")
        total_sales = 0
        
        for i in range(3):
            val = round(random.uniform(10.0, 100.0), 2)
            now = datetime.now()
            
            # --- 1. Header (operacao_pdv) ---
            # Columns from generate_insert.py detection + logical values
            
            cursor.execute("SELECT ISNULL(MAX(sequencia), 0) + 1 FROM operacao_pdv WHERE id_ponto_venda = ?", (ID_PONTO_VENDA,))
            sequencia = cursor.fetchone()[0]
            cursor.execute("SELECT ISNULL(MAX(coo), 0) + 1 FROM operacao_pdv WHERE id_ponto_venda = ?", (ID_PONTO_VENDA,))
            coo = cursor.fetchone()[0]
            
            guid_op = str(uuid.uuid4())
            dummy_hash = hashlib.md5(str(now).encode()).hexdigest()

            cursor.execute("""
                INSERT INTO operacao_pdv (
                    id_usuario, id_ponto_venda, id_turno,
                    data_movimento, data_hora_inicio, data_hora_termino,
                    sequencia, coo, valor_ajuste, operacao, cancelado, 
                    valor_desconto_subtotal, sync, 
                    modelo_ecf, numero_fabricacao_ecf, mf_adicional, tipo_ecf, marca_ecf, 
                    ccf, data_hora_inicio_ecf, numero_proprietario_ecf, 
                    hash_md5, hash_md5_paf_ecf, numero_sequencial_ecf, versao_software_ecf, 
                    digest_value_autorizacao_nfce, motivo_contingencia_nfce, guid_operacao
                ) 
                OUTPUT INSERTED.id_operacao
                VALUES (
                    ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, 0, 1, 0,
                    0, 0, 
                    '2D', 'BE090910100000030997', ' ', 'ECF-IF', 'Bematech',
                    ?, ?, '1',
                    ?, ?, ?, '01.00.00',
                    '', '', ?
                )
            """, (
                ID_USUARIO, ID_PONTO_VENDA, ID_TURNO,
                now, now, now,
                sequencia, coo,
                coo, now, # ccf=coo, data_hora_ecf=now
                dummy_hash, dummy_hash, coo, # numero_sequencial_ecf=coo
                guid_op
            ))
            
            row = cursor.fetchone()
            op_id = row[0]

            # --- 2. Item (item_operacao_pdv) ---
            # Columns from generate_insert.py
            
            cursor.execute("""
                INSERT INTO item_operacao_pdv (
                    id_operacao, id_produto, id_variacao, codigo_barras, 
                    id_situacao_tributaria_icms, quantidade_secundaria, quantidade_primaria, 
                    valor_unitario_bruto, valor_total_liquido, cancelado, 
                    string_ecf, valor_desconto, valor_acrescimo, aliquota_icms, preco_custo, 
                    id_produto_original, id_variacao_original, item, valor_ajuste, 
                    codigo_totalizador_imposto_ecf, hash_md5, numero_serie, sequencia_kit_operacao, observacao,
                    id_usuario_vendedor
                ) VALUES (
                    ?, 1, 1, 'ALL999', 
                    0, 0, 1, 
                    ?, ?, 0, 
                    'FF', 0, 0, 0, 0, 
                    1, 1, 1, 0, 
                    '01T1700', ?, 'BE090910100000030997', 0, '',
                    ?
                )
            """, (op_id, val, val, dummy_hash, ID_USUARIO))

            # --- 3. Payment (finalizador_operacao_pdv) ---
            # Columns from generate_insert.py
            
            cursor.execute("""
                INSERT INTO finalizador_operacao_pdv (
                    id_operacao, id_finalizador, parcela, valor, 
                    data_vencimento, hash_md5, valor_acrescimo_financeiro
                ) VALUES (
                    ?, ?, 1, ?, 
                    ?, ?, 0
                )
            """, (op_id, ID_FINALIZADOR, val, now, dummy_hash))
            
            total_sales += val
            print(f"Inserted Sale #{i+1}: ID={op_id} Val={val} Vendor={ID_USUARIO}")
            
        conn.commit()
        print(f"Successfully inserted 3 sales. Total Value: {total_sales:.2f}")

if __name__ == "__main__":
    seed()
