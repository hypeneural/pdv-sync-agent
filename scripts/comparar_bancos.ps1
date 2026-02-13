# =============================================================
#  COMPARAR BANCOS: Hiper (Gestão/Loja) vs HiperPdv (Caixa)
#  Analisa relações, gaps de sincronização e vendas perdidas
# =============================================================
$server = ".\HIPER"
$dbGestao = "Hiper"
$dbPdv = "HiperPdv"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  COMPARATIVO: Hiper (Gestao/Loja) vs HiperPdv (Caixa)" -ForegroundColor Cyan
Write-Host "  Maquina: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ===== 1. TABELAS EM COMUM =====
Write-Host "`n========== 1. TABELAS EM COMUM ==========" -ForegroundColor Yellow
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    g.name AS tabela,
    CASE WHEN p.name IS NOT NULL THEN 'SIM' ELSE '---' END AS em_HiperPdv,
    'SIM' AS em_Hiper
FROM [$dbGestao].sys.tables g
LEFT JOIN [$dbPdv].sys.tables p ON p.name = g.name
WHERE g.name IN ('turno','operacao_pdv','item_operacao_pdv','finalizador_operacao_pdv',
    'cancelamento_operacao_pdv','recebimento_operacao_pdv','servico_operacao_pdv',
    'ponto_venda','usuario','produto','finalizador','nota_fiscal','pre_venda',
    'pedido_venda','item_pedido_venda','devolucao_venda')
ORDER BY g.name
" -W

# ===== 2. LOJAS (ponto_venda) =====
Write-Host "`n========== 2. LOJAS - Hiper (Gestao) ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT id_ponto_venda, apelido, nome_fantasia, nome_cidade, sigla_uf
FROM dbo.ponto_venda ORDER BY id_ponto_venda" -W

Write-Host "`n========== 2b. LOJAS - HiperPdv (Caixa) ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbPdv -Q "SET NOCOUNT ON;
SELECT id_ponto_venda, apelido, nome_fantasia
FROM dbo.ponto_venda ORDER BY id_ponto_venda" -W

# ===== 3. USUARIOS COMPARATIVO =====
Write-Host "`n========== 3. USUARIOS - Comparativo ==========" -ForegroundColor Yellow
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    COALESCE(g.id_usuario, p.id_usuario) AS id,
    g.nome AS nome_gestao,
    p.nome AS nome_pdv,
    g.login AS login_gestao,
    p.login AS login_pdv,
    CASE
        WHEN g.id_usuario IS NULL THEN 'SO NO PDV'
        WHEN p.id_usuario IS NULL THEN 'SO NA GESTAO'
        WHEN g.nome = p.nome THEN 'IGUAL'
        ELSE 'DIFERENTE'
    END AS status
FROM [$dbGestao].dbo.usuario g
FULL OUTER JOIN [$dbPdv].dbo.usuario p ON p.id_usuario = g.id_usuario
ORDER BY COALESCE(g.id_usuario, p.id_usuario)
" -W

# ===== 4. TURNOS COMPARATIVO =====
Write-Host "`n========== 4. TURNOS - Comparativo (ultimos 10) ==========" -ForegroundColor Green
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    COALESCE(CONVERT(VARCHAR(36), g.id_turno), CONVERT(VARCHAR(36), p.id_turno)) AS id_turno,
    g.sequencial AS seq_gestao,
    p.sequencial AS seq_pdv,
    CONVERT(VARCHAR(19), COALESCE(g.data_hora_inicio, p.data_hora_inicio), 120) AS inicio,
    CASE WHEN g.id_turno IS NULL THEN 'SO NO PDV'
         WHEN p.id_turno IS NULL THEN 'SO NA GESTAO'
         ELSE 'AMBOS' END AS onde,
    CASE WHEN COALESCE(g.fechado, p.fechado) = 1 THEN 'FECHADO' ELSE 'ABERTO' END AS status
FROM (SELECT TOP 10 * FROM [$dbGestao].dbo.turno ORDER BY data_hora_inicio DESC) g
FULL OUTER JOIN (SELECT TOP 10 * FROM [$dbPdv].dbo.turno ORDER BY data_hora_inicio DESC) p
    ON p.id_turno = g.id_turno
ORDER BY COALESCE(g.data_hora_inicio, p.data_hora_inicio) DESC
" -W

# ===== 5. VENDAS - ULTIMAS 20 COMPARATIVO =====
Write-Host "`n========== 5. VENDAS - Comparativo por data/valor (ultimas 20) ==========" -ForegroundColor Magenta
sqlcmd -S $server -Q "SET NOCOUNT ON;
;WITH gestao AS (
    SELECT TOP 20
        op.id_operacao, op.data_hora_termino,
        (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM [$dbGestao].dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total,
        op.id_turno
    FROM [$dbGestao].dbo.operacao_pdv op
    WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
    ORDER BY op.data_hora_termino DESC
),
pdv AS (
    SELECT TOP 20
        op.id_operacao, op.data_hora_termino,
        (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM [$dbPdv].dbo.item_operacao_pdv i
         WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total,
        op.id_turno
    FROM [$dbPdv].dbo.operacao_pdv op
    WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
    ORDER BY op.data_hora_termino DESC
)
SELECT
    CONVERT(VARCHAR(19), COALESCE(g.data_hora_termino, p.data_hora_termino), 120) AS data_hora,
    g.id_operacao AS id_gestao,
    p.id_operacao AS id_pdv,
    g.total AS total_gestao,
    p.total AS total_pdv,
    CASE
        WHEN g.id_operacao IS NULL THEN '>>> SO NO PDV'
        WHEN p.id_operacao IS NULL THEN '<<< SO NA GESTAO'
        WHEN g.total = p.total THEN 'OK (valores iguais)'
        ELSE 'DIVERGENTE!'
    END AS status
FROM gestao g
FULL OUTER JOIN pdv p
    ON ABS(DATEDIFF(SECOND, g.data_hora_termino, p.data_hora_termino)) <= 5
    AND g.total = p.total
ORDER BY COALESCE(g.data_hora_termino, p.data_hora_termino) DESC
" -W

# ===== 6. VENDAS EXISTEM SO EM 1 BANCO (GAPS) =====
Write-Host "`n========== 6. GAPS - Vendas hoje SO na Gestao (Hiper Loja) ==========" -ForegroundColor Red
sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT
    op.id_operacao AS id_gestao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_hora,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total,
    (SELECT TOP 1 uv.nome FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS vendedor,
    'NAO EXISTE NO HIPERPDV' AS status
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= CAST(GETDATE() AS DATE)
  AND NOT EXISTS (
    SELECT 1 FROM [$dbPdv].dbo.operacao_pdv p
    WHERE ABS(DATEDIFF(SECOND, p.data_hora_termino, op.data_hora_termino)) <= 5
      AND p.operacao = 1 AND p.cancelado = 0
      AND (SELECT ISNULL(SUM(i2.valor_total_liquido),0) FROM [$dbPdv].dbo.item_operacao_pdv i2
           WHERE i2.id_operacao = p.id_operacao AND i2.cancelado = 0)
          = (SELECT ISNULL(SUM(i3.valor_total_liquido),0) FROM dbo.item_operacao_pdv i3
             WHERE i3.id_operacao = op.id_operacao AND i3.cancelado = 0)
  )
ORDER BY op.data_hora_termino DESC
" -W

Write-Host "`n========== 6b. GAPS - Vendas hoje SO no PDV (HiperCaixa) ==========" -ForegroundColor Red
sqlcmd -S $server -d $dbPdv -Q "SET NOCOUNT ON;
SELECT
    op.id_operacao AS id_pdv,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS data_hora,
    (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total,
    (SELECT TOP 1 uv.nome FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS vendedor,
    'NAO EXISTE NO HIPER GESTAO' AS status
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= CAST(GETDATE() AS DATE)
  AND NOT EXISTS (
    SELECT 1 FROM [$dbGestao].dbo.operacao_pdv g
    WHERE ABS(DATEDIFF(SECOND, g.data_hora_termino, op.data_hora_termino)) <= 5
      AND g.operacao = 1 AND g.cancelado = 0
      AND (SELECT ISNULL(SUM(i2.valor_total_liquido),0) FROM [$dbGestao].dbo.item_operacao_pdv i2
           WHERE i2.id_operacao = g.id_operacao AND i2.cancelado = 0)
          = (SELECT ISNULL(SUM(i3.valor_total_liquido),0) FROM dbo.item_operacao_pdv i3
             WHERE i3.id_operacao = op.id_operacao AND i3.cancelado = 0)
  )
ORDER BY op.data_hora_termino DESC
" -W

# ===== 7. CONTAGEM TOTAL =====
Write-Host "`n========== 7. TOTAIS GERAIS ==========" -ForegroundColor Cyan
sqlcmd -S $server -Q "SET NOCOUNT ON;
SELECT
    'Hiper (Gestao)' AS banco,
    (SELECT COUNT(*) FROM [$dbGestao].dbo.operacao_pdv WHERE operacao=1 AND cancelado=0) AS total_vendas,
    (SELECT COUNT(*) FROM [$dbGestao].dbo.turno) AS total_turnos,
    (SELECT COUNT(*) FROM [$dbGestao].dbo.usuario) AS total_usuarios,
    (SELECT COUNT(*) FROM [$dbGestao].dbo.ponto_venda) AS total_lojas,
    (SELECT COUNT(*) FROM [$dbGestao].dbo.produto) AS total_produtos
UNION ALL
SELECT
    'HiperPdv (Caixa)' AS banco,
    (SELECT COUNT(*) FROM [$dbPdv].dbo.operacao_pdv WHERE operacao=1 AND cancelado=0) AS total_vendas,
    (SELECT COUNT(*) FROM [$dbPdv].dbo.turno) AS total_turnos,
    (SELECT COUNT(*) FROM [$dbPdv].dbo.usuario) AS total_usuarios,
    (SELECT COUNT(*) FROM [$dbPdv].dbo.ponto_venda) AS total_lojas,
    (SELECT COUNT(*) FROM [$dbPdv].dbo.produto) AS total_produtos
" -W

# ===== 8. SYNC CONFIG =====
Write-Host "`n========== 8. TABELAS DE SINCRONIZACAO ==========" -ForegroundColor Yellow
Write-Host "  --- Hiper ---" -ForegroundColor Yellow
sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT t.name AS tabela, t.modify_date
FROM sys.tables t
WHERE t.name LIKE '%sync%' OR t.name LIKE '%sincroniz%' OR t.name LIKE '%replicat%'
ORDER BY t.name" -W

Write-Host "  --- HiperPdv ---" -ForegroundColor Yellow
sqlcmd -S $server -d $dbPdv -Q "SET NOCOUNT ON;
SELECT t.name AS tabela, t.modify_date
FROM sys.tables t
WHERE t.name LIKE '%sync%' OR t.name LIKE '%sincroniz%' OR t.name LIKE '%replicat%'
ORDER BY t.name" -W

# ===== 9. PEDIDO_VENDA (Hiper Loja) =====
Write-Host "`n========== 9. PEDIDOS VENDA (Hiper Loja) - Ultimos 10 ==========" -ForegroundColor Green
sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT c.name AS coluna, tp.name AS tipo
FROM sys.columns c JOIN sys.types tp ON tp.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.pedido_venda')
ORDER BY c.column_id" -W 2>$null

sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT TOP 10 id_pedido_venda, data_hora_venda, id_ponto_venda, id_usuario, valor_total,
    situacao, CONVERT(VARCHAR(19), data_hora_venda, 120) AS data_hora
FROM dbo.pedido_venda
ORDER BY data_hora_venda DESC" -W 2>$null

# ===== 10. RELACAO operacao_pdv <-> pedido_venda =====
Write-Host "`n========== 10. LINK operacao_pdv <-> pedido_venda na Gestao ==========" -ForegroundColor Magenta
sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
SELECT TOP 1 name FROM sys.tables WHERE name = 'pedido_venda_operacao_pdv'" -W -h -1 2>$null
$temLink = sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name = 'pedido_venda_operacao_pdv'" -W -h -1
if ($temLink -and $temLink.Trim() -gt "0") {
    Write-Host "  Tabela pedido_venda_operacao_pdv EXISTE! Ultimos 10:" -ForegroundColor Green
    sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
    SELECT TOP 10 * FROM dbo.pedido_venda_operacao_pdv ORDER BY 1 DESC" -W
}
else {
    Write-Host "  Tabela pedido_venda_operacao_pdv NAO encontrada" -ForegroundColor Red
    Write-Host "  Verificando colunas de link em operacao_pdv..." -ForegroundColor Yellow
    sqlcmd -S $server -d $dbGestao -Q "SET NOCOUNT ON;
    SELECT c.name FROM sys.columns c
    WHERE c.object_id = OBJECT_ID('dbo.operacao_pdv')
      AND (c.name LIKE '%pedido%' OR c.name LIKE '%pre_venda%' OR c.name LIKE '%origem%')
    ORDER BY c.column_id" -W
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  ANALISE CONCLUIDA" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
