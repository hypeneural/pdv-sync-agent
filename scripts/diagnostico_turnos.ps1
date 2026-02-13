# ═══════════════════════════════════════════════════════════════
# DIAGNÓSTICO DE TURNOS PDV vs GESTÃO
# Executa no SQL Server local da loja para verificar se os
# id_turno são compartilhados entre HiperPdv e Hiper (Gestão).
#
# USO: .\diagnostico_turnos.ps1
# SAÍDA: diagnostico_turnos_resultado.txt (abre automaticamente)
# ═══════════════════════════════════════════════════════════════

$ErrorActionPreference = "Continue"
$OutputFile = Join-Path $PSScriptRoot "diagnostico_turnos_resultado.txt"

# ── Configuração de conexão ──
$Server = "localhost"
$User = "sa"
$Pass = "sasa"
$DbPdv = "HiperPdv"
$DbGestao = "Hiper"

function Run-Query {
    param(
        [string]$Database,
        [string]$Query
    )
    try {
        $connStr = "Server=$Server;Database=$Database;User Id=$User;Password=$Pass;TrustServerCertificate=True;Connection Timeout=10;"
        $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 30
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $ds = New-Object System.Data.DataSet
        [void]$adapter.Fill($ds)
        $conn.Close()
        return $ds.Tables[0]
    }
    catch {
        return "ERRO: $($_.Exception.Message)"
    }
}

function Write-Section {
    param([string]$Title)
    $sep = "=" * 70
    "$sep" | Out-File $OutputFile -Append
    "  $Title" | Out-File $OutputFile -Append
    "$sep" | Out-File $OutputFile -Append
}

function Write-Table {
    param($Data, [string]$Label)
    if ($Data -is [string]) {
        "  $Label => $Data" | Out-File $OutputFile -Append
        return
    }
    if ($null -eq $Data -or $Data.Rows.Count -eq 0) {
        "  $Label => (VAZIO - 0 resultados)" | Out-File $OutputFile -Append
        return
    }
    "" | Out-File $OutputFile -Append
    "  $Label ($($Data.Rows.Count) resultado(s)):" | Out-File $OutputFile -Append
    $Data | Format-Table -AutoSize | Out-String | Out-File $OutputFile -Append
}

# ── Limpar arquivo anterior ──
"" | Set-Content $OutputFile
"DIAGNÓSTICO DE TURNOS - PDV vs GESTÃO" | Out-File $OutputFile -Append
"Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $OutputFile -Append
"Servidor: $Server" | Out-File $OutputFile -Append
"Machine: $env:COMPUTERNAME" | Out-File $OutputFile -Append
"" | Out-File $OutputFile -Append

# ═══════════════════════════════════════════
# TESTE 1: Conectividade
# ═══════════════════════════════════════════
Write-Section "TESTE 1: CONECTIVIDADE"

$testPdv = Run-Query -Database $DbPdv -Query "SELECT 1 AS ok"
$testGestao = Run-Query -Database $DbGestao -Query "SELECT 1 AS ok"

if ($testPdv -is [string]) {
    "  HiperPdv: FALHA - $testPdv" | Out-File $OutputFile -Append
}
else {
    "  HiperPdv: OK" | Out-File $OutputFile -Append
}

if ($testGestao -is [string]) {
    "  Gestão: FALHA - $testGestao" | Out-File $OutputFile -Append
}
else {
    "  Gestão: OK" | Out-File $OutputFile -Append
}

# ═══════════════════════════════════════════
# TESTE 2: Schema da tabela turno em ambos os DBs
# ═══════════════════════════════════════════
Write-Section "TESTE 2: COLUNAS DA TABELA TURNO"

$colsPdv = Run-Query -Database $DbPdv -Query "
    SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'turno'
    ORDER BY ORDINAL_POSITION
"
Write-Table $colsPdv "Colunas turno (HiperPdv)"

$colsGestao = Run-Query -Database $DbGestao -Query "
    SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'turno'
    ORDER BY ORDINAL_POSITION
"
Write-Table $colsGestao "Colunas turno (Gestão)"

# ═══════════════════════════════════════════
# TESTE 3: Últimos 15 turnos em CADA banco
# ═══════════════════════════════════════════
Write-Section "TESTE 3: ÚLTIMOS 15 TURNOS EM CADA BANCO"

$turnosPdv = Run-Query -Database $DbPdv -Query "
    SELECT TOP 15
        CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
        t.id_ponto_venda,
        t.sequencial,
        t.fechado,
        t.data_hora_inicio,
        t.data_hora_termino,
        t.id_usuario,
        u.nome AS nome_usuario,
        u.login AS login_usuario,
        DATEDIFF(MINUTE, t.data_hora_inicio, ISNULL(t.data_hora_termino, GETDATE())) AS duracao_min
    FROM dbo.turno t
    LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
    ORDER BY t.data_hora_inicio DESC
"
Write-Table $turnosPdv "Últimos turnos (HiperPdv)"

$turnosGestao = Run-Query -Database $DbGestao -Query "
    SELECT TOP 15
        CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
        t.id_ponto_venda,
        t.sequencial,
        t.fechado,
        t.data_hora_inicio,
        t.data_hora_termino,
        t.id_usuario,
        u.nome AS nome_usuario,
        u.login AS login_usuario,
        DATEDIFF(MINUTE, t.data_hora_inicio, ISNULL(t.data_hora_termino, GETDATE())) AS duracao_min
    FROM dbo.turno t
    LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
    ORDER BY t.data_hora_inicio DESC
"
Write-Table $turnosGestao "Últimos turnos (Gestão)"

# ═══════════════════════════════════════════
# TESTE 4 (PRINCIPAL): Comparação de id_turno entre os dois bancos
# ═══════════════════════════════════════════
Write-Section "TESTE 4 (PRINCIPAL): IDs DE TURNO COMPARTILHADOS?"

# Buscar últimos 20 turnos do PDV e verificar se cada um existe no Gestão
$comparisonPdv = Run-Query -Database $DbPdv -Query "
    SELECT TOP 20 CONVERT(VARCHAR(36), id_turno) AS id_turno
    FROM dbo.turno
    ORDER BY data_hora_inicio DESC
"

if ($comparisonPdv -isnot [string] -and $comparisonPdv.Rows.Count -gt 0) {
    $turnoIds = ($comparisonPdv.Rows | ForEach-Object { "'$($_.id_turno)'" }) -join ", "
    
    $foundInGestao = Run-Query -Database $DbGestao -Query "
        SELECT
            CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
            t.id_ponto_venda,
            t.sequencial,
            t.fechado,
            'ENCONTRADO_NO_GESTAO' AS status
        FROM dbo.turno t
        WHERE CONVERT(VARCHAR(36), t.id_turno) IN ($turnoIds)
        ORDER BY t.data_hora_inicio DESC
    "
    Write-Table $foundInGestao "Turnos do PDV que TAMBÉM existem no Gestão"

    if ($foundInGestao -isnot [string] -and $null -ne $foundInGestao) {
        $totalPdv = $comparisonPdv.Rows.Count
        $totalEncontrado = $foundInGestao.Rows.Count
        "" | Out-File $OutputFile -Append
        "  >>> RESULTADO: $totalEncontrado de $totalPdv turnos do PDV foram encontrados no Gestão" | Out-File $OutputFile -Append
        if ($totalEncontrado -eq $totalPdv) {
            "  >>> CONCLUSÃO: HIPÓTESE A CONFIRMADA - IDs são COMPARTILHADOS (replicados)" | Out-File $OutputFile -Append
        }
        elseif ($totalEncontrado -eq 0) {
            "  >>> CONCLUSÃO: HIPÓTESE B CONFIRMADA - IDs são DIFERENTES (independentes)" | Out-File $OutputFile -Append
        }
        else {
            "  >>> CONCLUSÃO: PARCIAL - Alguns IDs compartilhados, outros não ($totalEncontrado/$totalPdv)" | Out-File $OutputFile -Append
        }
    }
}
else {
    "  Não foi possível buscar turnos do PDV para comparação" | Out-File $OutputFile -Append
}

# ═══════════════════════════════════════════
# TESTE 5: Vendas LOJA (origem=2) e seus turnos
# ═══════════════════════════════════════════
Write-Section "TESTE 5: VENDAS LOJA (origem=2) E SEUS TURNOS"

# Verificar se operacao_pdv no Gestão tem coluna 'origem'
$hasOrigem = Run-Query -Database $DbGestao -Query "
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'operacao_pdv' AND COLUMN_NAME = 'origem'
"

if ($hasOrigem -isnot [string] -and $hasOrigem.Rows.Count -gt 0) {
    "  Coluna 'origem' existe em operacao_pdv (Gestão): SIM" | Out-File $OutputFile -Append

    $vendasLoja = Run-Query -Database $DbGestao -Query "
        SELECT TOP 15
            op.id_operacao,
            CONVERT(VARCHAR(36), op.id_turno) AS id_turno_loja,
            op.id_usuario,
            op.id_filial,
            op.data_hora_inicio,
            op.data_hora_termino,
            op.origem,
            u.nome AS nome_vendedor,
            u.login AS login_vendedor
        FROM dbo.operacao_pdv op
        LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
        WHERE op.operacao = 1 AND op.cancelado = 0 AND op.origem = 2
          AND op.data_hora_termino IS NOT NULL
        ORDER BY op.data_hora_termino DESC
    "
    Write-Table $vendasLoja "Últimas 15 vendas LOJA (origem=2)"

    # Pegar os id_turno das vendas Loja e verificar se existem na tabela turno do Gestão
    if ($vendasLoja -isnot [string] -and $vendasLoja.Rows.Count -gt 0) {
        $lojaTurnoIds = ($vendasLoja.Rows | ForEach-Object { "'$($_.id_turno_loja)'" } | Select-Object -Unique) -join ", "
        
        $turnoExistsGestao = Run-Query -Database $DbGestao -Query "
            SELECT
                CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
                t.sequencial, t.fechado, t.id_ponto_venda,
                t.data_hora_inicio, t.data_hora_termino,
                u.nome AS operador_nome
            FROM dbo.turno t
            LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
            WHERE CONVERT(VARCHAR(36), t.id_turno) IN ($lojaTurnoIds)
        "
        Write-Table $turnoExistsGestao "Turnos referenciados por vendas Loja (existem na tabela turno do Gestão?)"

        # E no PDV?
        $turnoExistsPdv = Run-Query -Database $DbPdv -Query "
            SELECT
                CONVERT(VARCHAR(36), t.id_turno) AS id_turno,
                t.sequencial, t.fechado, t.id_ponto_venda,
                t.data_hora_inicio, t.data_hora_termino,
                u.nome AS operador_nome
            FROM dbo.turno t
            LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
            WHERE CONVERT(VARCHAR(36), t.id_turno) IN ($lojaTurnoIds)
        "
        Write-Table $turnoExistsPdv "Mesmos turnos de vendas Loja - existem TAMBÉM no HiperPdv?"
    }
}
else {
    "  Coluna 'origem' NÃO existe em operacao_pdv (Gestão)" | Out-File $OutputFile -Append
    "  Verificando todas as vendas recentes..." | Out-File $OutputFile -Append
    
    $vendasGestao = Run-Query -Database $DbGestao -Query "
        SELECT TOP 15
            op.id_operacao,
            CONVERT(VARCHAR(36), op.id_turno) AS id_turno,
            op.id_usuario,
            op.data_hora_termino,
            u.nome AS nome_vendedor
        FROM dbo.operacao_pdv op
        LEFT JOIN dbo.usuario u ON u.id_usuario = op.id_usuario
        WHERE op.operacao = 1 AND op.cancelado = 0
          AND op.data_hora_termino IS NOT NULL
        ORDER BY op.data_hora_termino DESC
    "
    Write-Table $vendasGestao "Últimas 15 vendas no Gestão (sem filtro origem)"
}

# ═══════════════════════════════════════════
# TESTE 6: Contadores gerais
# ═══════════════════════════════════════════
Write-Section "TESTE 6: CONTADORES GERAIS"

$countsPdv = Run-Query -Database $DbPdv -Query "
    SELECT
        (SELECT COUNT(*) FROM dbo.turno) AS total_turnos,
        (SELECT COUNT(*) FROM dbo.turno WHERE fechado = 1) AS turnos_fechados,
        (SELECT COUNT(*) FROM dbo.turno WHERE fechado = 0) AS turnos_abertos,
        (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao = 1 AND cancelado = 0) AS total_vendas,
        (SELECT COUNT(DISTINCT id_usuario) FROM dbo.operacao_pdv WHERE operacao = 1 AND cancelado = 0) AS vendedores_distintos,
        (SELECT COUNT(*) FROM dbo.usuario) AS total_usuarios,
        (SELECT COUNT(*) FROM dbo.ponto_venda) AS total_pontos_venda
"
Write-Table $countsPdv "Contadores HiperPdv"

$countsGestao = Run-Query -Database $DbGestao -Query "
    SELECT
        (SELECT COUNT(*) FROM dbo.turno) AS total_turnos,
        (SELECT COUNT(*) FROM dbo.turno WHERE fechado = 1) AS turnos_fechados,
        (SELECT COUNT(*) FROM dbo.turno WHERE fechado = 0) AS turnos_abertos,
        (SELECT COUNT(*) FROM dbo.operacao_pdv WHERE operacao = 1 AND cancelado = 0) AS total_vendas,
        (SELECT COUNT(DISTINCT id_usuario) FROM dbo.operacao_pdv WHERE operacao = 1 AND cancelado = 0) AS vendedores_distintos,
        (SELECT COUNT(*) FROM dbo.usuario) AS total_usuarios
"
Write-Table $countsGestao "Contadores Gestão"

# Vendas por origem no Gestão (se coluna existe)
if ($hasOrigem -isnot [string] -and $hasOrigem.Rows.Count -gt 0) {
    $byOrigem = Run-Query -Database $DbGestao -Query "
        SELECT
            origem,
            CASE origem
                WHEN 0 THEN 'PDV (Caixa)'
                WHEN 1 THEN 'Desconhecido'
                WHEN 2 THEN 'Loja'
                ELSE 'Outro'
            END AS descricao,
            COUNT(*) AS total_vendas
        FROM dbo.operacao_pdv
        WHERE operacao = 1 AND cancelado = 0
        GROUP BY origem
        ORDER BY origem
    "
    Write-Table $byOrigem "Vendas por ORIGEM no Gestão"
}

# ═══════════════════════════════════════════
# TESTE 7: Store info (ponto_venda)
# ═══════════════════════════════════════════
Write-Section "TESTE 7: INFORMAÇÕES DA LOJA"

$storeInfo = Run-Query -Database $DbPdv -Query "
    SELECT
        id_ponto_venda,
        CASE
            WHEN COL_LENGTH('dbo.ponto_venda','apelido') IS NOT NULL THEN apelido
            WHEN COL_LENGTH('dbo.ponto_venda','nome') IS NOT NULL THEN nome
            ELSE NULL
        END AS nome_loja,
        cnpj
    FROM dbo.ponto_venda
"
Write-Table $storeInfo "Pontos de venda (HiperPdv)"

# ═══════════════════════════════════════════
# TESTE 8: Fechamento (op=9) e Falta (op=4) - existem no Gestão?
# ═══════════════════════════════════════════
Write-Section "TESTE 8: OPERAÇÕES DE FECHAMENTO E FALTA"

$closurePdv = Run-Query -Database $DbPdv -Query "
    SELECT operacao,
        CASE operacao
            WHEN 1 THEN 'Venda'
            WHEN 4 THEN 'Falta Caixa'
            WHEN 9 THEN 'Fechamento Turno'
            ELSE CAST(operacao AS VARCHAR)
        END AS tipo,
        COUNT(*) AS total
    FROM dbo.operacao_pdv
    WHERE cancelado = 0
    GROUP BY operacao
    ORDER BY operacao
"
Write-Table $closurePdv "Operações por tipo (HiperPdv)"

$closureGestao = Run-Query -Database $DbGestao -Query "
    SELECT operacao,
        CASE operacao
            WHEN 1 THEN 'Venda'
            WHEN 4 THEN 'Falta Caixa'
            WHEN 9 THEN 'Fechamento Turno'
            ELSE CAST(operacao AS VARCHAR)
        END AS tipo,
        COUNT(*) AS total
    FROM dbo.operacao_pdv
    WHERE cancelado = 0
    GROUP BY operacao
    ORDER BY operacao
"
Write-Table $closureGestao "Operações por tipo (Gestão)"

# ═══════════════════════════════════════════
# TESTE 9: Finalizadores (meios de pagamento)
# ═══════════════════════════════════════════
Write-Section "TESTE 9: MEIOS DE PAGAMENTO"

$finalizadores = Run-Query -Database $DbPdv -Query "
    SELECT id_finalizador, nome
    FROM dbo.finalizador_pdv
    ORDER BY id_finalizador
"
Write-Table $finalizadores "Finalizadores (HiperPdv)"

# ═══════════════════════════════════════════
# FIM
# ═══════════════════════════════════════════
"" | Out-File $OutputFile -Append
Write-Section "FIM DO DIAGNÓSTICO"
"Arquivo gerado em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $OutputFile -Append

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DIAGNÓSTICO CONCLUÍDO!" -ForegroundColor Green
Write-Host "  Resultado salvo em:" -ForegroundColor Green
Write-Host "  $OutputFile" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Abrir o arquivo automaticamente
Start-Process notepad.exe $OutputFile
