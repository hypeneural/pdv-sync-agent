# ==============================================================================
#  RAIO-X v4: HiperCaixa vs Hiper Loja vs Hiper Gestao
#  .NET SqlClient + schema discovery + correcoes de colunas
# ==============================================================================
$server = ".\HIPER"
$dbG = "Hiper"
$dbP = "HiperPdv"
$outFile = "C:\Users\Usuario\Desktop\maiscapinhas\chupacabra\pdv-sync-agent\scripts\raio_x_resultado.json"

function Q($db, $sql) {
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$server;Database=$db;Integrated Security=True;TrustServerCertificate=True"
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $sql
        $cmd.CommandTimeout = 60
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $ds = New-Object System.Data.DataSet
        [void]$adapter.Fill($ds)
        $conn.Close()
        if ($ds.Tables.Count -eq 0 -or $ds.Tables[0].Rows.Count -eq 0) { return @() }
        $results = @()
        foreach ($row in $ds.Tables[0].Rows) {
            $obj = [ordered]@{}
            foreach ($col in $ds.Tables[0].Columns) {
                $val = $row[$col.ColumnName]
                if ($val -is [System.DBNull]) { $val = $null }
                elseif ($val -is [byte[]]) { $val = [Convert]::ToBase64String($val) }
                elseif ($val -is [guid]) { $val = $val.ToString() }
                $obj[$col.ColumnName] = $val
            }
            $results += [PSCustomObject]$obj
        }
        return $results
    }
    catch {
        return @([PSCustomObject]@{ ERRO = $_.Exception.Message })
    }
}

Write-Host "`nGerando RAIO-X v4..." -ForegroundColor Cyan
$R = [ordered]@{
    _meta = [ordered]@{ maquina = $env:COMPUTERNAME; gerado = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
}

# === 0. SCHEMA DISCOVERY ===
Write-Host "  [0/13] Descobrindo schemas..." -ForegroundColor Gray
$R["0_schema_finalizador_pdv_PDV"] = @(Q $dbP "
SELECT c.name AS coluna, t.name AS tipo FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.finalizador_pdv') ORDER BY c.column_id")

$R["0_schema_finalizador_pdv_Gestao"] = @(Q $dbG "
SELECT c.name AS coluna, t.name AS tipo FROM sys.columns c
JOIN sys.types t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('dbo.finalizador_pdv') ORDER BY c.column_id")

$R["0_tem_origem_pdv"] = @(Q $dbP "
SELECT c.name FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.operacao_pdv') AND c.name = 'origem'")

$R["0_tem_origem_gestao"] = @(Q $dbG "
SELECT c.name FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.operacao_pdv') AND c.name = 'origem'")

# === 1. ORIGENS (so Gestao - PDV nao tem 'origem') ===
Write-Host "  [1/13] Origens de venda (Gestao)..." -ForegroundColor Yellow
$R["1_origens_gestao"] = @(Q $dbG "
SELECT op.origem, COUNT(*) AS total_vendas,
    CAST(SUM(sub.total) AS DECIMAL(18,2)) AS total_reais,
    MIN(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS primeira,
    MAX(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS ultima
FROM dbo.operacao_pdv op
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
GROUP BY op.origem ORDER BY op.origem")

$R["1_totais_pdv_sem_origem"] = @(Q $dbP "
SELECT COUNT(*) AS total_vendas,
    CAST(SUM(sub.total) AS DECIMAL(18,2)) AS total_reais,
    MIN(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS primeira,
    MAX(CONVERT(VARCHAR(10), op.data_hora_termino, 120)) AS ultima
FROM dbo.operacao_pdv op
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL")

# === 2. FINALIZADORES (SELECT * para descobrir colunas reais) ===
Write-Host "  [2/13] Finalizadores..." -ForegroundColor Yellow
$R["2_finalizadores_pdv"] = @(Q $dbP "SELECT * FROM dbo.finalizador_pdv ORDER BY id_finalizador")
$R["2_finalizadores_gestao"] = @(Q $dbG "SELECT TOP 20 * FROM dbo.finalizador_pdv ORDER BY id_finalizador")

# === 3. PAGAMENTOS 7 DIAS (sem join finalizador_pdv por agora) ===
Write-Host "  [3/13] Pagamentos 7d..." -ForegroundColor Yellow
$R["3_pagamentos_pdv"] = @(Q $dbP "
SELECT f.id_finalizador,
    COUNT(*) AS vezes, CAST(SUM(f.valor) AS DECIMAL(18,2)) AS total_bruto,
    CAST(SUM(ISNULL(f.valor_troco, 0)) AS DECIMAL(18,2)) AS total_troco
FROM dbo.finalizador_operacao_pdv f
JOIN dbo.operacao_pdv op ON op.id_operacao = f.id_operacao
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY f.id_finalizador ORDER BY total_bruto DESC")

$R["3_pagamentos_gestao"] = @(Q $dbG "
SELECT f.id_finalizador,
    COUNT(*) AS vezes, CAST(SUM(f.valor) AS DECIMAL(18,2)) AS total_bruto
FROM dbo.finalizador_operacao_pdv f
JOIN dbo.operacao_pdv op ON op.id_operacao = f.id_operacao
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY f.id_finalizador ORDER BY total_bruto DESC")

# === 4. VENDAS POR DIA E CANAL (Gestao) ===
Write-Host "  [4/13] Vendas por dia..." -ForegroundColor Yellow
$R["4_vendas_dia"] = @(Q $dbG "
SELECT CONVERT(VARCHAR(10), op.data_hora_termino, 120) AS dia,
    SUM(CASE WHEN op.origem IN (0,1) THEN 1 ELSE 0 END) AS vendas_pdv,
    SUM(CASE WHEN op.origem = 2 THEN 1 ELSE 0 END) AS vendas_loja,
    SUM(CASE WHEN op.origem NOT IN (0,1,2) OR op.origem IS NULL THEN 1 ELSE 0 END) AS vendas_outro,
    CAST(SUM(CASE WHEN op.origem IN (0,1) THEN sub.total ELSE 0 END) AS DECIMAL(18,2)) AS total_pdv,
    CAST(SUM(CASE WHEN op.origem = 2 THEN sub.total ELSE 0 END) AS DECIMAL(18,2)) AS total_loja
FROM dbo.operacao_pdv op
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
  AND op.data_hora_termino >= DATEADD(DAY, -7, GETDATE())
GROUP BY CONVERT(VARCHAR(10), op.data_hora_termino, 120) ORDER BY dia DESC")

# === 5. ULTIMAS VENDAS (Gestao - PDV channel) ===
Write-Host "  [5/13] Ultimas vendas..." -ForegroundColor Yellow
$R["5_ultimas_pdv_gestao"] = @(Q $dbG "
SELECT TOP 10 op.id_operacao, op.origem,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    op.id_filial, op.id_usuario,
    u.nome AS operador, sub.qtd_itens, CAST(sub.total AS DECIMAL(18,2)) AS total,
    op.ValorTroco AS troco, op.guid_operacao
FROM dbo.operacao_pdv op
LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
CROSS APPLY (SELECT COUNT(*) AS qtd_itens, ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL AND op.origem IN (0,1)
ORDER BY op.data_hora_termino DESC")

$R["5_ultimas_loja_gestao"] = @(Q $dbG "
SELECT TOP 10 op.id_operacao, op.origem,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    op.id_filial, op.id_usuario,
    u.nome AS operador, sub.qtd_itens, CAST(sub.total AS DECIMAL(18,2)) AS total,
    op.ValorTroco AS troco, op.guid_operacao
FROM dbo.operacao_pdv op
LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
CROSS APPLY (SELECT COUNT(*) AS qtd_itens, ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL AND op.origem = 2
ORDER BY op.data_hora_termino DESC")

# Ultimas vendas do HiperPdv (sem origem)
$R["5_ultimas_pdv_caixa"] = @(Q $dbP "
SELECT TOP 10 op.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    op.id_ponto_venda, op.id_usuario,
    u.nome AS operador, sub.qtd_itens, CAST(sub.total AS DECIMAL(18,2)) AS total,
    op.guid_operacao
FROM dbo.operacao_pdv op
LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
CROSS APPLY (SELECT COUNT(*) AS qtd_itens, ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0) sub
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC")

# === 6. DUPLICACAO ===
Write-Host "  [6/13] Duplicacao..." -ForegroundColor Yellow
$R["6_duplicacao"] = @(Q $dbG "
SELECT g.id_operacao, CONVERT(VARCHAR(19), g.data_hora_termino, 120) AS termino,
    g.origem, CAST(g_sub.total AS DECIMAL(18,2)) AS total, g.guid_operacao,
    CASE
        WHEN EXISTS (SELECT 1 FROM [$dbP].dbo.operacao_pdv p
            WHERE p.guid_operacao = g.guid_operacao AND p.guid_operacao IS NOT NULL
              AND LEN(p.guid_operacao) > 0 AND p.operacao = 1 AND p.cancelado = 0)
        THEN 'GUID_MATCH'
        WHEN EXISTS (SELECT 1 FROM [$dbP].dbo.operacao_pdv p
            WHERE ABS(DATEDIFF(SECOND, p.data_hora_termino, g.data_hora_termino)) <= 5
              AND p.operacao = 1 AND p.cancelado = 0)
        THEN 'HORARIO_MATCH'
        ELSE 'SEM_MATCH'
    END AS status_pdv
FROM dbo.operacao_pdv g
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = g.id_operacao AND i.cancelado = 0) g_sub
WHERE g.operacao = 1 AND g.cancelado = 0 AND g.origem = 2
  AND g.data_hora_termino >= DATEADD(DAY, -30, GETDATE())
ORDER BY g.data_hora_termino DESC")

# === 7. GUID MATCH (sem 'origem' no lado PDV) ===
Write-Host "  [7/13] GUID match..." -ForegroundColor Yellow
$R["7_guid_match"] = @(Q $dbG "
SELECT TOP 15 g.id_operacao AS id_gestao, p.id_operacao AS id_pdv,
    g.guid_operacao, g.origem AS origem_gestao,
    CONVERT(VARCHAR(19), g.data_hora_termino, 120) AS termino_gestao,
    CONVERT(VARCHAR(19), p.data_hora_termino, 120) AS termino_pdv,
    CAST(g_sub.total AS DECIMAL(18,2)) AS total_gestao,
    CAST(p_sub.total AS DECIMAL(18,2)) AS total_pdv
FROM dbo.operacao_pdv g
JOIN [$dbP].dbo.operacao_pdv p ON p.guid_operacao = g.guid_operacao
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM dbo.item_operacao_pdv i WHERE i.id_operacao = g.id_operacao AND i.cancelado = 0) g_sub
CROSS APPLY (SELECT ISNULL(SUM(i.valor_total_liquido), 0) AS total
    FROM [$dbP].dbo.item_operacao_pdv i WHERE i.id_operacao = p.id_operacao AND i.cancelado = 0) p_sub
WHERE g.operacao = 1 AND g.cancelado = 0
  AND g.guid_operacao IS NOT NULL AND LEN(g.guid_operacao) > 0
ORDER BY g.data_hora_termino DESC")

# === 8. TURNOS ===
Write-Host "  [8/13] Turnos..." -ForegroundColor Yellow
$R["8_turnos_gestao"] = @(Q $dbG "
SELECT TOP 10 CONVERT(VARCHAR(36), g.id_turno) AS id_turno,
    g.sequencial, g.fechado,
    CONVERT(VARCHAR(19), g.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), g.data_hora_termino, 120) AS termino,
    u.nome AS operador,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = g.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS vendas,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = g.id_turno AND op.operacao = 1 AND op.cancelado = 0 AND op.origem = 2) AS vendas_loja
FROM dbo.turno g
LEFT JOIN dbo.usuario u ON u.id_usuario = g.id_usuario
ORDER BY g.data_hora_inicio DESC")

# === 9. HIPERPDV TABELAS ===
Write-Host "  [9/13] Tabelas hiperpdv_..." -ForegroundColor Yellow
$R["9_hiperpdv_espelho"] = @(Q $dbG "
SELECT t.name AS tabela, p.rows AS registros
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name LIKE 'hiperpdv_%' ORDER BY t.name")

# === 10. VENDA 6,60 (corrigido ambiguous column) ===
Write-Host "  [10/13] Venda R$6,60..." -ForegroundColor Yellow
$R["10_venda_660_op"] = @(Q $dbG "
SELECT op.id_operacao, op.origem, op.id_filial, op.id_usuario,
    u.nome AS operador,
    CONVERT(VARCHAR(19), op.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS termino,
    op.guid_operacao, op.ValorTroco AS troco, op.valor_ajuste,
    CONVERT(VARCHAR(36), op.id_turno) AS id_turno
FROM dbo.operacao_pdv op
LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
WHERE op.id_operacao = 9799")

$R["10_venda_660_itens"] = @(Q $dbG "
SELECT i.id_produto, p.nome AS produto, i.quantidade_primaria AS qtd,
    i.valor_unitario_liquido AS preco, i.valor_total_liquido AS total,
    i.valor_desconto AS desconto, i.id_usuario_vendedor,
    u.nome AS vendedor
FROM dbo.item_operacao_pdv i
JOIN dbo.produto p ON p.id_produto = i.id_produto
LEFT JOIN dbo.usuario u ON u.id_usuario = i.id_usuario_vendedor
WHERE i.id_operacao = 9799 AND i.cancelado = 0")

$R["10_venda_660_pgto"] = @(Q $dbG "
SELECT f.id_finalizador, f.valor, f.parcela, f.documento
FROM dbo.finalizador_operacao_pdv f
WHERE f.id_operacao = 9799")

# === 11. TOTAIS ===
Write-Host "  [11/13] Totais..." -ForegroundColor Yellow
$R["11_totais_gestao"] = @(Q $dbG "
SELECT
    (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0) AS vendas_total,
    (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem IN (0,1)) AS vendas_pdv,
    (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2) AS vendas_loja,
    (SELECT COUNT(*) FROM dbo.turno) AS turnos,
    (SELECT COUNT(*) FROM dbo.usuario) AS usuarios,
    (SELECT COUNT(*) FROM dbo.filial WHERE ativa=1) AS filiais")

$R["11_totais_pdv"] = @(Q $dbP "
SELECT
    (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0) AS vendas,
    (SELECT COUNT(*) FROM dbo.turno) AS turnos,
    (SELECT COUNT(*) FROM dbo.usuario) AS usuarios,
    (SELECT COUNT(*) FROM dbo.ponto_venda) AS lojas")

# === 12. SYNC ===
Write-Host "  [12/13] Sync..." -ForegroundColor Yellow
$R["12_sync_config"] = @(Q $dbG "
SELECT api_url, ms_vendas_url, IntervaloDeSincronizacaoEmMinutos,
    envio_auditoria_em_minutos, sequencia_loja
FROM dbo.hiperloja_sync_config")

$R["12_sync_ultimos"] = @(Q $dbG "
SELECT TOP 5 Indice,
    CONVERT(VARCHAR(30), DataEHoraDeSolicitacao, 120) AS solicitado,
    SituacaoDoProcessamento AS status, Tipo
FROM dbo.hiperloja_sync_protocolo_sincronizacao
ORDER BY Indice DESC")

# === 13. VENDEDORES POR CANAL ===
Write-Host "  [13/13] Vendedores por canal..." -ForegroundColor Yellow
$R["13_vendedores_loja"] = @(Q $dbG "
SELECT i.id_usuario_vendedor, u.nome AS vendedor,
    COUNT(DISTINCT i.id_operacao) AS vendas, COUNT(*) AS itens,
    CAST(SUM(i.valor_total_liquido) AS DECIMAL(18,2)) AS total
FROM dbo.item_operacao_pdv i
JOIN dbo.operacao_pdv op ON op.id_operacao = i.id_operacao
LEFT JOIN dbo.usuario u ON u.id_usuario = i.id_usuario_vendedor
WHERE op.operacao = 1 AND op.cancelado = 0 AND i.cancelado = 0
  AND op.origem = 2 AND op.data_hora_termino >= DATEADD(DAY, -30, GETDATE())
GROUP BY i.id_usuario_vendedor, u.nome ORDER BY total DESC")

$R["13_vendedores_pdv"] = @(Q $dbG "
SELECT i.id_usuario_vendedor, u.nome AS vendedor,
    COUNT(DISTINCT i.id_operacao) AS vendas, COUNT(*) AS itens,
    CAST(SUM(i.valor_total_liquido) AS DECIMAL(18,2)) AS total
FROM dbo.item_operacao_pdv i
JOIN dbo.operacao_pdv op ON op.id_operacao = i.id_operacao
LEFT JOIN dbo.usuario u ON u.id_usuario = i.id_usuario_vendedor
WHERE op.operacao = 1 AND op.cancelado = 0 AND i.cancelado = 0
  AND op.origem IN (0,1) AND op.data_hora_termino >= DATEADD(DAY, -30, GETDATE())
GROUP BY i.id_usuario_vendedor, u.nome ORDER BY total DESC")

# === SALVAR ===
$json = $R | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($outFile, $json, [System.Text.Encoding]::UTF8)

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Salvo: $outFile" -ForegroundColor Green
Write-Host "  Tam: $((Get-Item $outFile).Length) bytes" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
Write-Host $json
