<#
.SYNOPSIS
  Validação PR-12: Testa todas as queries Gestão que serão usadas no Python.
  Roda contra os dois bancos para confirmar compatibilidade.
.DESCRIPTION
  Valida: conexão dual-db, vendas Loja no window, itens, pagamentos,
  resumo por vendedor, resumo por meio de pagamento, snapshot combinado.
#>

$ErrorActionPreference = "Continue"

# ─── Config ────────────────────────────────────────────────────
$SERVER = "localhost\HIPER"
$DB_PDV = "HiperPdv"
$DB_GESTAO = "Hiper"
$ID_FILIAL = 10
$ID_PDV = 10

# Window: últimas 24h (para ter dados)
$dt_to = Get-Date
$dt_from = $dt_to.AddDays(-1)
$dt_from_str = $dt_from.ToString("yyyy-MM-dd HH:mm:ss")
$dt_to_str = $dt_to.ToString("yyyy-MM-dd HH:mm:ss")

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  PR-12: Validação Queries Gestão" -ForegroundColor Cyan
Write-Host "  Window: $dt_from_str → $dt_to_str" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$R = [ordered]@{
    "_meta" = @{
        "maquina"     = $env:COMPUTERNAME
        "gerado"      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        "window_from" = $dt_from_str
        "window_to"   = $dt_to_str
    }
}

function Run-Query {
    param(
        [string]$Db,
        [string]$Query,
        [string]$Label
    )
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$SERVER;Database=$Db;Integrated Security=True;TrustServerCertificate=True"
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        [void]$adapter.Fill($dt)
        $conn.Close()

        $rows = @()
        foreach ($row in $dt.Rows) {
            $obj = [ordered]@{}
            foreach ($col in $dt.Columns) {
                $val = $row[$col.ColumnName]
                if ($val -is [System.DBNull]) { $val = $null }
                $obj[$col.ColumnName] = $val
            }
            $rows += $obj
        }
        Write-Host "  ✅ $Label → $($rows.Count) registros" -ForegroundColor Green
        return $rows
    }
    catch {
        Write-Host "  ❌ $Label → $($_.Exception.Message)" -ForegroundColor Red
        return @(@{ "ERRO" = $_.Exception.Message })
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST 1: Conexão aos dois bancos
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[1/9] Teste de conexão..." -ForegroundColor Yellow

$R["1_conexao_pdv"] = Run-Query -Db $DB_PDV -Label "HiperPdv" -Query "SELECT DB_NAME() AS banco, @@VERSION AS versao"
$R["1_conexao_gestao"] = Run-Query -Db $DB_GESTAO -Label "Hiper (Gestão)" -Query "SELECT DB_NAME() AS banco, @@VERSION AS versao"

# ═══════════════════════════════════════════════════════════════
# TEST 2: get_loja_operations_in_window
# Query principal: vendas origem=2 no período
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[2/9] Vendas Loja no window (get_loja_operations_in_window)..." -ForegroundColor Yellow

$R["2_loja_operations"] = Run-Query -Db $DB_GESTAO -Label "Vendas Loja window" -Query @"
SELECT op.id_operacao, op.id_filial, op.id_usuario,
    u.nome AS operador,
    op.data_hora_inicio, op.data_hora_termino,
    op.guid_operacao, op.ValorTroco AS troco, op.valor_ajuste,
    CONVERT(VARCHAR(36), op.id_turno) AS id_turno,
    op.origem
FROM dbo.operacao_pdv op
LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
WHERE op.operacao = 1
  AND op.cancelado = 0
  AND op.origem = 2
  AND op.data_hora_termino IS NOT NULL
  AND op.data_hora_termino >= '$dt_from_str'
  AND op.data_hora_termino < '$dt_to_str'
  AND op.id_filial = $ID_FILIAL
ORDER BY op.data_hora_termino
"@

# ═══════════════════════════════════════════════════════════════
# TEST 3: get_loja_sale_items
# Itens das vendas Loja
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[3/9] Itens vendas Loja (get_loja_sale_items)..." -ForegroundColor Yellow

$R["3_loja_items"] = Run-Query -Db $DB_GESTAO -Label "Itens Loja" -Query @"
WITH ops AS (
    SELECT id_operacao, id_turno, id_filial,
           data_hora_termino
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
)
SELECT
    ops.id_operacao,
    CONVERT(VARCHAR(36), ops.id_turno) AS id_turno,
    ops.data_hora_termino,
    it.id_item_operacao_pdv AS line_id,
    it.item AS line_no,
    it.id_produto,
    it.codigo_barras,
    p.nome AS nome_produto,
    it.quantidade_primaria AS qtd,
    it.valor_unitario_liquido AS preco_unit,
    it.valor_total_liquido AS total_item,
    ISNULL(it.valor_desconto, 0) AS desconto_item,
    it.id_usuario_vendedor,
    uv.nome AS nome_vendedor
FROM ops
JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao
JOIN dbo.produto p ON p.id_produto = it.id_produto
LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor
WHERE it.cancelado = 0
ORDER BY ops.data_hora_termino, ops.id_operacao, it.item
"@

# ═══════════════════════════════════════════════════════════════
# TEST 4: get_loja_sale_payments
# Pagamentos das vendas Loja
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[4/9] Pagamentos vendas Loja (get_loja_sale_payments)..." -ForegroundColor Yellow

$R["4_loja_payments"] = Run-Query -Db $DB_GESTAO -Label "Pagamentos Loja" -Query @"
WITH ops AS (
    SELECT id_operacao
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
)
SELECT
    fo.id_finalizador_operacao_pdv AS line_id,
    fo.id_operacao,
    fo.id_finalizador,
    fpv.nome AS meio_pagamento,
    fo.valor,
    ISNULL(fo.valor_troco, 0) AS valor_troco,
    fo.parcela
FROM ops
JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
ORDER BY fo.id_operacao, fo.id_finalizador
"@

# ═══════════════════════════════════════════════════════════════
# TEST 5: get_loja_sales_by_vendor
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[5/9] Resumo por vendedor Loja (get_loja_sales_by_vendor)..." -ForegroundColor Yellow

$R["5_loja_by_vendor"] = Run-Query -Db $DB_GESTAO -Label "By vendor Loja" -Query @"
WITH ops AS (
    SELECT id_operacao, id_filial,
        CONVERT(VARCHAR(36), id_turno) AS id_turno
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
)
SELECT
    ops.id_filial AS id_ponto_venda,
    ops.id_turno,
    it.id_usuario_vendedor,
    u.nome AS vendedor_nome,
    COUNT(DISTINCT ops.id_operacao) AS qtd_cupons,
    SUM(ISNULL(it.valor_total_liquido, 0)) AS total_vendido
FROM ops
JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao
LEFT JOIN dbo.usuario u ON u.id_usuario = it.id_usuario_vendedor
WHERE it.cancelado = 0
GROUP BY ops.id_filial, ops.id_turno,
    it.id_usuario_vendedor, u.nome
ORDER BY total_vendido DESC
"@

# ═══════════════════════════════════════════════════════════════
# TEST 6: get_loja_payments_by_method
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[6/9] Resumo por meio de pagamento Loja..." -ForegroundColor Yellow

$R["6_loja_by_payment"] = Run-Query -Db $DB_GESTAO -Label "By payment Loja" -Query @"
WITH ops AS (
    SELECT id_operacao, id_filial,
        CONVERT(VARCHAR(36), id_turno) AS id_turno
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
)
SELECT
    ops.id_filial AS id_ponto_venda,
    ops.id_turno,
    fo.id_finalizador,
    fpv.nome AS meio_pagamento,
    COUNT(DISTINCT ops.id_operacao) AS qtd_vendas,
    SUM(ISNULL(fo.valor, 0)) AS total_pago
FROM ops
JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
GROUP BY ops.id_filial, ops.id_turno,
    fo.id_finalizador, fpv.nome
ORDER BY total_pago DESC
"@

# ═══════════════════════════════════════════════════════════════
# TEST 7: get_loja_operation_ids (deduplicação)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[7/9] IDs para deduplicação Loja..." -ForegroundColor Yellow

$R["7_loja_op_ids"] = Run-Query -Db $DB_GESTAO -Label "Op IDs Loja" -Query @"
SELECT op.id_operacao
FROM dbo.operacao_pdv op
WHERE op.operacao = 1
  AND op.cancelado = 0
  AND op.origem = 2
  AND op.data_hora_termino IS NOT NULL
  AND op.data_hora_termino >= '$dt_from_str'
  AND op.data_hora_termino < '$dt_to_str'
  AND op.id_filial = $ID_FILIAL
ORDER BY op.id_operacao
"@

# ═══════════════════════════════════════════════════════════════
# TEST 8: Snapshot combinado - últimas vendas de AMBOS canais
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[8/9] Snapshot Loja (get_loja_vendas_snapshot)..." -ForegroundColor Yellow

$R["8_snapshot_loja"] = Run-Query -Db $DB_GESTAO -Label "Snapshot Loja" -Query @"
SELECT TOP 10
    op.id_operacao,
    op.data_hora_inicio,
    op.data_hora_termino,
    DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_segundos,
    CONVERT(VARCHAR(36), op.id_turno) AS id_turno,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS qtd_itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0)
     FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total_itens,
    (SELECT TOP 1 uv.id_usuario
     FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS id_vendedor,
    (SELECT TOP 1 uv.nome
     FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS nome_vendedor
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.origem = 2
  AND op.data_hora_termino IS NOT NULL
  AND op.id_filial = $ID_FILIAL
ORDER BY op.data_hora_termino DESC
"@

# Comparação: snapshot PDV
$R["8_snapshot_pdv"] = Run-Query -Db $DB_PDV -Label "Snapshot PDV (comparação)" -Query @"
SELECT TOP 10
    op.id_operacao,
    op.data_hora_inicio,
    op.data_hora_termino,
    DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_segundos,
    CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
    t.sequencial AS turno_seq,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS qtd_itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0)
     FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) AS total_itens,
    (SELECT TOP 1 uv.id_usuario
     FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS id_vendedor,
    (SELECT TOP 1 uv.nome
     FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0) AS nome_vendedor
FROM dbo.operacao_pdv op
JOIN dbo.turno t ON t.id_turno = op.id_turno
WHERE t.id_ponto_venda = $ID_PDV
  AND op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
"@

# ═══════════════════════════════════════════════════════════════
# TEST 9: Validação de finalizador_pdv JOIN na Gestão
# (confirmar que a coluna é "nome" e que o JOIN funciona)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[9/9] Finalizador JOIN validation (Gestão)..." -ForegroundColor Yellow

$R["9_finalizador_join"] = Run-Query -Db $DB_GESTAO -Label "Finalizador JOIN Gestão" -Query @"
SELECT DISTINCT fo.id_finalizador, fpv.nome AS meio_pagamento
FROM dbo.finalizador_operacao_pdv fo
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
WHERE fo.id_operacao IN (
    SELECT TOP 20 id_operacao FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0 AND origem = 2
    ORDER BY data_hora_termino DESC
)
ORDER BY fo.id_finalizador
"@

# ═══════════════════════════════════════════════════════════════
# Output JSON
# ═══════════════════════════════════════════════════════════════
Write-Host "`n========================================" -ForegroundColor Cyan
$json = $R | ConvertTo-Json -Depth 5
Write-Host $json
Write-Host "========================================" -ForegroundColor Cyan

# Salvar
$outDir = Split-Path $MyInvocation.MyCommand.Path -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir "validacao_gestao.json"
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.Encoding]::UTF8)
Write-Host "  Salvo: $outFile" -ForegroundColor Green
