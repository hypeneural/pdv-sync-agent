<#
.SYNOPSIS
  Validação das melhorias v3.0 do Agent antes do build.
  Testa as queries modificadas contra o banco real.
.DESCRIPTION
  Valida: troco ROW_NUMBER (PR-A5), tiebreaker (PR-A8),
  campos v3 turno (PR-A3), colunas existentes no banco.
  
  RODAR NA MAQUINA DA LOJA!
#>

$ErrorActionPreference = "Continue"

# ─── Config (mesmo dos outros scripts) ───
$SERVER = "localhost\HIPER"
$DB_PDV = "HiperPdv"
$DB_GESTAO = "Hiper"
$ID_FILIAL = 10
$ID_PDV = 10

$dt_to = Get-Date
$dt_from = $dt_to.AddDays(-7)
$dt_from_str = $dt_from.ToString("yyyy-MM-dd HH:mm:ss")
$dt_to_str = $dt_to.ToString("yyyy-MM-dd HH:mm:ss")

$PASS = 0
$FAIL = 0

function Run-SqlQuery {
    param([string]$Db, [string]$Query, [string]$Label)
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
        return $rows
    }
    catch {
        Write-Host "  ❌ $Label → ERRO: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        $script:PASS++
        Write-Host "  ✅ $Name" -ForegroundColor Green
    }
    else {
        $script:FAIL++
        $msg = "  ❌ $Name"
        if ($Detail) { $msg += " — $Detail" }
        Write-Host $msg -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  VALIDAÇÃO PRE-BUILD v3.0 — Queries SQL" -ForegroundColor Cyan
Write-Host "  Maquina: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  Bancos: $DB_PDV + $DB_GESTAO @ $SERVER" -ForegroundColor Cyan
Write-Host "  Window: $dt_from_str → $dt_to_str (7 dias)" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════
# TEST 1: Conexão aos dois bancos
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[1/8] Conexão aos bancos..." -ForegroundColor Yellow

$pdvOk = Run-SqlQuery -Db $DB_PDV -Label "PDV" -Query "SELECT DB_NAME() AS banco"
Check "Conexão HiperPdv" ($pdvOk -ne $null -and $pdvOk.Count -gt 0)

$gestaoOk = Run-SqlQuery -Db $DB_GESTAO -Label "Gestão" -Query "SELECT DB_NAME() AS banco"
Check "Conexão Hiper (Gestão)" ($gestaoOk -ne $null -and $gestaoOk.Count -gt 0)

# ═══════════════════════════════════════════════════════════════
# TEST 2: PR-A5 — Troco ROW_NUMBER (query nova)
# Verifica que o troco só vai para o 1º finalizador de cada venda
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[2/8] PR-A5: Troco ROW_NUMBER (vendas Loja)..." -ForegroundColor Yellow

$trocoResults = Run-SqlQuery -Db $DB_GESTAO -Label "Troco ROW_NUMBER" -Query @"
WITH ops AS (
    SELECT id_operacao, ISNULL(ValorTroco, 0) AS valor_troco_op
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
),
pagamentos AS (
    SELECT
        fo.id_finalizador_operacao_pdv AS line_id,
        fo.id_operacao,
        fo.id_finalizador,
        fpv.nome AS meio_pagamento,
        fo.valor,
        ops.valor_troco_op,
        fo.parcela,
        ROW_NUMBER() OVER (
            PARTITION BY fo.id_operacao
            ORDER BY fo.id_finalizador ASC
        ) AS rn
    FROM ops
    JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
    LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
)
SELECT
    line_id,
    id_operacao,
    id_finalizador,
    meio_pagamento,
    valor,
    CASE WHEN rn = 1 THEN valor_troco_op ELSE 0 END AS valor_troco,
    parcela,
    rn
FROM pagamentos
ORDER BY id_operacao, id_finalizador
"@

if ($trocoResults -ne $null) {
    Check "Query troco ROW_NUMBER executa sem erro" $true
    Check "Retornou registros" ($trocoResults.Count -gt 0) "Sem vendas Loja nos últimos 7 dias"

    if ($trocoResults.Count -gt 0) {
        # Verificar: nenhuma linha com rn > 1 deve ter troco > 0
        $trocoErrado = @($trocoResults | Where-Object { $_.rn -gt 1 -and $_.valor_troco -gt 0 })
        Check "Troco zerado em rn > 1 (nenhum duplicado)" ($trocoErrado.Count -eq 0) `
            "Encontrados $($trocoErrado.Count) registros com troco indevido"

        # Mostrar amostra de vendas com múltiplos finalizadores
        $multiPay = $trocoResults | Group-Object id_operacao | Where-Object { $_.Count -gt 1 }
        Write-Host "     → Vendas com 2+ finalizadores: $($multiPay.Count)" -ForegroundColor DarkGray
        
        if ($multiPay.Count -gt 0) {
            $sample = $multiPay | Select-Object -First 3
            foreach ($group in $sample) {
                Write-Host "     → Venda #$($group.Name):" -ForegroundColor DarkGray
                foreach ($row in $group.Group) {
                    $trocoStr = if ($row.valor_troco -gt 0) { "R$ $($row.valor_troco)" } else { "R$ 0.00" }
                    Write-Host "       rn=$($row.rn) | $($row.meio_pagamento) | valor=$($row.valor) | troco=$trocoStr" -ForegroundColor DarkGray
                }
            }
        }
    }
}
else {
    Check "Query troco ROW_NUMBER executa" $false "Erro na query"
}

# ═══════════════════════════════════════════════════════════════
# TEST 3: PR-A5 — Comparação ANTES vs DEPOIS do fix
# Mostra quanto troco estava sendo duplicado
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[3/8] PR-A5: Impacto do fix (antes vs depois)..." -ForegroundColor Yellow

$impacto = Run-SqlQuery -Db $DB_GESTAO -Label "Impacto troco" -Query @"
WITH ops AS (
    SELECT id_operacao, ISNULL(ValorTroco, 0) AS valor_troco_op
    FROM dbo.operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND origem = 2
      AND data_hora_termino IS NOT NULL
      AND data_hora_termino >= '$dt_from_str'
      AND data_hora_termino < '$dt_to_str'
      AND id_filial = $ID_FILIAL
      AND ValorTroco > 0
),
pagamentos AS (
    SELECT fo.id_operacao, ops.valor_troco_op,
        COUNT(*) AS qtd_finalizadores,
        ROW_NUMBER() OVER (PARTITION BY fo.id_operacao ORDER BY fo.id_finalizador) AS rn
    FROM ops
    JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao
    GROUP BY fo.id_operacao, ops.valor_troco_op, fo.id_finalizador
)
SELECT
    COUNT(DISTINCT id_operacao) AS vendas_com_troco,
    SUM(CASE WHEN rn = 1 THEN valor_troco_op ELSE 0 END) AS troco_correto,
    SUM(valor_troco_op) AS troco_antigo_duplicado,
    SUM(valor_troco_op) - SUM(CASE WHEN rn = 1 THEN valor_troco_op ELSE 0 END) AS diferenca
FROM pagamentos
"@

if ($impacto -ne $null -and $impacto.Count -gt 0) {
    $i = $impacto[0]
    Write-Host "     → Vendas com troco: $($i.vendas_com_troco)" -ForegroundColor DarkGray
    Write-Host "     → Troco real (corrigido):  R$ $($i.troco_correto)" -ForegroundColor Green
    Write-Host "     → Troco antigo (duplicado): R$ $($i.troco_antigo_duplicado)" -ForegroundColor Red
    Write-Host "     → Excesso removido:         R$ $($i.diferenca)" -ForegroundColor Yellow
    Check "Cálculo de impacto OK" $true
}

# ═══════════════════════════════════════════════════════════════
# TEST 4: PR-A8 — Tiebreaker (responsável do turno)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[4/8] PR-A8: Tiebreaker responsável turno (PDV)..." -ForegroundColor Yellow

$tiebreaker = Run-SqlQuery -Db $DB_PDV -Label "Tiebreaker" -Query @"
SELECT TOP 5
    t.id_turno,
    t.sequencial,
    uv.id_usuario,
    uv.nome,
    COUNT(*) AS itens_vendidos,
    SUM(iv.valor_total_liquido) AS total_vendido
FROM dbo.turno t
JOIN dbo.operacao_pdv ov ON ov.id_turno = t.id_turno
JOIN dbo.item_operacao_pdv iv ON iv.id_operacao = ov.id_operacao
JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
WHERE t.id_ponto_venda = $ID_PDV
  AND ov.operacao = 1 AND ov.cancelado = 0 AND iv.cancelado = 0
  AND t.data_hora_inicio >= '$dt_from_str'
GROUP BY t.id_turno, t.sequencial, uv.id_usuario, uv.nome
ORDER BY t.sequencial DESC, COUNT(*) DESC, SUM(iv.valor_total_liquido) DESC, uv.id_usuario ASC
"@

if ($tiebreaker -ne $null) {
    Check "Query tiebreaker executa sem erro" $true
    Check "Retornou resultados" ($tiebreaker.Count -gt 0) "Sem turnos com vendas nos últimos 7 dias"
    if ($tiebreaker.Count -gt 0) {
        Write-Host "     → Top vendedor: $($tiebreaker[0].nome) | itens=$($tiebreaker[0].itens_vendidos) | total=R$ $($tiebreaker[0].total_vendido)" -ForegroundColor DarkGray
    }
}
else {
    Check "Query tiebreaker executa" $false "Erro na query"
}

# ═══════════════════════════════════════════════════════════════
# TEST 5: PR-A3 — Campos v3 do TurnoDetail (cálculo de período)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[5/8] PR-A3: Campos v3 TurnoDetail (PDV)..." -ForegroundColor Yellow

$turnosV3 = Run-SqlQuery -Db $DB_PDV -Label "TurnoDetail v3" -Query @"
SELECT TOP 5
    t.sequencial,
    CASE WHEN t.fechado = 1 THEN 'FECHADO' ELSE 'ABERTO' END AS status,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS inicio,
    CONVERT(VARCHAR(19), t.data_hora_termino, 120) AS termino,
    DATEDIFF(MINUTE, t.data_hora_inicio, ISNULL(t.data_hora_termino, GETDATE())) AS duracao_minutos,
    CASE
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 12 THEN 'MATUTINO'
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 18 THEN 'VESPERTINO'
        ELSE 'NOTURNO'
    END AS periodo,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0) AS qtd_vendas,
    (SELECT ISNULL(SUM(it.valor_total_liquido), 0)
     FROM dbo.operacao_pdv op2
     JOIN dbo.item_operacao_pdv it ON it.id_operacao = op2.id_operacao
     WHERE op2.id_turno = t.id_turno AND op2.operacao = 1 AND op2.cancelado = 0
     AND it.cancelado = 0) AS total_vendas,
    (SELECT COUNT(DISTINCT it2.id_usuario_vendedor)
     FROM dbo.operacao_pdv op3
     JOIN dbo.item_operacao_pdv it2 ON it2.id_operacao = op3.id_operacao
     WHERE op3.id_turno = t.id_turno AND op3.operacao = 1 AND op3.cancelado = 0
     AND it2.cancelado = 0 AND it2.id_usuario_vendedor IS NOT NULL) AS qtd_vendedores,
    u.nome AS operador
FROM dbo.turno t
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
WHERE t.id_ponto_venda = $ID_PDV
  AND t.data_hora_inicio >= '$dt_from_str'
ORDER BY t.data_hora_inicio DESC
"@

if ($turnosV3 -ne $null) {
    Check "Query campos v3 executa sem erro" $true
    Check "Retornou turnos" ($turnosV3.Count -gt 0) "Sem turnos nos últimos 7 dias"
    
    if ($turnosV3.Count -gt 0) {
        Write-Host "     → Amostra de turnos com campos v3:" -ForegroundColor DarkGray
        foreach ($t in $turnosV3) {
            Write-Host "       seq=$($t.sequencial) | $($t.status) | $($t.periodo) | duracao=$($t.duracao_minutos)min | vendas=$($t.qtd_vendas) | total=R$ $($t.total_vendas) | vendedores=$($t.qtd_vendedores) | op=$($t.operador)" -ForegroundColor DarkGray
        }
    }
}
else {
    Check "Query campos v3" $false "Erro na query"
}

# ═══════════════════════════════════════════════════════════════
# TEST 6: Verificar colunas existem nas tabelas
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[6/8] Colunas críticas nas tabelas..." -ForegroundColor Yellow

$colunas = @(
    @{ Db = $DB_PDV; Tabela = "operacao_pdv"; Coluna = "id_turno" },
    @{ Db = $DB_PDV; Tabela = "operacao_pdv"; Coluna = "data_hora_termino" },
    @{ Db = $DB_PDV; Tabela = "item_operacao_pdv"; Coluna = "id_usuario_vendedor" },
    @{ Db = $DB_PDV; Tabela = "item_operacao_pdv"; Coluna = "valor_total_liquido" },
    @{ Db = $DB_PDV; Tabela = "finalizador_operacao_pdv"; Coluna = "id_finalizador_operacao_pdv" },
    @{ Db = $DB_GESTAO; Tabela = "operacao_pdv"; Coluna = "ValorTroco" },
    @{ Db = $DB_GESTAO; Tabela = "operacao_pdv"; Coluna = "origem" },
    @{ Db = $DB_GESTAO; Tabela = "finalizador_operacao_pdv"; Coluna = "id_finalizador_operacao_pdv" },
    @{ Db = $DB_GESTAO; Tabela = "finalizador_pdv"; Coluna = "nome" }
)

foreach ($c in $colunas) {
    $result = Run-SqlQuery -Db $c.Db -Label "$($c.Tabela).$($c.Coluna)" -Query @"
SELECT COUNT(*) AS existe
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = '$($c.Tabela)' AND COLUMN_NAME = '$($c.Coluna)'
"@
    $existe = ($result -ne $null -and $result.Count -gt 0 -and $result[0].existe -gt 0)
    Check "[$($c.Db)].$($c.Tabela).$($c.Coluna)" $existe "Coluna não encontrada!"
}

# ═══════════════════════════════════════════════════════════════
# TEST 7: Queries PDV (existentes — confirmar que não quebraram)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[7/8] Queries PDV (regressão)..." -ForegroundColor Yellow

$pdvItems = Run-SqlQuery -Db $DB_PDV -Label "get_sale_items" -Query @"
SELECT TOP 5 it.id_item_operacao_pdv AS line_id, it.item AS line_no,
    it.id_produto, it.quantidade_primaria AS qtd, it.valor_total_liquido AS total
FROM dbo.item_operacao_pdv it
JOIN dbo.operacao_pdv op ON op.id_operacao = it.id_operacao
JOIN dbo.turno t ON t.id_turno = op.id_turno
WHERE t.id_ponto_venda = $ID_PDV
  AND op.operacao = 1 AND op.cancelado = 0 AND it.cancelado = 0
  AND op.data_hora_termino >= '$dt_from_str'
ORDER BY op.data_hora_termino DESC
"@
Check "get_sale_items (PDV)" ($pdvItems -ne $null -and $pdvItems.Count -gt 0) "Sem itens"

$pdvPayments = Run-SqlQuery -Db $DB_PDV -Label "get_sale_payments" -Query @"
SELECT TOP 5 fo.id_finalizador_operacao_pdv AS line_id, fo.id_finalizador,
    fpv.nome AS meio_pagamento, fo.valor, ISNULL(fo.valor_troco, 0) AS troco
FROM dbo.finalizador_operacao_pdv fo
JOIN dbo.operacao_pdv op ON op.id_operacao = fo.id_operacao
JOIN dbo.turno t ON t.id_turno = op.id_turno
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
WHERE t.id_ponto_venda = $ID_PDV
  AND op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino >= '$dt_from_str'
ORDER BY op.data_hora_termino DESC
"@
Check "get_sale_payments (PDV)" ($pdvPayments -ne $null -and $pdvPayments.Count -gt 0) "Sem pagamentos"

# ═══════════════════════════════════════════════════════════════
# TEST 8: Queries Gestão Loja (confirmar que não quebraram)
# ═══════════════════════════════════════════════════════════════
Write-Host "`n[8/8] Queries Gestão Loja (regressão)..." -ForegroundColor Yellow

$lojaItems = Run-SqlQuery -Db $DB_GESTAO -Label "get_loja_sale_items" -Query @"
SELECT TOP 5 it.id_item_operacao_pdv AS line_id, it.item AS line_no,
    it.id_produto, p.nome, it.quantidade_primaria AS qtd, it.valor_total_liquido AS total
FROM dbo.item_operacao_pdv it
JOIN dbo.operacao_pdv op ON op.id_operacao = it.id_operacao
JOIN dbo.produto p ON p.id_produto = it.id_produto
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.origem = 2
  AND it.cancelado = 0
  AND op.data_hora_termino >= '$dt_from_str'
  AND op.id_filial = $ID_FILIAL
ORDER BY op.data_hora_termino DESC
"@
Check "get_loja_sale_items (Gestão)" ($lojaItems -ne $null) "Erro ou sem dados"

$lojaPayments = Run-SqlQuery -Db $DB_GESTAO -Label "get_loja_sale_payments" -Query @"
SELECT TOP 5 fo.id_finalizador_operacao_pdv AS line_id, fo.id_finalizador,
    fpv.nome AS meio, fo.valor
FROM dbo.finalizador_operacao_pdv fo
JOIN dbo.operacao_pdv op ON op.id_operacao = fo.id_operacao
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.origem = 2
  AND op.data_hora_termino >= '$dt_from_str'
  AND op.id_filial = $ID_FILIAL
ORDER BY op.data_hora_termino DESC
"@
Check "get_loja_sale_payments (Gestão)" ($lojaPayments -ne $null) "Erro ou sem dados"

# ═══════════════════════════════════════════════════════════════
# RESULTADO FINAL
# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RESULTADO FINAL" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ✅ PASSOU:  $PASS" -ForegroundColor Green
Write-Host "  ❌ FALHOU:  $FAIL" -ForegroundColor Red
Write-Host "  ─────────────────────────" -ForegroundColor DarkGray

if ($FAIL -eq 0) {
    Write-Host ""
    Write-Host "  🚀 TODAS AS QUERIES VALIDADAS! Pode buildar!" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "  ⛔ $FAIL FALHA(S) — Corrigir antes de buildar!" -ForegroundColor Red
}
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
