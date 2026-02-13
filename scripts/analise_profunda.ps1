# =============================================================
#  ANALISE PROFUNDA - Hiper (Gestão/Loja)
#  Vendas, operadores, vendedores, pagamentos, campos
# =============================================================
$server = ".\HIPER"
$dbG = "Hiper"
$dbP = "HiperPdv"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ANALISE PROFUNDA - Banco Hiper (Gestao/Loja)" -ForegroundColor Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ===== 1. COLUNAS operacao_pdv NO HIPER GESTAO =====
Write-Host "`n========== 1. COLUNAS operacao_pdv (Gestao) ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo, c.max_length AS tam
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.operacao_pdv')
ORDER BY c.column_id" -W

# ===== 2. COLUNAS item_operacao_pdv NO HIPER GESTAO =====
Write-Host "`n========== 2. COLUNAS item_operacao_pdv (Gestao) ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo, c.max_length AS tam
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.item_operacao_pdv')
ORDER BY c.column_id" -W

# ===== 3. COLUNAS finalizador_operacao_pdv NO HIPER GESTAO =====
Write-Host "`n========== 3. COLUNAS finalizador_operacao_pdv (Gestao) ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo, c.max_length AS tam
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.finalizador_operacao_pdv')
ORDER BY c.column_id" -W

# ===== 4. TABELA DE FINALIZADORES (meios de pagamento) =====
Write-Host "`n========== 4. MEIOS DE PAGAMENTO - Onde esta a descricao? ==========" -ForegroundColor Green
# Procurar tabela de meios de pagamento
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT t.name FROM sys.tables t
WHERE t.name LIKE '%finalizador%' AND t.name NOT LIKE '%operacao%'
ORDER BY t.name" -W

# Tentar finalizador_pdv_ponto_venda (existe no HiperPdv)
Write-Host "  --- finalizador_pdv_ponto_venda (HiperPdv) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.finalizador_pdv_ponto_venda')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT TOP 20 * FROM dbo.finalizador_pdv_ponto_venda ORDER BY id_finalizador" -W 2>$null

# ===== 5. ULTIMAS 10 VENDAS GESTAO - DETALHADO =====
Write-Host "`n========== 5. ULTIMAS 10 VENDAS - Hiper Gestao (completo) ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 10
    op.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    op.operacao AS tipo_op,
    op.cancelado,
    op.id_turno,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS qtd_itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total_itens
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
" -W

# ===== 6. VENDA R$6,60 - DETALHES (a que nao replicou) =====
Write-Host "`n========== 6. VENDA R$6,60 (id=9799) - Itens e Pagamentos ==========" -ForegroundColor Red
Write-Host "  --- Itens ---" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    i.id_item_operacao_pdv, i.id_produto, p.nome AS produto,
    i.quantidade_primaria AS qtd, i.valor_unitario_liquido AS preco,
    i.valor_total_liquido AS total, i.valor_desconto AS desc,
    i.id_usuario_vendedor,
    (SELECT u.nome FROM dbo.usuario u WHERE u.id_usuario = i.id_usuario_vendedor) AS vendedor
FROM dbo.item_operacao_pdv i
JOIN dbo.produto p ON p.id_produto = i.id_produto
WHERE i.id_operacao = 9799 AND i.cancelado = 0
ORDER BY i.item" -W

Write-Host "  --- Pagamentos ---" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    f.id_finalizador, f.valor, f.valor_troco AS troco,
    (f.valor - f.valor_troco) AS liquido, f.parcela, f.documento
FROM dbo.finalizador_operacao_pdv f
WHERE f.id_operacao = 9799
" -W

Write-Host "  --- Operacao completa ---" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT * FROM dbo.operacao_pdv WHERE id_operacao = 9799" -W

# ===== 7. OPERADORES vs VENDEDORES - QUEM OPERA E QUEM VENDE =====
Write-Host "`n========== 7. OPERADORES (quem abre turno) - ultimos 7 dias ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    t.id_usuario, u.nome AS operador, u.login,
    COUNT(*) AS turnos_abertos,
    MIN(CONVERT(VARCHAR(19), t.data_hora_inicio, 120)) AS primeiro_turno,
    MAX(CONVERT(VARCHAR(19), t.data_hora_inicio, 120)) AS ultimo_turno
FROM dbo.turno t
JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
WHERE t.data_hora_inicio >= DATEADD(DAY, -7, GETDATE())
GROUP BY t.id_usuario, u.nome, u.login
ORDER BY turnos_abertos DESC
" -W

Write-Host "`n========== 7b. VENDEDORES (quem vende itens) - ultimos 7 dias ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    i.id_usuario_vendedor, u.nome AS vendedor,
    COUNT(DISTINCT i.id_operacao) AS qtd_vendas,
    COUNT(*) AS qtd_itens,
    SUM(i.valor_total_liquido) AS total_vendido
FROM dbo.item_operacao_pdv i
JOIN dbo.operacao_pdv op ON op.id_operacao = i.id_operacao
JOIN dbo.usuario u ON u.id_usuario = i.id_usuario_vendedor
WHERE op.operacao = 1 AND op.cancelado = 0 AND i.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY i.id_usuario_vendedor, u.nome
ORDER BY total_vendido DESC
" -W

# ===== 8. MEIOS DE PAGAMENTO USADOS - ultimos 7 dias =====
Write-Host "`n========== 8. MEIOS DE PAGAMENTO - ultimos 7 dias (Gestao) ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    f.id_finalizador,
    COUNT(*) AS vezes_usado,
    SUM(f.valor) AS total_bruto,
    SUM(f.valor_troco) AS total_troco,
    SUM(f.valor - f.valor_troco) AS total_liquido
FROM dbo.finalizador_operacao_pdv f
JOIN dbo.operacao_pdv op ON op.id_operacao = f.id_operacao
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY f.id_finalizador
ORDER BY total_liquido DESC
" -W

Write-Host "`n========== 8b. MEIOS DE PAGAMENTO - ultimos 7 dias (HiperPdv) ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT
    f.id_finalizador,
    COUNT(*) AS vezes_usado,
    SUM(f.valor) AS total_bruto,
    SUM(f.valor_troco) AS total_troco,
    SUM(f.valor - f.valor_troco) AS total_liquido
FROM dbo.finalizador_operacao_pdv f
JOIN dbo.operacao_pdv op ON op.id_operacao = f.id_operacao
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY f.id_finalizador
ORDER BY total_liquido DESC
" -W

# ===== 9. TABELA filial ou loja no Hiper Gestao =====
Write-Host "`n========== 9. TABELA DE LOJAS no Hiper Gestao ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT t.name FROM sys.tables t
WHERE t.name LIKE '%filial%' OR t.name LIKE '%loja%' OR t.name LIKE '%ponto%' OR t.name LIKE '%estabelecimento%'
ORDER BY t.name" -W

# Provavelmente é 'filial'
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
IF OBJECT_ID('dbo.filial') IS NOT NULL
BEGIN
    SELECT c.name AS coluna, t.name AS tipo
    FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('dbo.filial')
    ORDER BY c.column_id
END" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
IF OBJECT_ID('dbo.filial') IS NOT NULL
    SELECT * FROM dbo.filial" -W 2>$null

# ===== 10. SYNC - Ultimo protocolo de sincronizacao =====
Write-Host "`n========== 10. SYNC - Status da sincronizacao ==========" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5
    c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.hiperloja_sync_protocolo_sincronizacao')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 10 *
FROM dbo.hiperloja_sync_protocolo_sincronizacao
ORDER BY 1 DESC" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5
    c.name AS coluna
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.hiperloja_sync_config')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT * FROM dbo.hiperloja_sync_config" -W 2>$null

# ===== 11. VENDAS HIPER LOJA (pedido_venda) - Ultimos 10 =====
Write-Host "`n========== 11. PEDIDOS VENDA Hiper Loja - Ultimos 10 ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 10
    pv.id_pedido_venda,
    CONVERT(VARCHAR(19), pv.data_hora_geracao, 120) AS data_hora,
    pv.id_filial_venda AS filial,
    pv.situacao,
    pv.operacao,
    pv.id_usuario_vendedor,
    (SELECT u.nome FROM dbo.usuario u WHERE u.id_usuario = pv.id_usuario_vendedor) AS vendedor,
    pv.id_usuario_geracao,
    (SELECT u.nome FROM dbo.usuario u WHERE u.id_usuario = pv.id_usuario_geracao) AS gerado_por,
    (SELECT ISNULL(SUM(ipv.valor_total_liquido), 0) FROM dbo.item_pedido_venda ipv
     WHERE ipv.id_pedido_venda = pv.id_pedido_venda) AS total
FROM dbo.pedido_venda pv
ORDER BY pv.data_hora_geracao DESC
" -W

# ===== 12. LINK pedido_venda <-> operacao_pdv =====
Write-Host "`n========== 12. PEDIDOS vinculados a OPERACOES ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    pvo.id_pedido_venda, pvo.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_operacao,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado=0) AS total_op
FROM dbo.pedido_venda_operacao_pdv pvo
LEFT JOIN dbo.operacao_pdv op ON op.id_operacao = pvo.id_operacao
ORDER BY pvo.id_operacao DESC
" -W 2>$null

# Se vazio, checar coluna pedido_venda na operacao_pdv
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5 op.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_hora,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado=0) AS total
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -1, GETDATE())
ORDER BY op.data_hora_termino DESC
" -W

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  ANALISE PROFUNDA CONCLUIDA" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
