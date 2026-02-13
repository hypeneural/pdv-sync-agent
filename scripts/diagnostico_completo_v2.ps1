<#
  DIAGNOSTICO COMPLETO PDV vs GESTAO v2
  Cole TUDO no PowerShell. Resultado em C:\diagnostico_completo.txt
#>
$Out = "C:\diagnostico_completo.txt"
$S = "localhost\HIPER"
$ErrorActionPreference = "Continue"

function Q($db, $q) { try { $c = New-Object System.Data.SqlClient.SqlConnection("Server=$S;Database=$db;Integrated Security=True;TrustServerCertificate=True;Connection Timeout=15;"); $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $q; $cmd.CommandTimeout = 60; $a = New-Object System.Data.SqlClient.SqlDataAdapter($cmd); $d = New-Object System.Data.DataSet; [void]$a.Fill($d); $c.Close(); if ($d.Tables.Count -gt 0) { return $d.Tables[0] }else { return $null } }catch { return "ERRO: $($_.Exception.Message)" } }
function H($t) { "`n$("="*70)`n  $t`n$("="*70)" | Out-File $Out -Append }
function L($m) { "  $m" | Out-File $Out -Append }
function T($d, $l) { if ($d -is [string]) { L "$l => $d" }elseif ($null -eq $d -or $d.Rows.Count -eq 0) { L "$l => (vazio)" }else { L "$l ($($d.Rows.Count) rows):"; $d | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Out-File $Out -Append } }

"" | Set-Content $Out
"DIAGNOSTICO COMPLETO PDV vs GESTAO v2" | Out-File $Out -Append
"Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $Out -Append
"Machine: $env:COMPUTERNAME" | Out-File $Out -Append
"Server: $S" | Out-File $Out -Append

# ═══════════════════════════════════════
H "1. CONECTIVIDADE E VERSAO SQL"
# ═══════════════════════════════════════
$info = Q "HiperPdv" "SELECT @@SERVERNAME AS servidor, @@VERSION AS versao"
if ($info -is [string]) { L "FALHA HiperPdv: $info" }else { L "Servidor: $($info.Rows[0].servidor)"; L "SQL: $($info.Rows[0].versao.Substring(0,80))..." }
$info2 = Q "Hiper" "SELECT DB_NAME() AS db"
if ($info2 -is [string]) { L "FALHA Gestao: $info2" }else { L "Gestao DB: OK" }

# ═══════════════════════════════════════
H "2. STORE INFO (ponto_venda)"
# ═══════════════════════════════════════
$pvCols = Q "HiperPdv" "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='ponto_venda' ORDER BY ORDINAL_POSITION"
if ($pvCols -isnot [string]) { L "Colunas ponto_venda: $(($pvCols.Rows|%{$_.COLUMN_NAME}) -join ', ')" }
T (Q "HiperPdv" "SELECT * FROM dbo.ponto_venda") "ponto_venda (HiperPdv)"

# Gestao: filiais
$filCols = Q "Hiper" "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('filial','ponto_venda','loja') ORDER BY TABLE_NAME"
T $filCols "Tabelas de loja no Gestao"
$hasFilial = Q "Hiper" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME='filial'"
if ($hasFilial -isnot [string] -and $hasFilial.Rows[0].n -gt 0) {
    $filialCols = Q "Hiper" "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='filial' ORDER BY ORDINAL_POSITION"
    if ($filialCols -isnot [string]) { L "Colunas filial: $(($filialCols.Rows|%{$_.COLUMN_NAME}) -join ', ')" }
    T (Q "Hiper" "SELECT * FROM dbo.filial") "filial (Gestao)"
}

# ═══════════════════════════════════════
H "3. SCHEMA TURNO - COMPARACAO DETALHADA"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_MAXIMUM_LENGTH AS max_len,IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='turno' ORDER BY ORDINAL_POSITION") "turno (HiperPdv)"
T (Q "Hiper" "SELECT COLUMN_NAME,DATA_TYPE,CHARACTER_MAXIMUM_LENGTH AS max_len,IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='turno' ORDER BY ORDINAL_POSITION") "turno (Gestao)"

# ═══════════════════════════════════════
H "4. SCHEMA OPERACAO_PDV - COMPARACAO DETALHADA"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' ORDER BY ORDINAL_POSITION") "operacao_pdv (HiperPdv)"
T (Q "Hiper" "SELECT COLUMN_NAME,DATA_TYPE,IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' ORDER BY ORDINAL_POSITION") "operacao_pdv (Gestao)"

# Verificação específica de colunas críticas
L ""
$critCols = @("origem", "id_filial", "id_ponto_venda", "ValorTroco", "id_turno")
foreach ($col in $critCols) {
    $ep = Q "HiperPdv" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' AND COLUMN_NAME='$col'"
    $eg = Q "Hiper" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' AND COLUMN_NAME='$col'"
    $pv = if ($ep -isnot [string] -and $ep.Rows[0].n -gt 0) { "SIM" }else { "NAO" }
    $gv = if ($eg -isnot [string] -and $eg.Rows[0].n -gt 0) { "SIM" }else { "NAO" }
    L "  operacao_pdv.$col => PDV=$pv | Gestao=$gv"
}

# ═══════════════════════════════════════
H "5. SCHEMA FINALIZADOR_OPERACAO_PDV"
# ═══════════════════════════════════════
$finCols = @("valor_troco", "parcela", "id_finalizador", "valor")
foreach ($col in $finCols) {
    $ep = Q "HiperPdv" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='finalizador_operacao_pdv' AND COLUMN_NAME='$col'"
    $eg = Q "Hiper" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='finalizador_operacao_pdv' AND COLUMN_NAME='$col'"
    $pv = if ($ep -isnot [string] -and $ep.Rows[0].n -gt 0) { "SIM" }else { "NAO" }
    $gv = if ($eg -isnot [string] -and $eg.Rows[0].n -gt 0) { "SIM" }else { "NAO" }
    L "  finalizador_operacao_pdv.$col => PDV=$pv | Gestao=$gv"
}

# ═══════════════════════════════════════
H "6. ULTIMOS 15 TURNOS - LADO A LADO"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT TOP 15 CONVERT(VARCHAR(36),t.id_turno) AS id_turno,t.id_ponto_venda AS id_pdv,t.sequencial AS seq,t.fechado,CONVERT(VARCHAR(19),t.data_hora_inicio,120) AS inicio,CONVERT(VARCHAR(19),t.data_hora_termino,120) AS termino,t.id_usuario,u.nome AS operador,u.login AS login_op FROM dbo.turno t LEFT JOIN dbo.usuario u ON u.id_usuario=t.id_usuario ORDER BY t.data_hora_inicio DESC") "turnos (HiperPdv)"

T (Q "Hiper" "SELECT TOP 15 CONVERT(VARCHAR(36),t.id_turno) AS id_turno,t.id_filial,t.sequencial AS seq,t.fechado,CONVERT(VARCHAR(19),t.data_hora_inicio,120) AS inicio,CONVERT(VARCHAR(19),t.data_hora_termino,120) AS termino,t.id_usuario,u.nome AS operador,u.login AS login_op FROM dbo.turno t LEFT JOIN dbo.usuario u ON u.id_usuario=t.id_usuario ORDER BY t.data_hora_inicio DESC") "turnos (Gestao)"

# ═══════════════════════════════════════
H "7. TESTE PRINCIPAL: TURNOS COMPARTILHADOS?"
# ═══════════════════════════════════════
# PDV -> Gestao
$tp = Q "HiperPdv" "SELECT TOP 30 CONVERT(VARCHAR(36),id_turno) AS id_turno FROM dbo.turno ORDER BY data_hora_inicio DESC"
if ($tp -isnot [string] -and $tp.Rows.Count -gt 0) {
    $ids = ($tp.Rows | % { "'$($_.id_turno)'" }) -join ","
    $match = Q "Hiper" "SELECT COUNT(*) AS encontrados FROM dbo.turno WHERE CONVERT(VARCHAR(36),id_turno) IN ($ids)"
    if ($match -isnot [string] -and $match.Rows.Count -gt 0) {
        $f = [int]$match.Rows[0].encontrados; $t = $tp.Rows.Count
        L "PDV->Gestao: $f de $t turnos encontrados"
        if ($f -eq $t) { L ">>> HIPOTESE A: IDs COMPARTILHADOS" }
        elseif ($f -eq 0) { L ">>> HIPOTESE B: IDs COMPLETAMENTE DIFERENTES" }
        else { L ">>> PARCIAL: $f/$t compartilhados" }
    }
}
# Gestao -> PDV
$tg = Q "Hiper" "SELECT TOP 30 CONVERT(VARCHAR(36),id_turno) AS id_turno FROM dbo.turno ORDER BY data_hora_inicio DESC"
if ($tg -isnot [string] -and $tg.Rows.Count -gt 0) {
    $ids2 = ($tg.Rows | % { "'$($_.id_turno)'" }) -join ","
    $match2 = Q "HiperPdv" "SELECT COUNT(*) AS encontrados FROM dbo.turno WHERE CONVERT(VARCHAR(36),id_turno) IN ($ids2)"
    if ($match2 -isnot [string] -and $match2.Rows.Count -gt 0) {
        $f2 = [int]$match2.Rows[0].encontrados; $t2 = $tg.Rows.Count
        L "Gestao->PDV: $f2 de $t2 turnos encontrados"
    }
}
# Totais
T (Q "HiperPdv" "SELECT 'HiperPdv' AS banco,COUNT(*) AS total,SUM(CASE WHEN fechado=1 THEN 1 ELSE 0 END) AS fechados,SUM(CASE WHEN fechado=0 THEN 1 ELSE 0 END) AS abertos,MIN(CONVERT(VARCHAR(19),data_hora_inicio,120)) AS primeiro,MAX(CONVERT(VARCHAR(19),data_hora_inicio,120)) AS ultimo FROM dbo.turno") "total turnos PDV"
T (Q "Hiper" "SELECT 'Gestao' AS banco,COUNT(*) AS total,SUM(CASE WHEN fechado=1 THEN 1 ELSE 0 END) AS fechados,SUM(CASE WHEN fechado=0 THEN 1 ELSE 0 END) AS abertos,MIN(CONVERT(VARCHAR(19),data_hora_inicio,120)) AS primeiro,MAX(CONVERT(VARCHAR(19),data_hora_inicio,120)) AS ultimo FROM dbo.turno") "total turnos Gestao"

# ═══════════════════════════════════════
H "8. VENDAS POR CANAL/ORIGEM"
# ═══════════════════════════════════════
# PDV
T (Q "HiperPdv" "SELECT COUNT(*) AS total_vendas,MIN(CONVERT(VARCHAR(19),data_hora_termino,120)) AS primeira,MAX(CONVERT(VARCHAR(19),data_hora_termino,120)) AS ultima FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL") "vendas PDV (HiperPdv)"

# Gestao: tentar com e sem origem
$hasOrigem = Q "Hiper" "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' AND COLUMN_NAME='origem'"
$origemExiste = $false
if ($hasOrigem -isnot [string] -and $hasOrigem.Rows.Count -gt 0 -and [int]$hasOrigem.Rows[0].n -gt 0) { $origemExiste = $true }

# Teste direto
if (-not $origemExiste) {
    L "INFORMATION_SCHEMA diz que 'origem' NAO existe. Tentando SELECT direto..."
    $testOrigem = Q "Hiper" "SELECT TOP 1 origem FROM dbo.operacao_pdv"
    if ($testOrigem -isnot [string]) {
        L "SELECT origem FUNCIONOU! Coluna existe mas INFORMATION_SCHEMA nao listou."
        $origemExiste = $true
    }
    else {
        L "SELECT origem FALHOU: $testOrigem"
        L ">>> CONFIRMADO: coluna 'origem' NAO EXISTE neste banco"
    }
}
else {
    L "INFORMATION_SCHEMA confirma: coluna 'origem' EXISTE"
}

if ($origemExiste) {
    T (Q "Hiper" "SELECT origem,CASE origem WHEN 0 THEN 'PDV/Caixa' WHEN 1 THEN 'Tipo1' WHEN 2 THEN 'Loja' ELSE 'outro_'+CAST(origem AS VARCHAR) END AS tipo,COUNT(*) AS total FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 GROUP BY origem ORDER BY origem") "vendas por ORIGEM (Gestao)"

    T (Q "Hiper" "SELECT origem,COUNT(*) AS total,MIN(CONVERT(VARCHAR(19),data_hora_termino,120)) AS primeira,MAX(CONVERT(VARCHAR(19),data_hora_termino,120)) AS ultima FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL GROUP BY origem ORDER BY origem") "datas por origem (Gestao)"
}
else {
    T (Q "Hiper" "SELECT COUNT(*) AS total_vendas,MIN(CONVERT(VARCHAR(19),data_hora_termino,120)) AS primeira,MAX(CONVERT(VARCHAR(19),data_hora_termino,120)) AS ultima FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL") "vendas totais (Gestao sem filtro origem)"
}

# ═══════════════════════════════════════
H "9. VENDAS LOJA - DETALHES"
# ═══════════════════════════════════════
if ($origemExiste) {
    T (Q "Hiper" "SELECT TOP 15 op.id_operacao,CONVERT(VARCHAR(36),op.id_turno) AS id_turno_loja,op.id_filial,op.id_usuario,CONVERT(VARCHAR(19),op.data_hora_inicio,120) AS inicio,CONVERT(VARCHAR(19),op.data_hora_termino,120) AS termino,op.origem,u.nome AS vendedor,u.login AS login_vend FROM dbo.operacao_pdv op LEFT JOIN dbo.usuario u ON u.id_usuario=op.id_usuario WHERE op.operacao=1 AND op.cancelado=0 AND op.origem=2 AND op.data_hora_termino IS NOT NULL ORDER BY op.data_hora_termino DESC") "ultimas 15 vendas LOJA (origem=2)"

    # Turnos dessas vendas existem?
    $vl = Q "Hiper" "SELECT DISTINCT TOP 15 CONVERT(VARCHAR(36),op.id_turno) AS id_turno FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.origem=2 AND op.data_hora_termino IS NOT NULL AND op.id_turno IS NOT NULL ORDER BY id_turno"
    if ($vl -isnot [string] -and $vl.Rows.Count -gt 0) {
        $idsLoja = ($vl.Rows | % { "'$($_.id_turno)'" }) -join ","
        $mg = Q "Hiper" "SELECT COUNT(*) AS n FROM dbo.turno WHERE CONVERT(VARCHAR(36),id_turno) IN ($idsLoja)"
        $mp = Q "HiperPdv" "SELECT COUNT(*) AS n FROM dbo.turno WHERE CONVERT(VARCHAR(36),id_turno) IN ($idsLoja)"
        $ng = if ($mg -isnot [string] -and $mg.Rows.Count -gt 0) { [int]$mg.Rows[0].n }else { 0 }
        $np = if ($mp -isnot [string] -and $mp.Rows.Count -gt 0) { [int]$mp.Rows[0].n }else { 0 }
        L "Turnos de vendas Loja encontrados no Gestao: $ng de $($vl.Rows.Count)"
        L "Turnos de vendas Loja encontrados no PDV:    $np de $($vl.Rows.Count)"
    }

    # Vendas Loja com turno NULL
    T (Q "Hiper" "SELECT COUNT(*) AS sem_turno FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND id_turno IS NULL") "vendas Loja com id_turno NULL"

    # Vendas Loja por filial
    T (Q "Hiper" "SELECT id_filial,COUNT(*) AS vendas FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 GROUP BY id_filial ORDER BY id_filial") "vendas Loja por filial"
}
else {
    L "Sem coluna 'origem' - pulando testes de vendas Loja"
    T (Q "Hiper" "SELECT TOP 15 op.id_operacao,CONVERT(VARCHAR(36),op.id_turno) AS id_turno,op.id_filial,op.id_usuario,CONVERT(VARCHAR(19),op.data_hora_termino,120) AS termino,u.nome AS vendedor FROM dbo.operacao_pdv op LEFT JOIN dbo.usuario u ON u.id_usuario=op.id_usuario WHERE op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL ORDER BY op.data_hora_termino DESC") "ultimas 15 vendas (Gestao, todas)"
}

# ═══════════════════════════════════════
H "10. OPERAÇÕES FECHAMENTO E FALTA (op=9, op=4)"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT operacao,CASE operacao WHEN 0 THEN 'Abertura' WHEN 1 THEN 'Venda' WHEN 3 THEN 'Sangria' WHEN 4 THEN 'FaltaCaixa' WHEN 8 THEN 'Raro' WHEN 9 THEN 'Fechamento' ELSE 'op_'+CAST(operacao AS VARCHAR) END AS tipo,COUNT(*) AS total FROM dbo.operacao_pdv WHERE cancelado=0 GROUP BY operacao ORDER BY operacao") "operacoes por tipo (HiperPdv)"

T (Q "Hiper" "SELECT operacao,CASE operacao WHEN 0 THEN 'Abertura' WHEN 1 THEN 'Venda' WHEN 3 THEN 'Sangria' WHEN 4 THEN 'FaltaCaixa' WHEN 8 THEN 'Raro' WHEN 9 THEN 'Fechamento' ELSE 'op_'+CAST(operacao AS VARCHAR) END AS tipo,COUNT(*) AS total FROM dbo.operacao_pdv WHERE cancelado=0 GROUP BY operacao ORDER BY operacao") "operacoes por tipo (Gestao)"

# Op=9 e op=4 no Gestao estao ligados a turnos?
T (Q "Hiper" "SELECT TOP 5 op.id_operacao,CONVERT(VARCHAR(36),op.id_turno) AS id_turno,op.operacao,CONVERT(VARCHAR(19),op.data_hora_termino,120) AS data,op.id_filial FROM dbo.operacao_pdv op WHERE op.operacao=9 AND op.cancelado=0 ORDER BY op.data_hora_termino DESC") "ultimos 5 fechamentos Gestao (op=9)"

# ═══════════════════════════════════════
H "11. COLISAO DE id_operacao"
# ═══════════════════════════════════════
if ($origemExiste) {
    $colQ = "SELECT TOP 10 p.id_operacao,CONVERT(VARCHAR(19),p.data_hora_termino,120) AS pdv_data,CONVERT(VARCHAR(19),g.data_hora_termino,120) AS gestao_data,g.origem AS gestao_origem,g.id_filial AS gestao_filial FROM [HiperPdv].dbo.operacao_pdv p JOIN [Hiper].dbo.operacao_pdv g ON g.id_operacao=p.id_operacao WHERE p.operacao=1 AND p.cancelado=0 AND g.operacao=1 AND g.cancelado=0 ORDER BY p.data_hora_termino DESC"
}
else {
    $colQ = "SELECT TOP 10 p.id_operacao,CONVERT(VARCHAR(19),p.data_hora_termino,120) AS pdv_data,CONVERT(VARCHAR(19),g.data_hora_termino,120) AS gestao_data,g.id_filial AS gestao_filial FROM [HiperPdv].dbo.operacao_pdv p JOIN [Hiper].dbo.operacao_pdv g ON g.id_operacao=p.id_operacao WHERE p.operacao=1 AND p.cancelado=0 AND g.operacao=1 AND g.cancelado=0 ORDER BY p.data_hora_termino DESC"
}
T (Q "HiperPdv" $colQ) "colisao id_operacao"
$colCount = Q "HiperPdv" "SELECT COUNT(*) AS total FROM [HiperPdv].dbo.operacao_pdv p JOIN [Hiper].dbo.operacao_pdv g ON g.id_operacao=p.id_operacao WHERE p.operacao=1 AND p.cancelado=0 AND g.operacao=1 AND g.cancelado=0"
if ($colCount -isnot [string] -and $colCount.Rows.Count -gt 0) { L "Total colisoes: $([int]$colCount.Rows[0].total)" }

# ═══════════════════════════════════════
H "12. MEIOS PAGAMENTO"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT id_finalizador,nome FROM dbo.finalizador_pdv ORDER BY id_finalizador") "finalizadores (HiperPdv)"
T (Q "Hiper" "SELECT DISTINCT id_finalizador,nome FROM dbo.finalizador_pdv ORDER BY id_finalizador") "finalizadores DISTINCT (Gestao)"
T (Q "Hiper" "SELECT id_finalizador,nome,COUNT(*) AS duplicatas FROM dbo.finalizador_pdv GROUP BY id_finalizador,nome HAVING COUNT(*)>1 ORDER BY id_finalizador") "finalizadores duplicados (Gestao)"

# ═══════════════════════════════════════
H "13. USUARIOS/VENDEDORES"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT COUNT(*) AS total,(SELECT COUNT(DISTINCT id_usuario) FROM dbo.usuario WHERE login IS NOT NULL AND login<>'') AS com_login FROM dbo.usuario") "usuarios (HiperPdv)"
T (Q "Hiper" "SELECT COUNT(*) AS total,(SELECT COUNT(DISTINCT id_usuario) FROM dbo.usuario WHERE login IS NOT NULL AND login<>'') AS com_login FROM dbo.usuario") "usuarios (Gestao)"

# IDs compartilhados?
$uPdv = Q "HiperPdv" "SELECT TOP 10 id_usuario,nome,login FROM dbo.usuario ORDER BY id_usuario"
$uGestao = Q "Hiper" "SELECT TOP 10 id_usuario,nome,login FROM dbo.usuario ORDER BY id_usuario"
T $uPdv "primeiros 10 usuarios (HiperPdv)"
T $uGestao "primeiros 10 usuarios (Gestao)"

# ═══════════════════════════════════════
H "14. ULTIMAS 5 VENDAS DETALHADAS (HiperPdv)"
# ═══════════════════════════════════════
T (Q "HiperPdv" "SELECT TOP 5 op.id_operacao,CONVERT(VARCHAR(8),op.id_turno) AS turno_8ch,CONVERT(VARCHAR(19),op.data_hora_termino,120) AS data,(SELECT COUNT(*) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS itens,(SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS total_itens,(SELECT COUNT(*) FROM dbo.finalizador_operacao_pdv f WHERE f.id_operacao=op.id_operacao) AS pgtos,(SELECT ISNULL(SUM(f.valor),0) FROM dbo.finalizador_operacao_pdv f WHERE f.id_operacao=op.id_operacao) AS total_pgto FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL ORDER BY op.data_hora_termino DESC") "vendas detalhe PDV"

# Detalhe de 1 venda (itens)
$lastSale = Q "HiperPdv" "SELECT TOP 1 id_operacao FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL ORDER BY data_hora_termino DESC"
if ($lastSale -isnot [string] -and $lastSale.Rows.Count -gt 0) {
    $opId = [int]$lastSale.Rows[0].id_operacao
    T (Q "HiperPdv" "SELECT it.id_item_operacao_pdv AS line_id,it.item AS line_no,it.id_produto,p.nome AS produto,it.codigo_barras,it.quantidade_primaria AS qtd,it.valor_unitario_liquido AS preco_unit,it.valor_total_liquido AS total,ISNULL(it.valor_desconto,0) AS desconto,it.id_usuario_vendedor,uv.nome AS vendedor,uv.login AS login_vend FROM dbo.item_operacao_pdv it JOIN dbo.produto p ON p.id_produto=it.id_produto LEFT JOIN dbo.usuario uv ON uv.id_usuario=it.id_usuario_vendedor WHERE it.id_operacao=$opId AND it.cancelado=0 ORDER BY it.item") "itens da venda #$opId"
    T (Q "HiperPdv" "SELECT fo.id_finalizador_operacao_pdv AS line_id,fo.id_finalizador,fpv.nome AS meio,fo.valor,ISNULL(fo.valor_troco,0) AS troco,fo.parcela FROM dbo.finalizador_operacao_pdv fo JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador=fo.id_finalizador WHERE fo.id_operacao=$opId ORDER BY fo.id_finalizador") "pagamentos da venda #$opId"
}

# ═══════════════════════════════════════
H "15. ULTIMAS 5 VENDAS DETALHADAS (Gestao)"
# ═══════════════════════════════════════
if ($origemExiste) { $wh = "AND op.origem=2" }else { $wh = "" }
T (Q "Hiper" "SELECT TOP 5 op.id_operacao,CONVERT(VARCHAR(8),op.id_turno) AS turno_8ch,op.id_filial,CONVERT(VARCHAR(19),op.data_hora_termino,120) AS data,(SELECT COUNT(*) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS itens,(SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS total_itens,(SELECT COUNT(*) FROM dbo.finalizador_operacao_pdv f WHERE f.id_operacao=op.id_operacao) AS pgtos,(SELECT ISNULL(SUM(f.valor),0) FROM dbo.finalizador_operacao_pdv f WHERE f.id_operacao=op.id_operacao) AS total_pgto FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL $wh ORDER BY op.data_hora_termino DESC") "vendas detalhe Gestao"

# Detalhe de 1 venda Loja
$lastLoja = Q "Hiper" "SELECT TOP 1 id_operacao FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL $wh ORDER BY data_hora_termino DESC"
if ($lastLoja -isnot [string] -and $lastLoja.Rows.Count -gt 0) {
    $opIdL = [int]$lastLoja.Rows[0].id_operacao
    T (Q "Hiper" "SELECT it.id_item_operacao_pdv AS line_id,it.item AS line_no,it.id_produto,p.nome AS produto,it.codigo_barras,it.quantidade_primaria AS qtd,it.valor_unitario_liquido AS preco_unit,it.valor_total_liquido AS total,ISNULL(it.valor_desconto,0) AS desconto,it.id_usuario_vendedor,uv.nome AS vendedor,uv.login AS login_vend FROM dbo.item_operacao_pdv it JOIN dbo.produto p ON p.id_produto=it.id_produto LEFT JOIN dbo.usuario uv ON uv.id_usuario=it.id_usuario_vendedor WHERE it.id_operacao=$opIdL AND it.cancelado=0 ORDER BY it.item") "itens da venda Gestao #$opIdL"
    # Pagamentos Gestao (sem valor_troco na tabela finalizador)
    T (Q "Hiper" "SELECT fo.id_finalizador_operacao_pdv AS line_id,fo.id_finalizador,fpv.nome AS meio,fo.valor,fo.parcela FROM dbo.finalizador_operacao_pdv fo JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador=fo.id_finalizador WHERE fo.id_operacao=$opIdL ORDER BY fo.id_finalizador") "pagamentos da venda Gestao #$opIdL"
    # ValorTroco da operacao
    T (Q "Hiper" "SELECT id_operacao,ISNULL(ValorTroco,0) AS ValorTroco FROM dbo.operacao_pdv WHERE id_operacao=$opIdL") "ValorTroco da operacao #$opIdL"
}

# ═══════════════════════════════════════
H "16. TURNOS COM DADOS DE FECHAMENTO (Gestao)"
# ═══════════════════════════════════════
T (Q "Hiper" "SELECT TOP 5 t.id_filial,CONVERT(VARCHAR(36),t.id_turno) AS id_turno,t.sequencial,CONVERT(VARCHAR(19),t.data_hora_inicio,120) AS inicio,CONVERT(VARCHAR(19),t.data_hora_termino,120) AS termino,(SELECT COUNT(*) FROM dbo.operacao_pdv op WHERE op.id_turno=t.id_turno AND op.operacao=9 AND op.cancelado=0) AS qtd_fechamentos,(SELECT COUNT(*) FROM dbo.operacao_pdv op WHERE op.id_turno=t.id_turno AND op.operacao=4 AND op.cancelado=0) AS qtd_faltas,(SELECT COUNT(*) FROM dbo.operacao_pdv op WHERE op.id_turno=t.id_turno AND op.operacao=1 AND op.cancelado=0) AS qtd_vendas FROM dbo.turno t WHERE t.fechado=1 ORDER BY t.data_hora_inicio DESC") "turnos Gestao com fechamento/falta/vendas"

# ═══════════════════════════════════════
H "17. FILIAIS NO GESTAO"
# ═══════════════════════════════════════
T (Q "Hiper" "SELECT DISTINCT id_filial FROM dbo.turno ORDER BY id_filial") "filiais distintas em turno (Gestao)"
if ($origemExiste) {
    T (Q "Hiper" "SELECT DISTINCT id_filial FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 ORDER BY id_filial") "filiais com vendas Loja (origem=2)"
}
T (Q "Hiper" "SELECT id_filial,COUNT(*) AS total_turnos,SUM(CASE WHEN fechado=1 THEN 1 ELSE 0 END) AS fechados FROM dbo.turno GROUP BY id_filial ORDER BY id_filial") "turnos por filial (Gestao)"

# ═══════════════════════════════════════
H "18. ANOMALIAS E EDGE CASES"
# ═══════════════════════════════════════
# Vendas PDV sem itens
$semItens = Q "HiperPdv" "SELECT COUNT(*) AS qtd FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dbo.item_operacao_pdv it WHERE it.id_operacao=op.id_operacao AND it.cancelado=0)"
T $semItens "vendas PDV sem itens ativos"

# Itens sem vendedor
$semVend = Q "HiperPdv" "SELECT COUNT(*) AS qtd FROM dbo.item_operacao_pdv it JOIN dbo.operacao_pdv op ON op.id_operacao=it.id_operacao WHERE op.operacao=1 AND op.cancelado=0 AND it.cancelado=0 AND it.id_usuario_vendedor IS NULL"
T $semVend "itens PDV sem vendedor"

# Datas no futuro
T (Q "HiperPdv" "SELECT COUNT(*) AS qtd FROM dbo.operacao_pdv WHERE data_hora_termino>GETDATE() AND operacao=1 AND cancelado=0") "vendas PDV com data futura"

# Turnos muito curtos (<5min)
T (Q "HiperPdv" "SELECT COUNT(*) AS qtd FROM dbo.turno WHERE fechado=1 AND DATEDIFF(MINUTE,data_hora_inicio,data_hora_termino)<5") "turnos PDV <5 minutos"

# Volume ultimos 7 dias
$dt7 = Get-Date (Get-Date).AddDays(-7) -Format "yyyy-MM-dd HH:mm:ss"
T (Q "HiperPdv" "SELECT COUNT(*) AS vendas_7d FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino>='$dt7'") "vendas PDV ultimos 7 dias"
if ($origemExiste) {
    T (Q "Hiper" "SELECT origem,COUNT(*) AS vendas_7d FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino>='$dt7' GROUP BY origem ORDER BY origem") "vendas Gestao ultimos 7 dias por origem"
}
else {
    T (Q "Hiper" "SELECT COUNT(*) AS vendas_7d FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino>='$dt7'") "vendas Gestao ultimos 7 dias"
}

# ═══════════════════════════════════════
H "FIM DO DIAGNOSTICO"
# ═══════════════════════════════════════
L "Gerado em: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
L "Machine: $env:COMPUTERNAME"

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  PRONTO! Resultado em: $Out" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Start-Process notepad.exe $Out
