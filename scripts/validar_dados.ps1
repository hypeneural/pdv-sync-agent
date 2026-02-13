# =============================================================
#  VALIDACAO DE DADOS - PDV Sync Agent
#  Explora turnos e vendas com todos os detalhes
#  Valida consistencia dos dados e propoe dados para webhook
# =============================================================
$server = ".\HIPER"
$db = "HiperPdv"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  VALIDACAO DE DADOS - PDV Sync Agent" -ForegroundColor Cyan
Write-Host "  Maquina: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ===== 1. QUAL LOJA ESTA MAQUINA OPERA? =====
Write-Host "`n========== 1. IDENTIFICACAO DA LOJA ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 1
    pv.id_ponto_venda, pv.apelido, pv.nome_fantasia,
    pv.nome_cidade, pv.sigla_uf,
    COUNT(*) AS vendas_recentes
FROM dbo.operacao_pdv o
JOIN dbo.turno t ON t.id_turno = o.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE o.operacao = 1 AND o.cancelado = 0
  AND o.data_hora_termino >= DATEADD(DAY, -5, GETDATE())
GROUP BY pv.id_ponto_venda, pv.apelido, pv.nome_fantasia, pv.nome_cidade, pv.sigla_uf
ORDER BY vendas_recentes DESC
" -W

# ===== 2. TURNOS ABERTOS AGORA (TODAS AS LOJAS) =====
Write-Host "`n========== 2. TURNOS ABERTOS AGORA ==========" -ForegroundColor Red
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT
    t.id_turno,
    t.sequencial,
    'ABERTO' AS status,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS inicio,
    DATEDIFF(MINUTE, t.data_hora_inicio, GETDATE()) AS minutos_aberto,
    pv.apelido AS loja,
    u.nome AS operador,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS vendas
FROM dbo.turno t
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE t.fechado = 0
ORDER BY t.data_hora_inicio DESC
" -W

# ===== 3. ULTIMOS 10 TURNOS DETALHADOS =====
Write-Host "`n========== 3. ULTIMOS 10 TURNOS (DETALHADO) ==========" -ForegroundColor Green
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 10
    t.sequencial AS seq,
    CASE WHEN t.fechado = 1 THEN 'FECHADO' ELSE 'ABERTO ' END AS status,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), t.data_hora_termino, 120) AS termino,
    DATEDIFF(MINUTE, t.data_hora_inicio, ISNULL(t.data_hora_termino, GETDATE())) AS duracao_min,
    CASE
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 12 THEN 'MATUTINO'
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 18 THEN 'VESPERTINO'
        ELSE 'NOTURNO'
    END AS periodo,
    pv.apelido AS loja,
    u.nome AS operador,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS vendas,
    (SELECT ISNULL(SUM(it.valor_total_liquido), 0) FROM dbo.operacao_pdv op2
     JOIN dbo.item_operacao_pdv it ON it.id_operacao = op2.id_operacao
     WHERE op2.id_turno = t.id_turno AND op2.operacao = 1 AND op2.cancelado = 0
     AND it.cancelado = 0) AS total_vendas_R$
FROM dbo.turno t
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
ORDER BY t.data_hora_inicio DESC
" -W

# ===== 4. ULTIMAS 10 VENDAS DETALHADAS =====
Write-Host "`n========== 4. ULTIMAS 10 VENDAS ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 10
    op.id_operacao AS id_venda,
    CONVERT(VARCHAR(19), op.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_seg,
    pv.apelido AS loja,
    u_op.nome AS operador,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS qtd_itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total_R$
FROM dbo.operacao_pdv op
JOIN dbo.turno t ON t.id_turno = op.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
LEFT JOIN dbo.usuario u_op ON u_op.id_usuario = t.id_usuario
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
" -W

# ===== 5. DETALHES DA ULTIMA VENDA (ITENS + PAGAMENTO) =====
Write-Host "`n========== 5. ULTIMA VENDA - ITENS ==========" -ForegroundColor Yellow
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
DECLARE @lastSale INT;
SELECT TOP 1 @lastSale = id_operacao
FROM dbo.operacao_pdv
WHERE operacao = 1 AND cancelado = 0 AND data_hora_termino IS NOT NULL
ORDER BY data_hora_termino DESC;

SELECT
    'VENDA #' + CAST(@lastSale AS VARCHAR) AS titulo,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_hora,
    pv.apelido AS loja,
    u.nome AS operador
FROM dbo.operacao_pdv op
JOIN dbo.turno t ON t.id_turno = op.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
WHERE op.id_operacao = @lastSale;

PRINT '';
PRINT 'ITENS:';
SELECT
    it.item AS seq,
    p.nome AS produto,
    it.quantidade_primaria AS qtd,
    it.valor_unitario_liquido AS preco_unit,
    it.valor_total_liquido AS total,
    ISNULL(it.valor_desconto, 0) AS desconto,
    uv.nome AS vendedor
FROM dbo.item_operacao_pdv it
JOIN dbo.produto p ON p.id_produto = it.id_produto
LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor
WHERE it.id_operacao = @lastSale AND it.cancelado = 0
ORDER BY it.item;

PRINT '';
PRINT 'PAGAMENTO:';
SELECT
    fpv.nome AS meio_pagamento,
    fo.valor AS valor_pago,
    ISNULL(fo.valor_troco, 0) AS troco,
    fo.parcela
FROM dbo.finalizador_operacao_pdv fo
JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
WHERE fo.id_operacao = @lastSale;
" -W

# ===== 6. COLUNAS DA TABELA operacao_pdv =====
Write-Host "`n========== 6. COLUNAS DE operacao_pdv ==========" -ForegroundColor Cyan
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo, c.max_length AS tam
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.operacao_pdv')
ORDER BY c.column_id
" -W

# ===== 7. COLUNAS DA TABELA item_operacao_pdv =====
Write-Host "`n========== 7. COLUNAS DE item_operacao_pdv ==========" -ForegroundColor Cyan
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT c.name AS coluna, t.name AS tipo, c.max_length AS tam
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.item_operacao_pdv')
ORDER BY c.column_id
" -W

# ===== 8. VERIFICACAO DE CONSISTENCIA =====
Write-Host "`n========== 8. VERIFICACOES DE CONSISTENCIA ==========" -ForegroundColor Red
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;

-- Turnos sem loja
PRINT '--- Turnos sem ponto_venda valido ---';
SELECT COUNT(*) AS turnos_sem_loja
FROM dbo.turno t
WHERE NOT EXISTS (SELECT 1 FROM dbo.ponto_venda pv WHERE pv.id_ponto_venda = t.id_ponto_venda);

-- Vendas sem turno
PRINT '--- Vendas sem turno valido ---';
SELECT COUNT(*) AS vendas_sem_turno
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.turno t WHERE t.id_turno = op.id_turno);

-- Vendas com data_hora_termino NULL (incompletas)
PRINT '--- Vendas incompletas (sem termino) ---';
SELECT COUNT(*) AS vendas_incompletas
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NULL;

-- Itens sem vendedor
PRINT '--- Itens sem vendedor ---';
SELECT COUNT(*) AS itens_sem_vendedor
FROM dbo.item_operacao_pdv it
JOIN dbo.operacao_pdv op ON op.id_operacao = it.id_operacao
WHERE op.operacao = 1 AND op.cancelado = 0 AND it.cancelado = 0
  AND it.id_usuario_vendedor IS NULL
  AND op.data_hora_termino >= DATEADD(DAY, -5, GETDATE());

-- Turnos com duracao 0-2 min (possiveis erros)
PRINT '--- Turnos muito curtos (< 2 min) ultimos 30 dias ---';
SELECT
    t.sequencial, pv.apelido,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS inicio,
    DATEDIFF(SECOND, t.data_hora_inicio, t.data_hora_termino) AS segundos
FROM dbo.turno t
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE t.fechado = 1
  AND DATEDIFF(MINUTE, t.data_hora_inicio, t.data_hora_termino) < 2
  AND t.data_hora_inicio >= DATEADD(DAY, -30, GETDATE())
ORDER BY t.data_hora_inicio DESC;
" -W

# ===== 9. PROPOSTA WEBHOOK: AMOSTRA DE DADOS =====
Write-Host "`n========== 9. PROPOSTA WEBHOOK: SNAPSHOT TURNOS ==========" -ForegroundColor Green
Write-Host "  Dados que poderiam ir no webhook a cada 10 min:" -ForegroundColor DarkGray
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
PRINT 'SNAPSHOT DE TURNOS (ultimas 24h):';
SELECT
    t.id_turno,
    t.sequencial,
    t.fechado,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), t.data_hora_termino, 120) AS termino,
    t.id_ponto_venda,
    pv.apelido AS loja,
    t.id_usuario,
    u.nome AS operador,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS qtd_vendas,
    (SELECT ISNULL(SUM(it.valor_total_liquido), 0) FROM dbo.operacao_pdv op3
     JOIN dbo.item_operacao_pdv it ON it.id_operacao = op3.id_operacao
     WHERE op3.id_turno = t.id_turno AND op3.operacao = 1 AND op3.cancelado = 0
     AND it.cancelado = 0) AS total_R$
FROM dbo.turno t
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE t.data_hora_inicio >= DATEADD(HOUR, -24, GETDATE())
ORDER BY t.data_hora_inicio DESC;
" -W

Write-Host "`n========== 10. PROPOSTA WEBHOOK: SNAPSHOT VENDAS ==========" -ForegroundColor Green
Write-Host "  Ultimas 10 vendas com resumo (para verificacao backend):" -ForegroundColor DarkGray
sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 10
    op.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_hora,
    t.id_turno,
    t.sequencial AS turno_seq,
    pv.apelido AS loja,
    u.nome AS operador,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total_R$,
    (SELECT TOP 1 uv.nome FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS vendedor_principal
FROM dbo.operacao_pdv op
JOIN dbo.turno t ON t.id_turno = op.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
" -W

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  VALIDACAO COMPLETA" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
