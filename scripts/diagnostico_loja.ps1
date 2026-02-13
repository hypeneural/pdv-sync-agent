# =============================================================
#  DIAGNOSTICO DE LOJA - PDV Sync Agent
#  Rode em cada PC de loja para identificar e comparar
#  Gera JSON organizado com dados da loja no topo
#  Inclui snapshot de turnos e vendas para verificacao webhook
# =============================================================
$server = ".\HIPER"
$db = "HiperPdv"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DIAGNOSTICO DE LOJA - PDV Sync Agent" -ForegroundColor Cyan
Write-Host "  Maquina: $env:COMPUTERNAME" -ForegroundColor Cyan
$dataStr = Get-Date -Format 'yyyy-MM-dd HH:mm'
Write-Host "  Data: $dataStr" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# Helper: executa query e retorna SEMPRE array de ordered hashtables
function Run-Query {
    param([string]$Query)
    $withHeader = sqlcmd -S $server -d $db -Q "SET NOCOUNT ON; $Query" -W -s "|"
    $headerLines = @($withHeader | Where-Object { $_ -and $_.Trim() -ne "" })
    if ($headerLines.Count -lt 2) { return , @() }

    $headers = $headerLines[0].Split("|") | ForEach-Object { $_.Trim() }
    $dataLines = @($headerLines | Select-Object -Skip 2)

    [System.Collections.ArrayList]$results = @()
    foreach ($line in $dataLines) {
        if (-not $line -or $line.Trim() -eq "") { continue }
        $values = $line.Split("|")
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $val = if ($i -lt $values.Count) { $values[$i].Trim() } else { "" }
            if ($val -eq "NULL") { $val = $null }
            $obj[$headers[$i]] = $val
        }
        [void]$results.Add($obj)
    }
    return , $results
}

# ===== COLETA DE DADOS =====
Write-Host "`n  Coletando dados..." -ForegroundColor Yellow

# Loja ativa (baseado em vendas 5 dias)
$lojaAtiva = Run-Query "
SELECT TOP 1
    pv.id_ponto_venda, pv.apelido, pv.nome_fantasia, pv.razao_social,
    pv.cnpj, pv.nome_cidade, pv.sigla_uf, pv.logradouro,
    pv.endereco_numero, pv.bairro, pv.cep,
    pv.fone1_ddd, pv.fone1_numero, pv.email,
    COUNT(*) AS vendas_5_dias
FROM dbo.operacao_pdv o
JOIN dbo.turno t ON t.id_turno = o.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE o.operacao = 1 AND o.cancelado = 0
  AND o.data_hora_termino >= DATEADD(DAY, -5, GETDATE())
GROUP BY pv.id_ponto_venda, pv.apelido, pv.nome_fantasia, pv.razao_social,
    pv.cnpj, pv.nome_cidade, pv.sigla_uf, pv.logradouro,
    pv.endereco_numero, pv.bairro, pv.cep, pv.fone1_ddd, pv.fone1_numero, pv.email
ORDER BY vendas_5_dias DESC
"
# Extrair dados da loja
$loja = $null
$lojaId = "0"
$lojaApelido = "desconhecida"
if ($lojaAtiva -and $lojaAtiva.Count -gt 0) {
    $loja = $lojaAtiva[0]
    $lojaId = $loja.id_ponto_venda
    $lojaApelido = $loja.apelido
}
Write-Host "  [OK] Loja ativa: $lojaApelido (id=$lojaId)" -ForegroundColor Green

# Vendas 5 e 30 dias desta loja
$vendas5dias = if ($loja) { $loja.vendas_5_dias } else { "0" }

$vendas30 = Run-Query "
SELECT
    pv.id_ponto_venda, pv.apelido,
    COUNT(*) AS vendas_30_dias
FROM dbo.operacao_pdv o
JOIN dbo.turno t ON t.id_turno = o.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE o.operacao = 1 AND o.cancelado = 0
  AND o.data_hora_termino >= DATEADD(DAY, -30, GETDATE())
GROUP BY pv.id_ponto_venda, pv.apelido
ORDER BY vendas_30_dias DESC
"
$vendas30dias = "0"
foreach ($v in $vendas30) {
    if ($v.id_ponto_venda -eq $lojaId) { $vendas30dias = $v.vendas_30_dias; break }
}
Write-Host "  [OK] Vendas: $vendas5dias (5d) / $vendas30dias (30d)" -ForegroundColor Green

# Operadores ativos (5 dias)
$operadores = Run-Query "
SELECT
    u.id_usuario, u.nome, u.login,
    COUNT(*) AS qtd_operacoes
FROM dbo.operacao_pdv o
JOIN dbo.turno t ON t.id_turno = o.id_turno
JOIN dbo.usuario u ON u.id_usuario = t.id_usuario
WHERE o.operacao = 1 AND o.cancelado = 0
  AND o.data_hora_termino >= DATEADD(DAY, -5, GETDATE())
GROUP BY u.id_usuario, u.nome, u.login
ORDER BY qtd_operacoes DESC
"
Write-Host "  [OK] Operadores: $($operadores.Count)" -ForegroundColor Green

# Vendedores ativos (5 dias)
$vendedores = Run-Query "
SELECT
    u.id_usuario, u.nome, u.login,
    COUNT(*) AS qtd_itens
FROM dbo.item_operacao_pdv oi
JOIN dbo.operacao_pdv o ON o.id_operacao = oi.id_operacao
JOIN dbo.turno t ON t.id_turno = o.id_turno
JOIN dbo.usuario u ON u.id_usuario = oi.id_usuario_vendedor
WHERE o.operacao = 1 AND o.cancelado = 0
  AND o.data_hora_termino >= DATEADD(DAY, -5, GETDATE())
  AND oi.cancelado = 0
GROUP BY u.id_usuario, u.nome, u.login
ORDER BY qtd_itens DESC
"
Write-Host "  [OK] Vendedores: $($vendedores.Count)" -ForegroundColor Green

# =============================================================
#  SNAPSHOT: ULTIMOS 10 TURNOS FECHADOS (DETALHADO)
#  Inclui responsavel real, vendas, valor total
# =============================================================
$turnosFechados = Run-Query "
SELECT TOP 10
    t.id_turno,
    t.sequencial,
    CASE WHEN t.fechado = 1 THEN 'FECHADO' ELSE 'ABERTO' END AS status,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS data_hora_inicio,
    CONVERT(VARCHAR(19), t.data_hora_termino, 120) AS data_hora_termino,
    DATEDIFF(MINUTE, t.data_hora_inicio, ISNULL(t.data_hora_termino, GETDATE())) AS duracao_minutos,
    CASE
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 12 THEN 'MATUTINO'
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 18 THEN 'VESPERTINO'
        ELSE 'NOTURNO'
    END AS periodo,
    t.id_ponto_venda,
    pv.apelido AS loja,
    t.id_usuario AS id_operador_sistema,
    u_op.nome AS operador_sistema,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0
    ) AS qtd_vendas,
    (SELECT ISNULL(SUM(it.valor_total_liquido), 0) FROM dbo.operacao_pdv op2
     JOIN dbo.item_operacao_pdv it ON it.id_operacao = op2.id_operacao
     WHERE op2.id_turno = t.id_turno AND op2.operacao = 1 AND op2.cancelado = 0
     AND it.cancelado = 0
    ) AS total_vendas,
    (SELECT COUNT(DISTINCT iv.id_usuario_vendedor)
     FROM dbo.operacao_pdv ov
     JOIN dbo.item_operacao_pdv iv ON iv.id_operacao = ov.id_operacao
     WHERE ov.id_turno = t.id_turno AND ov.operacao = 1 AND ov.cancelado = 0 AND iv.cancelado = 0
    ) AS qtd_vendedores,
    (SELECT TOP 1 uv.id_usuario
     FROM dbo.operacao_pdv ov2
     JOIN dbo.item_operacao_pdv iv2 ON iv2.id_operacao = ov2.id_operacao
     JOIN dbo.usuario uv ON uv.id_usuario = iv2.id_usuario_vendedor
     WHERE ov2.id_turno = t.id_turno AND ov2.operacao = 1 AND ov2.cancelado = 0 AND iv2.cancelado = 0
     GROUP BY uv.id_usuario ORDER BY COUNT(*) DESC
    ) AS id_responsavel,
    (SELECT TOP 1 uv.nome
     FROM dbo.operacao_pdv ov3
     JOIN dbo.item_operacao_pdv iv3 ON iv3.id_operacao = ov3.id_operacao
     JOIN dbo.usuario uv ON uv.id_usuario = iv3.id_usuario_vendedor
     WHERE ov3.id_turno = t.id_turno AND ov3.operacao = 1 AND ov3.cancelado = 0 AND iv3.cancelado = 0
     GROUP BY uv.id_usuario, uv.nome ORDER BY COUNT(*) DESC
    ) AS nome_responsavel
FROM dbo.turno t
LEFT JOIN dbo.usuario u_op ON u_op.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE t.fechado = 1
ORDER BY t.data_hora_inicio DESC
"
Write-Host "  [OK] Turnos fechados (snapshot): $($turnosFechados.Count)" -ForegroundColor Green

# Turno aberto atual (se existir)
$turnoAberto = Run-Query "
SELECT TOP 1
    t.id_turno,
    t.sequencial,
    'ABERTO' AS status,
    CONVERT(VARCHAR(19), t.data_hora_inicio, 120) AS data_hora_inicio,
    DATEDIFF(MINUTE, t.data_hora_inicio, GETDATE()) AS minutos_aberto,
    CASE
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 12 THEN 'MATUTINO'
        WHEN DATEPART(HOUR, t.data_hora_inicio) < 18 THEN 'VESPERTINO'
        ELSE 'NOTURNO'
    END AS periodo,
    t.id_ponto_venda,
    pv.apelido AS loja,
    t.id_usuario AS id_operador_sistema,
    u_op.nome AS operador_sistema,
    (SELECT COUNT(*) FROM dbo.operacao_pdv op
     WHERE op.id_turno = t.id_turno AND op.operacao = 1 AND op.cancelado = 0
    ) AS qtd_vendas,
    (SELECT ISNULL(SUM(it.valor_total_liquido), 0) FROM dbo.operacao_pdv op2
     JOIN dbo.item_operacao_pdv it ON it.id_operacao = op2.id_operacao
     WHERE op2.id_turno = t.id_turno AND op2.operacao = 1 AND op2.cancelado = 0
     AND it.cancelado = 0
    ) AS total_vendas,
    (SELECT TOP 1 uv.id_usuario
     FROM dbo.operacao_pdv ov2
     JOIN dbo.item_operacao_pdv iv2 ON iv2.id_operacao = ov2.id_operacao
     JOIN dbo.usuario uv ON uv.id_usuario = iv2.id_usuario_vendedor
     WHERE ov2.id_turno = t.id_turno AND ov2.operacao = 1 AND ov2.cancelado = 0 AND iv2.cancelado = 0
     GROUP BY uv.id_usuario ORDER BY COUNT(*) DESC
    ) AS id_responsavel,
    (SELECT TOP 1 uv.nome
     FROM dbo.operacao_pdv ov3
     JOIN dbo.item_operacao_pdv iv3 ON iv3.id_operacao = ov3.id_operacao
     JOIN dbo.usuario uv ON uv.id_usuario = iv3.id_usuario_vendedor
     WHERE ov3.id_turno = t.id_turno AND ov3.operacao = 1 AND ov3.cancelado = 0 AND iv3.cancelado = 0
     GROUP BY uv.id_usuario, uv.nome ORDER BY COUNT(*) DESC
    ) AS nome_responsavel
FROM dbo.turno t
LEFT JOIN dbo.usuario u_op ON u_op.id_usuario = t.id_usuario
LEFT JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
WHERE t.fechado = 0
  AND t.data_hora_inicio >= DATEADD(DAY, -7, GETDATE())
ORDER BY t.data_hora_inicio DESC
"
Write-Host "  [OK] Turno aberto: $(if ($turnoAberto -and $turnoAberto.Count -gt 0) { $turnoAberto[0].nome_responsavel } else { 'nenhum' })" -ForegroundColor Green

# =============================================================
#  SNAPSHOT: ULTIMAS 10 VENDAS (DETALHADO)
#  Para verificacao/conferencia no backend
# =============================================================
$snapshotVendas = Run-Query "
SELECT TOP 10
    op.id_operacao,
    CONVERT(VARCHAR(19), op.data_hora_inicio, 120) AS venda_inicio,
    CONVERT(VARCHAR(19), op.data_hora_termino, 120) AS venda_termino,
    DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_segundos,
    t.id_turno,
    t.sequencial AS turno_sequencial,
    t.id_ponto_venda,
    pv.apelido AS loja,
    t.id_usuario AS id_operador,
    u_op.nome AS operador,
    (SELECT COUNT(*) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0
    ) AS qtd_itens,
    (SELECT ISNULL(SUM(i.valor_total_liquido), 0) FROM dbo.item_operacao_pdv i
     WHERE i.id_operacao = op.id_operacao AND i.cancelado = 0
    ) AS total_itens,
    (SELECT TOP 1 uv.id_usuario FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0
    ) AS id_vendedor,
    (SELECT TOP 1 uv.nome FROM dbo.item_operacao_pdv iv
     JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
     WHERE iv.id_operacao = op.id_operacao AND iv.cancelado = 0
    ) AS vendedor
FROM dbo.operacao_pdv op
JOIN dbo.turno t ON t.id_turno = op.id_turno
JOIN dbo.ponto_venda pv ON pv.id_ponto_venda = t.id_ponto_venda
LEFT JOIN dbo.usuario u_op ON u_op.id_usuario = t.id_usuario
WHERE op.operacao = 1 AND op.cancelado = 0
  AND op.data_hora_termino IS NOT NULL
ORDER BY op.data_hora_termino DESC
"
Write-Host "  [OK] Vendas (snapshot): $($snapshotVendas.Count)" -ForegroundColor Green

# Todas as lojas
$todasLojas = Run-Query "
SELECT
    id_ponto_venda, apelido, nome_fantasia,
    razao_social, cnpj, nome_cidade, sigla_uf
FROM dbo.ponto_venda
ORDER BY id_ponto_venda
"
Write-Host "  [OK] Lojas: $($todasLojas.Count)" -ForegroundColor Green

# Todos os usuarios
$todosUsuarios = Run-Query "
SELECT
    id_usuario, nome, login,
    CASE WHEN ativo = 1 THEN 'SIM' ELSE 'NAO' END AS ativo
FROM dbo.usuario
ORDER BY id_usuario
"
$ativos = @($todosUsuarios | Where-Object { $_.ativo -eq 'SIM' }).Count
Write-Host "  [OK] Usuarios: $($todosUsuarios.Count) ($ativos ativos)" -ForegroundColor Green

# ===== RESUMO NO CONSOLE =====
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ESTA LOJA: $lojaApelido (id=$lojaId)" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Vendas 5 dias:      $vendas5dias"
Write-Host "  Vendas 30 dias:     $vendas30dias"
Write-Host "  Operadores ativos:  $($operadores.Count)"
Write-Host "  Vendedores ativos:  $($vendedores.Count)"
Write-Host "  Turnos fechados:    $($turnosFechados.Count) (snapshot)"
Write-Host "  Vendas recentes:    $($snapshotVendas.Count) (snapshot)"
Write-Host "  Lojas no banco:     $($todasLojas.Count)"
Write-Host "  Usuarios total:     $($todosUsuarios.Count) ($ativos ativos)"
Write-Host "  Maquina:            $env:COMPUTERNAME"
Write-Host "============================================================" -ForegroundColor Green

# ===== MONTAR JSON =====

# Bloco desta loja
$estaLoja = [ordered]@{
    id_ponto_venda = $lojaId
    apelido        = $lojaApelido
    nome_fantasia  = $null
    razao_social   = $null
    cnpj           = $null
    cidade         = $null
    uf             = $null
    endereco       = $null
    cep            = $null
    telefone       = $null
    email          = $null
    vendas_5_dias  = $vendas5dias
    vendas_30_dias = $vendas30dias
}
if ($loja) {
    $estaLoja.nome_fantasia = $loja.nome_fantasia
    $estaLoja.razao_social = $loja.razao_social
    $estaLoja.cnpj = $loja.cnpj
    $estaLoja.cidade = $loja.nome_cidade
    $estaLoja.uf = $loja.sigla_uf
    $estaLoja.endereco = "$($loja.logradouro), $($loja.endereco_numero) - $($loja.bairro)"
    $estaLoja.cep = $loja.cep
    $estaLoja.telefone = "($($loja.fone1_ddd)) $($loja.fone1_numero)"
    $estaLoja.email = $loja.email
}

# Montar turno aberto para o JSON
$turnoAbertoObj = $null
if ($turnoAberto -and $turnoAberto.Count -gt 0) {
    $ta = $turnoAberto[0]
    $turnoAbertoObj = [ordered]@{
        id_turno         = $ta.id_turno
        sequencial       = $ta.sequencial
        status           = "ABERTO"
        data_hora_inicio = $ta.data_hora_inicio
        minutos_aberto   = $ta.minutos_aberto
        periodo          = $ta.periodo
        loja             = $ta.loja
        operador_sistema = $ta.operador_sistema
        responsavel      = [ordered]@{
            id_usuario = $ta.id_responsavel
            nome       = $ta.nome_responsavel
        }
        qtd_vendas       = $ta.qtd_vendas
        total_vendas     = $ta.total_vendas
    }
}

$jsonOrdenado = [ordered]@{
    esta_loja              = $estaLoja
    operadores             = @($operadores)
    vendedores             = @($vendedores)
    turno_aberto           = $turnoAbertoObj
    snapshot_turnos        = @($turnosFechados)
    snapshot_vendas        = @($snapshotVendas)
    ranking_vendas_30_dias = @($vendas30)
    dados_gerais           = [ordered]@{
        total_lojas           = $todasLojas.Count
        total_usuarios        = $todosUsuarios.Count
        total_usuarios_ativos = $ativos
        todas_lojas           = @($todasLojas)
        todos_usuarios        = @($todosUsuarios)
    }
    meta                   = [ordered]@{
        maquina    = $env:COMPUTERNAME
        sql_server = $server
        database   = $db
        data_hora  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }
}

# Nome: ID-apelido.json
$nomeArquivo = $lojaApelido -replace '[^a-zA-Z0-9\-]', '_'
$nomeArquivo = $nomeArquivo -replace '__+', '_'
$nomeArquivo = $nomeArquivo.Trim('_')
$jsonFile = "${lojaId}-${nomeArquivo}.json"

$jsonOrdenado | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonFile -Encoding UTF8
$jsonSize = [math]::Round((Get-Item $jsonFile).Length / 1KB, 1)

Write-Host ""
Write-Host "  JSON gerado: $jsonFile ($jsonSize KB)" -ForegroundColor Cyan
Write-Host "  Caminho: $(Resolve-Path $jsonFile)" -ForegroundColor Cyan
Write-Host ""

# Abrir no Bloco de Notas
Start-Process notepad.exe (Resolve-Path $jsonFile)
