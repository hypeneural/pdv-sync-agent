# ==============================================================================
#  INVESTIGAR HIPER LOJA - Fluxo de vendas, origem, sync, e duplicação
#  Objetivo: entender como as vendas do Hiper Loja chegam nos bancos
#             e como incluir no webhook sem duplicar
# ==============================================================================
$server = ".\HIPER"
$dbG = "Hiper"      # Banco Gestão (Hiper Loja grava aqui)
$dbP = "HiperPdv"   # Banco PDV (HiperCaixa grava aqui)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  INVESTIGACAO HIPER LOJA - Canais de Venda" -ForegroundColor Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ===== 1. CAMPO ORIGEM - O que significa cada valor? =====
Write-Host "`n========== 1. VALORES DE ORIGEM em operacao_pdv ==========" -ForegroundColor Yellow
Write-Host "  --- Hiper (Gestao) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    op.origem,
    COUNT(*) AS total_vendas,
    MIN(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS primeira_venda,
    MAX(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS ultima_venda,
    SUM((SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0)) AS total_vendido
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
GROUP BY op.origem
ORDER BY op.origem
" -W

Write-Host "  --- HiperPdv (Caixa) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT
    op.origem,
    COUNT(*) AS total_vendas,
    MIN(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS primeira_venda,
    MAX(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS ultima_venda,
    SUM((SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0)) AS total_vendido
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
GROUP BY op.origem
ORDER BY op.origem
" -W

# ===== 2. VENDAS POR ORIGEM - Ultimas de cada canal =====
Write-Host "`n========== 2. ULTIMAS 5 VENDAS DE CADA ORIGEM (Gestao) ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
;WITH ranked AS (
    SELECT
        op.id_operacao, op.origem,
        CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
        op.id_usuario,
        (SELECT u.nome FROM dbo.usuario u WHERE u.id_usuario = op.id_usuario) AS usuario,
        (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total,
        (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS itens,
        op.id_filial,
        op.id_turno,
        op.ValorTroco,
        ROW_NUMBER() OVER (PARTITION BY op.origem ORDER BY op.data_hora_termino DESC) AS rn
    FROM dbo.operacao_pdv op
    WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
)
SELECT origem, id_operacao, termino, id_filial AS filial, usuario, itens, total, ValorTroco AS troco
FROM ranked WHERE rn <= 5
ORDER BY origem, rn
" -W

# ===== 3. FINALIZADORES - Nomes dos meios de pagamento =====
Write-Host "`n========== 3. FINALIZADORES (meios de pagamento) ==========" -ForegroundColor Yellow
Write-Host "  --- finalizador_pdv (HiperPdv) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.finalizador_pdv')
ORDER BY c.column_id" -W

sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT * FROM dbo.finalizador_pdv ORDER BY id_finalizador" -W

# Tentar na Gestao tambem
Write-Host "  --- finalizador (Gestao) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT t.name FROM sys.tables t
WHERE t.name LIKE '%finalizador%' AND t.name NOT LIKE '%operacao%'
ORDER BY t.name" -W

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
IF OBJECT_ID('dbo.finalizador') IS NOT NULL
SELECT TOP 20 * FROM dbo.finalizador ORDER BY id_finalizador" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
IF OBJECT_ID('dbo.finalizador_pdv') IS NOT NULL
SELECT TOP 20 * FROM dbo.finalizador_pdv ORDER BY id_finalizador" -W 2>$null

# ===== 4. HIPER LOJA - Vendas origem=2 vs PDV origem=0/1 =====
Write-Host "`n========== 4. HIPER LOJA vs HiperCaixa - Vendas por dia (ultimos 7 dias) ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT
    CONVERT(VARCHAR(10), op.data_hora_termino, 120) AS dia,
    SUM(CASE WHEN op.origem IN (0,1) THEN 1 ELSE 0 END) AS vendas_pdv,
    SUM(CASE WHEN op.origem = 2 THEN 1 ELSE 0 END) AS vendas_loja,
    SUM(CASE WHEN op.origem NOT IN (0,1,2) THEN 1 ELSE 0 END) AS vendas_outro,
    SUM(CASE WHEN op.origem IN (0,1) THEN
        (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) ELSE 0 END) AS total_pdv,
    SUM(CASE WHEN op.origem = 2 THEN
        (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) ELSE 0 END) AS total_loja
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY CONVERT(VARCHAR(10), op.data_hora_termino, 120)
ORDER BY dia DESC
" -W

# ===== 5. DUPLICACAO? Checar se vendas origem=2 existem TAMBEM no HiperPdv =====
Write-Host "`n========== 5. HIPER LOJA VENDAS: Existem no HiperPdv? ==========" -ForegroundColor Red
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    g.id_operacao AS id_gestao,
    CONVERT(VARCHAR(19), g.data_hora_termino, 120) AS data_hora,
    g.origem AS origem_gestao,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM [$dbG].dbo.item_operacao_pdv i
     WHERE i.id_operacao = g.id_operacao AND i.cancelado = 0) AS total_gestao,
    p.id_operacao AS id_pdv,
    p.origem AS origem_pdv,
    CASE
        WHEN p.id_operacao IS NOT NULL THEN 'DUPLICADA NO PDV!'
        ELSE 'SO NA GESTAO (sem duplicar)'
    END AS status
FROM [$dbG].dbo.operacao_pdv g
LEFT JOIN [$dbP].dbo.operacao_pdv p
    ON ABS(DATEDIFF(SECOND, g.data_hora_termino, p.data_hora_termino)) <= 5
    AND p.operacao = 1 AND p.cancelado = 0
    AND (SELECT ISNULL(SUM(i2.valor_total_liquido),0) FROM [$dbP].dbo.item_operacao_pdv i2
         WHERE i2.id_operacao = p.id_operacao AND i2.cancelado = 0)
        = (SELECT ISNULL(SUM(i3.valor_total_liquido),0) FROM [$dbG].dbo.item_operacao_pdv i3
           WHERE i3.id_operacao = g.id_operacao AND i3.cancelado = 0)
WHERE g.operacao = 1 AND g.cancelado = 0 AND g.origem = 2
  AND g.data_hora_termino >= DATEADD(DAY, -30, GETDATE())
ORDER BY g.data_hora_termino DESC
" -W

# ===== 6. VENDAS DO PDV: Vendas do HiperCaixa que NAO existem na Gestao =====
Write-Host "`n========== 6. VENDAS PDV SEM MATCH NA GESTAO (ultimos 3 dias) ==========" -ForegroundColor Magenta
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    p.id_operacao AS id_pdv,
    CONVERT(VARCHAR(19), p.data_hora_termino, 120) AS data_hora,
    p.origem AS origem_pdv,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM [$dbP].dbo.item_operacao_pdv i
     WHERE i.id_operacao = p.id_operacao AND i.cancelado = 0) AS total_pdv,
    'NAO EXISTE NA GESTAO' AS status
FROM [$dbP].dbo.operacao_pdv p
WHERE p.operacao = 1 AND p.cancelado = 0 AND p.data_hora_termino IS NOT NULL
  AND p.data_hora_termino >= DATEADD(DAY, -3, GETDATE())
  AND NOT EXISTS (
    SELECT 1 FROM [$dbG].dbo.operacao_pdv g
    WHERE ABS(DATEDIFF(SECOND, g.data_hora_termino, p.data_hora_termino)) <= 5
      AND g.operacao = 1 AND g.cancelado = 0
      AND (SELECT ISNULL(SUM(i2.valor_total_liquido),0) FROM [$dbG].dbo.item_operacao_pdv i2
           WHERE i2.id_operacao = g.id_operacao AND i2.cancelado = 0)
          = (SELECT ISNULL(SUM(i3.valor_total_liquido),0) FROM [$dbP].dbo.item_operacao_pdv i3
             WHERE i3.id_operacao = p.id_operacao AND i3.cancelado = 0)
  )
ORDER BY p.data_hora_termino DESC
" -W

# ===== 7. HIPERLOJA SYNC - O que sincroniza e quando =====
Write-Host "`n========== 7. HIPERLOJA SYNC - Registro de objetos sincronizados ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.hiperloja_sync_registro')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 20 * FROM dbo.hiperloja_sync_registro ORDER BY 1 DESC" -W 2>$null

Write-Host "`n  --- Tabelas replicadas (tipo_objeto) ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.hiperloja_sync_protocolo_sincronizacao_tipo_objeto')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT * FROM dbo.hiperloja_sync_protocolo_sincronizacao_tipo_objeto" -W 2>$null

# ===== 8. HIPERLOJA SYNC - Processamento recente =====
Write-Host "`n========== 8. SYNC PROCESSAMENTO - Ultimas atividades ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.hiperloja_sync_processamento')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 10 * FROM dbo.hiperloja_sync_processamento ORDER BY 1 DESC" -W 2>$null

# ===== 9. HIPER PDV SYNC CONFIG =====
Write-Host "`n========== 9. HIPERSYNC CONFIG (HiperPdv) ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.hipersync_config')
ORDER BY c.column_id" -W

sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT * FROM dbo.hipersync_config" -W

# ===== 10. TABELAS HIPERPDV_ no banco Gestao (dados do PDV na Gestao) =====
Write-Host "`n========== 10. TABELAS hiperpdv_ na Gestao (replicadas do PDV) ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT t.name, (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS colunas
FROM sys.tables t WHERE t.name LIKE 'hiperpdv_%'
ORDER BY t.name" -W

# Comparar quantidade de registros
Write-Host "`n  --- Registros nas tabelas hiperpdv_ ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT 'hiperpdv_operacao_pdv' AS tabela,
    (SELECT COUNT(*) FROM dbo.hiperpdv_operacao_pdv) AS registros
UNION ALL
SELECT 'hiperpdv_item_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_item_operacao_pdv)
UNION ALL
SELECT 'hiperpdv_finalizador_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_finalizador_operacao_pdv)
UNION ALL
SELECT 'hiperpdv_cancelamento_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_cancelamento_operacao_pdv)
UNION ALL
SELECT 'hiperpdv_devolucao_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_devolucao_operacao_pdv)
UNION ALL
SELECT 'hiperpdv_servico_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_servico_operacao_pdv)
UNION ALL
SELECT 'hiperpdv_recebimento_operacao_pdv',
    (SELECT COUNT(*) FROM dbo.hiperpdv_recebimento_operacao_pdv)
" -W

# ===== 11. COMPARAR hiperpdv_operacao_pdv vs operacao_pdv =====
Write-Host "`n========== 11. hiperpdv_operacao_pdv vs operacao_pdv (Gestao) ==========" -ForegroundColor Red
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5
    h.id_operacao AS id_hiperpdv,
    CONVERT(VARCHAR(19), h.data_hora_termino, 120) AS termino_hiperpdv,
    op.id_operacao AS id_operacao_gestao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino_gestao
FROM dbo.hiperpdv_operacao_pdv h
LEFT JOIN dbo.operacao_pdv op
    ON ABS(DATEDIFF(SECOND, h.data_hora_termino, op.data_hora_termino)) <= 5
    AND op.operacao = 1 AND op.cancelado = 0
WHERE h.operacao = 1 AND h.cancelado = 0 AND h.data_hora_termino IS NOT NULL
ORDER BY h.data_hora_termino DESC
" -W 2>$null

# Ultimas hiperpdv_operacao_pdv
Write-Host "`n  --- Ultimas 5 hiperpdv_operacao_pdv ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5
    id_operacao, CONVERT(VARCHAR(19), data_hora_termino, 120) AS termino,
    operacao, cancelado, origem,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.hiperpdv_item_operacao_pdv i
     WHERE i.id_operacao = h.id_operacao AND i.cancelado = 0) AS total
FROM dbo.hiperpdv_operacao_pdv h
WHERE operacao = 1 AND cancelado = 0 AND data_hora_termino IS NOT NULL
ORDER BY data_hora_termino DESC
" -W 2>$null

# ===== 12. ITEM_PEDIDO_VENDA - Colunas corretas =====
Write-Host "`n========== 12. ITEM_PEDIDO_VENDA - Schema ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo
FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.item_pedido_venda')
ORDER BY c.column_id" -W

# Ultimos pedidos com totais
Write-Host "`n  --- Ultimos 10 pedidos venda com totais ---" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 10
    pv.id_pedido_venda,
    CONVERT(VARCHAR(19), pv.data_hora_geracao, 120) AS data_hora,
    pv.id_filial_venda AS filial,
    pv.situacao,
    pv.operacao,
    (SELECT u.nome FROM dbo.usuario u WHERE u.id_usuario = pv.id_usuario_geracao) AS gerado_por,
    (SELECT COUNT(*) FROM dbo.item_pedido_venda ipv WHERE ipv.id_pedido_venda = pv.id_pedido_venda) AS qtd_itens,
    (SELECT ISNULL(SUM(ipv.valor_unitario_liquido * ipv.quantidade), 0) FROM dbo.item_pedido_venda ipv
     WHERE ipv.id_pedido_venda = pv.id_pedido_venda) AS total_calc
FROM dbo.pedido_venda pv
ORDER BY pv.data_hora_geracao DESC
" -W 2>$null

# ===== 13. CAMPO guid_operacao - link entre bancos? =====
Write-Host "`n========== 13. GUID_OPERACAO - Link entre bancos? ==========" -ForegroundColor Magenta
Write-Host "  Ultimas 5 vendas Gestao com guid:" -ForegroundColor Cyan
sqlcmd -S $server -d $dbG -Q "SET NOCOUNT ON;
SELECT TOP 5
    op.id_operacao, op.guid_operacao, op.origem,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
" -W

Write-Host "`n  Ultimas 5 vendas HiperPdv com guid:" -ForegroundColor Cyan
sqlcmd -S $server -d $dbP -Q "SET NOCOUNT ON;
SELECT TOP 5
    op.id_operacao, op.guid_operacao, op.origem,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
" -W

# GUID match?
Write-Host "`n  GUID MATCH - vendas com mesmo guid nos 2 bancos:" -ForegroundColor Red
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT TOP 10
    g.id_operacao AS id_gestao,
    p.id_operacao AS id_pdv,
    g.guid_operacao,
    g.origem AS orig_gestao,
    p.origem AS orig_pdv,
    CONVERT(VARCHAR(19), g.data_hora_termino, 120) AS termino_gestao,
    CONVERT(VARCHAR(19), p.data_hora_termino, 120) AS termino_pdv,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM [$dbG].dbo.item_operacao_pdv i
     WHERE i.id_operacao = g.id_operacao AND i.cancelado = 0) AS total
FROM [$dbG].dbo.operacao_pdv g
JOIN [$dbP].dbo.operacao_pdv p ON p.guid_operacao = g.guid_operacao
WHERE g.operacao = 1 AND g.cancelado = 0 AND g.guid_operacao IS NOT NULL AND g.guid_operacao != ''
ORDER BY g.data_hora_termino DESC
" -W

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  INVESTIGACAO HIPER LOJA CONCLUIDA" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
