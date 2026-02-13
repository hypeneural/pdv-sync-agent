# =============================================================
#  EXPLORAR TURNOS - Todas as colunas e dados do turno
# =============================================================
$server = ".\HIPER"
$db = "HiperPdv"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  EXPLORADOR DE TURNOS" -ForegroundColor Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ===== 1. ESTRUTURA DA TABELA TURNO =====
Write-Host "`n========== COLUNAS DA TABELA 'turno' ==========" -ForegroundColor Yellow
$colunas = sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT
    c.name AS coluna,
    t.name AS tipo,
    c.max_length AS tamanho,
    CASE WHEN c.is_nullable = 1 THEN 'SIM' ELSE 'NAO' END AS permite_null
FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.turno')
ORDER BY c.column_id
" -W -s "|"
$colunas | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

# ===== 2. ULTIMOS 5 TURNOS - TODAS AS COLUNAS =====
Write-Host "`n========== ULTIMOS 5 TURNOS (TODOS OS CAMPOS) ==========" -ForegroundColor Green
$turnos = sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 5 *
FROM dbo.turno
ORDER BY data_hora_inicio DESC
" -W -s "|"
$turnos | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

# ===== 3. TURNOS COM OPERADOR E LOJA =====
Write-Host "`n========== ULTIMOS 5 TURNOS (DETALHADO) ==========" -ForegroundColor Magenta
$detalhado = sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT TOP 5
    t.id_turno,
    t.sequencial,
    CASE WHEN t.fechado = 1 THEN 'FECHADO' ELSE 'ABERTO' END AS status,
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
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS vendas_no_turno
FROM dbo.turno t
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
ORDER BY t.data_hora_inicio DESC
" -W -s "|"
$detalhado | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

# ===== 4. TABELAS RELACIONADAS AO TURNO =====
Write-Host "`n========== TABELAS QUE REFERENCIAM 'turno' ==========" -ForegroundColor Yellow
$refs = sqlcmd -S $server -d $db -Q "
SET NOCOUNT ON;
SELECT
    OBJECT_NAME(fk.parent_object_id) AS tabela_que_usa,
    COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS coluna_fk,
    fk.name AS nome_constraint
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE fk.referenced_object_id = OBJECT_ID('dbo.turno')
ORDER BY tabela_que_usa
" -W -s "|"
$refs | ForEach-Object { Write-Host "  $_" -ForegroundColor White }

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  FIM" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
