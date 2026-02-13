<#
  Validação COMPLETA pré-instalação — PDV Sync Agent v3.0
  Pode ser colado direto no console PowerShell!
  Resultado salvo em C:\validacao_loja.txt e aberto automaticamente.
#>

$ErrorActionPreference = "Continue"
$LOG = "C:\validacao_loja.txt"
Start-Transcript -Path $LOG -Force | Out-Null

$SERVER = "localhost\HIPER"
$DB_PDV = "HiperPdv"
$DB_GESTAO = "Hiper"
$ID_PDV = 10
$ID_FILIAL = 10
$dt_to = Get-Date
$dt_from = $dt_to.AddDays(-7)
$FROM_STR = $dt_from.ToString("yyyy-MM-dd HH:mm:ss")
$TO_STR = $dt_to.ToString("yyyy-MM-dd HH:mm:ss")
$PASS = 0; $FAIL = 0; $WARN = 0

function Sql { param([string]$Db, [string]$Q, [string]$Label = ""); try { $c = New-Object System.Data.SqlClient.SqlConnection; $c.ConnectionString = "Server=$SERVER;Database=$Db;Integrated Security=True;TrustServerCertificate=True"; $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $Q; $cmd.CommandTimeout = 30; $a = New-Object System.Data.SqlClient.SqlDataAdapter($cmd); $t = New-Object System.Data.DataTable; [void]$a.Fill($t); $c.Close(); $rows = @(); foreach ($r in $t.Rows) { $o = [ordered]@{}; foreach ($col in $t.Columns) { $v = $r[$col.ColumnName]; if ($v -is [System.DBNull]) { $v = $null }; $o[$col.ColumnName] = $v }; $rows += $o }; return $rows } catch { if ($Label) { Write-Host "  !! ERRO [$Label]: $($_.Exception.Message)" -Fore Red }; return $null } }

function Ok { param([string]$M, [string]$D = ""); $script:PASS++; Write-Host "  [OK] $M" -Fore Green; if ($D) { Write-Host "     -> $D" -Fore DarkGray } }
function Nok { param([string]$M, [string]$D = ""); $script:FAIL++; Write-Host "  [FAIL] $M $D" -Fore Red }
function Wrn { param([string]$M); $script:WARN++; Write-Host "  [WARN] $M" -Fore Yellow }
function Hdr { param([string]$M); Write-Host "`n$M" -Fore Cyan }
function Sub { param([string]$M); Write-Host "  $M" -Fore DarkGray }

Write-Host ""
Write-Host "================================================================" -Fore Cyan
Write-Host "  VALIDACAO COMPLETA PRE-INSTALACAO -- PDV Sync Agent v3.0" -Fore Cyan
Write-Host "  Maquina: $($env:COMPUTERNAME)" -Fore Cyan
Write-Host "  Data:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Fore Cyan
Write-Host "  Janela:  $FROM_STR -> $TO_STR" -Fore Cyan
Write-Host "================================================================" -Fore Cyan

# ═══ A) CONEXAO SQL ═══
Hdr "[A] CONEXAO E INSTANCIA SQL SERVER"

$sqlInfo = Sql $DB_PDV "SELECT @@VERSION AS ver, @@SERVERNAME AS srv, DB_NAME() AS db" "SQL Info"
if ($sqlInfo) { Ok "Conexao HiperPdv"; Sub "Server: $($sqlInfo[0].srv)"; Sub "Database: $($sqlInfo[0].db)" } else { Nok "Conexao HiperPdv" "Verifique o servidor $SERVER" }

$sqlG = Sql $DB_GESTAO "SELECT DB_NAME() AS db" "Gestao"
if ($sqlG) { Ok "Conexao Hiper (Gestao)" } else { Nok "Conexao Hiper (Gestao)" }

# ═══ B) SCHEMAS ═══
Hdr "[B] DESCOBERTA DE SCHEMAS -- TABELAS E COLUNAS"

$tabelasAgent = @("turno", "operacao_pdv", "item_operacao_pdv", "finalizador_operacao_pdv", "finalizador_pdv", "ponto_venda", "produto", "usuario")

foreach ($db in @($DB_PDV, $DB_GESTAO)) { Write-Host "`n  -- Banco: $db --" -Fore Yellow; foreach ($tbl in $tabelasAgent) { $cols = Sql $db "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH AS max_len, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$tbl' AND TABLE_SCHEMA = 'dbo' ORDER BY ORDINAL_POSITION" "$db.$tbl"; if ($cols -and $cols.Count -gt 0) { $colNames = ($cols | ForEach-Object { $_.COLUMN_NAME }) -join ", "; Ok "[$db].$tbl ($($cols.Count) colunas)"; Sub $colNames } else { Wrn "[$db].$tbl -- tabela NAO encontrada" } } }

# B.2: Colunas criticas
Hdr "[B.2] COLUNAS CRITICAS USADAS PELO AGENT"

$critical = @(@{Db = $DB_PDV; T = "operacao_pdv"; C = "id_turno" }, @{Db = $DB_PDV; T = "operacao_pdv"; C = "data_hora_termino" }, @{Db = $DB_PDV; T = "operacao_pdv"; C = "data_hora_inicio" }, @{Db = $DB_PDV; T = "operacao_pdv"; C = "operacao" }, @{Db = $DB_PDV; T = "operacao_pdv"; C = "cancelado" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "id_usuario_vendedor" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "valor_total_liquido" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "valor_unitario_liquido" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "valor_desconto" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "codigo_barras" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "quantidade_primaria" }, @{Db = $DB_PDV; T = "item_operacao_pdv"; C = "cancelado" }, @{Db = $DB_PDV; T = "finalizador_operacao_pdv"; C = "valor_troco" }, @{Db = $DB_PDV; T = "finalizador_operacao_pdv"; C = "parcela" }, @{Db = $DB_PDV; T = "finalizador_pdv"; C = "nome" }, @{Db = $DB_PDV; T = "ponto_venda"; C = "apelido" }, @{Db = $DB_PDV; T = "ponto_venda"; C = "nome" }, @{Db = $DB_PDV; T = "turno"; C = "sequencial" }, @{Db = $DB_PDV; T = "turno"; C = "fechado" }, @{Db = $DB_PDV; T = "turno"; C = "id_ponto_venda" }, @{Db = $DB_GESTAO; T = "operacao_pdv"; C = "origem" }, @{Db = $DB_GESTAO; T = "operacao_pdv"; C = "id_filial" }, @{Db = $DB_GESTAO; T = "operacao_pdv"; C = "ValorTroco" }, @{Db = $DB_GESTAO; T = "finalizador_pdv"; C = "nome" })

foreach ($c in $critical) { $r = Sql $c.Db "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='$($c.T)' AND COLUMN_NAME='$($c.C)'" "col"; if ($r -and $r[0].n -gt 0) { Ok "[$($c.Db)].$($c.T).$($c.C)" } else { Nok "[$($c.Db)].$($c.T).$($c.C)" "COLUNA NAO EXISTE" } }

# B.3: Diferencas
Hdr "[B.3] DIFERENCAS SCHEMA PDV vs GESTAO"

$pdvFinTroco = Sql $DB_PDV "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='finalizador_operacao_pdv' AND COLUMN_NAME='valor_troco'" "col"
$gestFinTroco = Sql $DB_GESTAO "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='finalizador_operacao_pdv' AND COLUMN_NAME='valor_troco'" "col"
Sub "PDV finalizador_operacao_pdv.valor_troco: $(if($pdvFinTroco -and $pdvFinTroco[0].n -gt 0){'EXISTE'}else{'NAO EXISTE'})"
Sub "Gestao finalizador_operacao_pdv.valor_troco: $(if($gestFinTroco -and $gestFinTroco[0].n -gt 0){'EXISTE'}else{'NAO EXISTE (esperado)'})"

$gestOrigem = Sql $DB_GESTAO "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' AND COLUMN_NAME='origem'" "col"
$pdvOrigem = Sql $DB_PDV "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME='operacao_pdv' AND COLUMN_NAME='origem'" "col"
Sub "Gestao operacao_pdv.origem: $(if($gestOrigem -and $gestOrigem[0].n -gt 0){'EXISTE'}else{'NAO EXISTE'})"
Sub "PDV operacao_pdv.origem: $(if($pdvOrigem -and $pdvOrigem[0].n -gt 0){'EXISTE'}else{'NAO EXISTE (esperado)'})"

# ═══ C) FKs ═══
Hdr "[C] FOREIGN KEYS E RELACIONAMENTOS"

foreach ($db in @($DB_PDV, $DB_GESTAO)) { Write-Host "`n  -- $db --" -Fore Yellow; $fks = Sql $db "SELECT fk.name AS fk_name, tp.name AS parent_table, cp.name AS parent_column, tr.name AS ref_table, cr.name AS ref_column FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id JOIN sys.tables tp ON tp.object_id = fk.parent_object_id JOIN sys.columns cp ON cp.object_id = fk.parent_object_id AND cp.column_id = fkc.parent_column_id JOIN sys.tables tr ON tr.object_id = fk.referenced_object_id JOIN sys.columns cr ON cr.object_id = fk.referenced_object_id AND cr.column_id = fkc.referenced_column_id WHERE tp.name IN ('operacao_pdv','item_operacao_pdv','finalizador_operacao_pdv','turno') ORDER BY tp.name, fk.name" "FKs $db"; if ($fks -and $fks.Count -gt 0) { foreach ($fk in $fks) { Sub "$($fk.parent_table).$($fk.parent_column) -> $($fk.ref_table).$($fk.ref_column) [$($fk.fk_name)]" }; Ok "$db : $($fks.Count) FKs encontradas" } else { Wrn "$db : Nenhuma FK nas tabelas do agent" } }

# ═══ D) DADOS DA LOJA ═══
Hdr "[D] DADOS DA LOJA"

$store = Sql $DB_PDV "SELECT * FROM dbo.ponto_venda WHERE id_ponto_venda = $ID_PDV" "store"
if ($store -and $store.Count -gt 0) { Ok "ponto_venda id=$ID_PDV encontrado"; foreach ($k in $store[0].Keys) { Sub "$k = $($store[0][$k])" } } else { Nok "ponto_venda id=$ID_PDV NAO ENCONTRADO" }

$allPdvs = Sql $DB_PDV "SELECT id_ponto_venda, nome FROM dbo.ponto_venda ORDER BY id_ponto_venda" "allPdv"
if ($allPdvs) { Sub "Todos os pontos de venda:"; foreach ($p in $allPdvs) { Sub "  id=$($p.id_ponto_venda) | nome=$($p.nome)" } }

$fins = Sql $DB_PDV "SELECT id_finalizador, nome FROM dbo.finalizador_pdv ORDER BY id_finalizador" "fins"
if ($fins) { Ok "Finalizadores PDV: $($fins.Count)"; foreach ($f in $fins) { Sub "id=$($f.id_finalizador) | $($f.nome)" } }

$opTypes = Sql $DB_PDV "SELECT operacao, COUNT(*) AS qtd, CASE operacao WHEN 0 THEN 'Abertura' WHEN 1 THEN 'Venda' WHEN 3 THEN 'Sangria' WHEN 4 THEN 'Falta Caixa' WHEN 8 THEN 'Raro' WHEN 9 THEN 'Fechamento' ELSE 'Desconhecido' END AS descr FROM dbo.operacao_pdv GROUP BY operacao ORDER BY operacao" "opTypes"
if ($opTypes) { Sub "Tipos de operacao no PDV:"; foreach ($o in $opTypes) { Sub "  op=$($o.operacao) ($($o.descr)): $($o.qtd) registros" } }

# ═══ E) VOLUME ═══
Hdr "[E] VOLUME DE DADOS (ultimos 7 dias)"

$turnos = Sql $DB_PDV "SELECT COUNT(*) AS total, SUM(CASE WHEN fechado=1 THEN 1 ELSE 0 END) AS fechados, SUM(CASE WHEN fechado=0 THEN 1 ELSE 0 END) AS abertos FROM dbo.turno WHERE id_ponto_venda = $ID_PDV AND data_hora_inicio >= '$FROM_STR'" "turnos"
if ($turnos) { Sub "Turnos: total=$($turnos[0].total) | fechados=$($turnos[0].fechados) | abertos=$($turnos[0].abertos)" }

$opsPdv = Sql $DB_PDV "SELECT COUNT(*) AS vendas FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR'" "pdvOps"
if ($opsPdv) { Sub "Vendas PDV (op=1, cancelado=0): $($opsPdv[0].vendas)" }

$opsLoja = Sql $DB_GESTAO "SELECT COUNT(*) AS vendas FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR' AND id_filial = $ID_FILIAL" "lojaOps"
if ($opsLoja) { Sub "Vendas Loja (origem=2): $($opsLoja[0].vendas)" }

# ═══ F) QUERIES PDV ═══
Hdr "[F] QUERIES PDV -- REPLICA EXATA DO PYTHON"

Write-Host "`n  [F.1] get_store_info" -Fore Yellow
$storeInfo = Sql $DB_PDV "SELECT id_ponto_venda, ISNULL(apelido, nome) AS nome FROM dbo.ponto_venda WHERE id_ponto_venda = $ID_PDV" "get_store_info"
if ($storeInfo) { Ok "get_store_info: id=$($storeInfo[0].id_ponto_venda) nome=$($storeInfo[0].nome)" } else { Nok "get_store_info" }

Write-Host "`n  [F.2] get_current_turno" -Fore Yellow
$curTurno = Sql $DB_PDV "SELECT TOP 1 id_turno, id_ponto_venda, id_usuario, data_hora_inicio, data_hora_termino, fechado, sequencial FROM dbo.turno WHERE id_ponto_venda = $ID_PDV ORDER BY data_hora_inicio DESC" "get_current_turno"
if ($curTurno) { Ok "get_current_turno: seq=$($curTurno[0].sequencial) fechado=$($curTurno[0].fechado)"; Sub "id_turno=$($curTurno[0].id_turno)"; Sub "inicio=$($curTurno[0].data_hora_inicio) | termino=$($curTurno[0].data_hora_termino)" } else { Wrn "Nenhum turno encontrado para PDV $ID_PDV" }

Write-Host "`n  [F.3] get_turnos_with_activity" -Fore Yellow
$turnosAct = Sql $DB_PDV "SELECT DISTINCT t.id_turno, t.sequencial, t.fechado, t.data_hora_inicio, t.data_hora_termino, t.id_usuario AS id_operador, u.nome AS nome_operador FROM dbo.turno t LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario WHERE t.id_ponto_venda = $ID_PDV AND (t.id_turno IN (SELECT DISTINCT op.id_turno FROM dbo.operacao_pdv op WHERE op.operacao IN (1, 4, 9) AND op.cancelado = 0 AND op.data_hora_termino IS NOT NULL AND op.data_hora_termino >= '$FROM_STR' AND op.data_hora_termino < '$TO_STR') OR (t.fechado = 1 AND t.data_hora_termino IS NOT NULL AND t.data_hora_termino >= '$FROM_STR' AND t.data_hora_termino < '$TO_STR') OR (t.fechado = 0 AND t.data_hora_termino IS NULL)) ORDER BY t.data_hora_inicio" "get_turnos_with_activity"
if ($turnosAct) { Ok "get_turnos_with_activity: $($turnosAct.Count) turno(s)"; foreach ($t in $turnosAct) { Sub "seq=$($t.sequencial) | fechado=$($t.fechado) | op=$($t.nome_operador) | inicio=$($t.data_hora_inicio)" } } else { Wrn "Nenhum turno com atividade na janela" }

Write-Host "`n  [F.4] get_operation_ids" -Fore Yellow
$opIds = Sql $DB_PDV "SELECT id_operacao FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR' ORDER BY id_operacao" "get_operation_ids"
if ($opIds) { Ok "get_operation_ids: $($opIds.Count) IDs" } else { Wrn "Nenhuma operacao na janela" }

Write-Host "`n  [F.5] get_sale_items" -Fore Yellow
$saleItems = Sql $DB_PDV "WITH ops AS (SELECT id_operacao, id_turno, id_ponto_venda, data_hora_termino FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR') SELECT TOP 10 ops.id_operacao, ops.id_turno, ops.data_hora_termino, it.id_item_operacao_pdv AS line_id, it.item AS line_no, it.id_produto, it.codigo_barras, p.nome AS nome_produto, it.quantidade_primaria AS qtd, it.valor_unitario_liquido AS preco_unit, it.valor_total_liquido AS total_item, ISNULL(it.valor_desconto,0) AS desconto_item, it.id_usuario_vendedor, uv.nome AS nome_vendedor FROM ops JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao JOIN dbo.produto p ON p.id_produto = it.id_produto LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor WHERE it.cancelado = 0 ORDER BY ops.data_hora_termino DESC, ops.id_operacao, it.item" "get_sale_items"
if ($saleItems) { Ok "get_sale_items: $($saleItems.Count) itens (sample)"; foreach ($i in $saleItems | Select-Object -First 3) { Sub "op=$($i.id_operacao) | $($i.nome_produto) | qtd=$($i.qtd) | R`$ $($i.total_item) | vend=$($i.nome_vendedor)" } } else { Wrn "Nenhum item de venda na janela" }

Write-Host "`n  [F.6] get_sale_payments" -Fore Yellow
$salePay = Sql $DB_PDV "WITH ops AS (SELECT id_operacao FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR') SELECT TOP 10 fo.id_finalizador_operacao_pdv AS line_id, fo.id_operacao, fo.id_finalizador, fpv.nome AS meio_pagamento, fo.valor, ISNULL(fo.valor_troco,0) AS valor_troco, fo.parcela FROM ops JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador ORDER BY fo.id_operacao, fo.id_finalizador" "get_sale_payments"
if ($salePay) { Ok "get_sale_payments: $($salePay.Count) pgtos (sample)"; foreach ($p in $salePay | Select-Object -First 3) { Sub "op=$($p.id_operacao) | $($p.meio_pagamento) | R`$ $($p.valor) | troco=R`$ $($p.valor_troco)" } } else { Wrn "Nenhum pagamento na janela" }

Write-Host "`n  [F.7] get_sales_by_vendor" -Fore Yellow
$byVendor = Sql $DB_PDV "WITH ops AS (SELECT id_operacao, id_ponto_venda, id_turno FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR') SELECT it.id_usuario_vendedor, u.nome AS vendedor_nome, COUNT(DISTINCT ops.id_operacao) AS qtd_cupons, SUM(ISNULL(it.valor_total_liquido,0)) AS total_vendido FROM ops JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao LEFT JOIN dbo.usuario u ON u.id_usuario = it.id_usuario_vendedor WHERE it.cancelado = 0 GROUP BY it.id_usuario_vendedor, u.nome ORDER BY total_vendido DESC" "get_sales_by_vendor"
if ($byVendor) { Ok "get_sales_by_vendor: $($byVendor.Count) vendedores"; foreach ($v in $byVendor) { $vname = if ($v.vendedor_nome) { $v.vendedor_nome } else { "NULL !!!" }; Sub "id=$($v.id_usuario_vendedor) | $vname | cupons=$($v.qtd_cupons) | R`$ $($v.total_vendido)" }; $nullV = @($byVendor | Where-Object { $null -eq $_.id_usuario_vendedor }); if ($nullV.Count -gt 0) { Wrn "Vendedor NULL em $($nullV[0].qtd_cupons) cupom(s) -- gerara warning" } }

Write-Host "`n  [F.8] get_payments_by_method" -Fore Yellow
$byMethod = Sql $DB_PDV "WITH ops AS (SELECT id_operacao, id_ponto_venda, id_turno FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR') SELECT fo.id_finalizador, fpv.nome AS meio_pagamento, COUNT(DISTINCT ops.id_operacao) AS qtd_vendas, SUM(ISNULL(fo.valor,0)) AS total_pago FROM ops JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador GROUP BY fo.id_finalizador, fpv.nome ORDER BY total_pago DESC" "get_payments_by_method"
if ($byMethod) { Ok "get_payments_by_method: $($byMethod.Count) metodos"; foreach ($m in $byMethod) { Sub "id=$($m.id_finalizador) | $($m.meio_pagamento) | vendas=$($m.qtd_vendas) | R`$ $($m.total_pago)" } }

Write-Host "`n  [F.9] get_turno_responsavel (TIEBREAKER)" -Fore Yellow
if ($curTurno) { $idT = $curTurno[0].id_turno; $resp = Sql $DB_PDV "SELECT TOP 1 uv.id_usuario, uv.nome FROM dbo.operacao_pdv ov JOIN dbo.item_operacao_pdv iv ON iv.id_operacao = ov.id_operacao JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor WHERE ov.id_turno = '$idT' AND ov.operacao=1 AND ov.cancelado=0 AND iv.cancelado=0 GROUP BY uv.id_usuario, uv.nome ORDER BY COUNT(*) DESC, SUM(iv.valor_total_liquido) DESC, uv.id_usuario ASC" "tiebreaker"; if ($resp) { Ok "Responsavel: $($resp[0].nome) (id=$($resp[0].id_usuario))" } else { Wrn "Sem vendas no turno atual -- responsavel NULL" } } else { Wrn "Sem turno para testar tiebreaker" }

Write-Host "`n  [F.10] get_turno_closure + shortage (op=9, op=4)" -Fore Yellow
$closedT = Sql $DB_PDV "SELECT TOP 1 id_turno, sequencial FROM dbo.turno WHERE id_ponto_venda=$ID_PDV AND fechado=1 ORDER BY data_hora_inicio DESC" "closedTurno"
if ($closedT) { $idClosed = $closedT[0].id_turno; Sub "Testando com turno fechado seq=$($closedT[0].sequencial)"; $closure = Sql $DB_PDV "SELECT fo.id_finalizador, fpv.nome AS meio_pagamento, SUM(ISNULL(fo.valor,0)) AS total_declarado FROM dbo.operacao_pdv op JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador WHERE op.id_turno = '$idClosed' AND op.operacao=9 AND op.cancelado=0 GROUP BY fo.id_finalizador, fpv.nome ORDER BY total_declarado DESC" "closure"; if ($closure) { Ok "Closure (op=9): $($closure.Count) entradas"; foreach ($c in $closure) { Sub "$($c.meio_pagamento): R`$ $($c.total_declarado)" } } else { Wrn "Sem op=9 para turno $($closedT[0].sequencial)" }; $shortage = Sql $DB_PDV "SELECT fo.id_finalizador, fpv.nome AS meio_pagamento, SUM(ISNULL(fo.valor,0)) AS total_falta FROM dbo.operacao_pdv op JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador WHERE op.id_turno = '$idClosed' AND op.operacao=4 AND op.cancelado=0 GROUP BY fo.id_finalizador, fpv.nome ORDER BY total_falta DESC" "shortage"; if ($shortage) { Ok "Shortage (op=4): $($shortage.Count) entradas"; foreach ($s in $shortage) { Sub "$($s.meio_pagamento): R`$ $($s.total_falta)" } } else { Sub "Sem op=4 para turno (normal se nao houve falta)" } }

Write-Host "`n  [F.11] get_turno_snapshot" -Fore Yellow
$tSnap = Sql $DB_PDV "SELECT TOP 5 t.id_turno, t.sequencial, t.fechado, t.data_hora_inicio, t.data_hora_termino, DATEDIFF(MINUTE, t.data_hora_inicio, t.data_hora_termino) AS duracao_minutos, u.nome AS nome_operador, (SELECT COUNT(*) FROM dbo.operacao_pdv op WHERE op.id_turno=t.id_turno AND op.operacao=1 AND op.cancelado=0) AS qtd_vendas, (SELECT ISNULL(SUM(it.valor_total_liquido),0) FROM dbo.operacao_pdv op2 JOIN dbo.item_operacao_pdv it ON it.id_operacao=op2.id_operacao WHERE op2.id_turno=t.id_turno AND op2.operacao=1 AND op2.cancelado=0 AND it.cancelado=0) AS total_vendas, (SELECT COUNT(DISTINCT iv2.id_usuario_vendedor) FROM dbo.operacao_pdv ov2 JOIN dbo.item_operacao_pdv iv2 ON iv2.id_operacao=ov2.id_operacao WHERE ov2.id_turno=t.id_turno AND ov2.operacao=1 AND ov2.cancelado=0 AND iv2.cancelado=0) AS qtd_vendedores FROM dbo.turno t LEFT JOIN dbo.usuario u ON u.id_usuario=t.id_usuario WHERE t.id_ponto_venda=$ID_PDV AND t.fechado=1 ORDER BY t.data_hora_inicio DESC" "turno_snapshot"
if ($tSnap) { Ok "turno_snapshot: $($tSnap.Count) turnos fechados"; foreach ($s in $tSnap) { Sub "seq=$($s.sequencial) | $($s.duracao_minutos)min | vendas=$($s.qtd_vendas) | R`$ $($s.total_vendas) | vendedores=$($s.qtd_vendedores)" } }

Write-Host "`n  [F.12] get_vendas_snapshot" -Fore Yellow
$vSnap = Sql $DB_PDV "SELECT TOP 5 op.id_operacao, op.data_hora_inicio, op.data_hora_termino, DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_segundos, t.id_turno, t.sequencial AS turno_seq, (SELECT COUNT(*) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS qtd_itens, (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS total_itens FROM dbo.operacao_pdv op JOIN dbo.turno t ON t.id_turno=op.id_turno WHERE t.id_ponto_venda=$ID_PDV AND op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL ORDER BY op.data_hora_termino DESC" "vendas_snapshot"
if ($vSnap) { Ok "vendas_snapshot: $($vSnap.Count) vendas recentes"; foreach ($v in $vSnap) { Sub "op=$($v.id_operacao) | turno=$($v.turno_seq) | $($v.duracao_segundos)s | itens=$($v.qtd_itens) | R`$ $($v.total_itens)" } }

# ═══ G) QUERIES GESTAO ═══
Hdr "[G] QUERIES GESTAO/LOJA -- REPLICA EXATA DO PYTHON"

Write-Host "`n  [G.1] get_loja_operation_ids" -Fore Yellow
$lojaIds = Sql $DB_GESTAO "SELECT id_operacao FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR' AND id_filial = $ID_FILIAL ORDER BY id_operacao" "loja_op_ids"
if ($lojaIds) { Ok "loja_operation_ids: $($lojaIds.Count) IDs" } else { Wrn "Nenhuma venda Loja na janela" }

Write-Host "`n  [G.2] get_loja_sale_items" -Fore Yellow
$lojaItems = Sql $DB_GESTAO "WITH ops AS (SELECT id_operacao, id_turno, id_filial, data_hora_termino FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR' AND id_filial = $ID_FILIAL) SELECT TOP 10 ops.id_operacao, CONVERT(VARCHAR(36), ops.id_turno) AS id_turno, ops.data_hora_termino, it.id_item_operacao_pdv AS line_id, it.item AS line_no, it.id_produto, p.nome AS nome_produto, it.quantidade_primaria AS qtd, it.valor_total_liquido AS total_item, it.id_usuario_vendedor, uv.nome AS nome_vendedor FROM ops JOIN dbo.item_operacao_pdv it ON it.id_operacao = ops.id_operacao JOIN dbo.produto p ON p.id_produto = it.id_produto LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor WHERE it.cancelado = 0 ORDER BY ops.data_hora_termino DESC" "loja_items"
if ($lojaItems) { Ok "loja_sale_items: $($lojaItems.Count) itens (sample)"; foreach ($i in $lojaItems | Select-Object -First 3) { Sub "op=$($i.id_operacao) | $($i.nome_produto) | R`$ $($i.total_item) | turno=$($i.id_turno)" } } else { Wrn "Sem itens Loja" }

Write-Host "`n  [G.3] get_loja_sale_payments (TROCO ROW_NUMBER FIX)" -Fore Yellow
$lojaPay = Sql $DB_GESTAO "WITH ops AS (SELECT id_operacao, ISNULL(ValorTroco, 0) AS valor_troco_op FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND data_hora_termino IS NOT NULL AND data_hora_termino >= '$FROM_STR' AND data_hora_termino < '$TO_STR' AND id_filial = $ID_FILIAL), pagamentos AS (SELECT fo.id_finalizador_operacao_pdv AS line_id, fo.id_operacao, fo.id_finalizador, fpv.nome AS meio_pagamento, fo.valor, ops.valor_troco_op, fo.parcela, ROW_NUMBER() OVER (PARTITION BY fo.id_operacao ORDER BY fo.id_finalizador ASC) AS rn FROM ops JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = ops.id_operacao LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador) SELECT line_id, id_operacao, id_finalizador, meio_pagamento, valor, CASE WHEN rn = 1 THEN valor_troco_op ELSE 0 END AS valor_troco, parcela, rn FROM pagamentos ORDER BY id_operacao, id_finalizador" "loja_payments"
if ($lojaPay) { Ok "loja_sale_payments: $($lojaPay.Count) pgtos"; $trocoErr = @($lojaPay | Where-Object { $_.rn -gt 1 -and $_.valor_troco -gt 0 }); if ($trocoErr.Count -eq 0) { Ok "Troco ROW_NUMBER: NENHUM duplicado (rn>1 com troco=0)" } else { Nok "Troco duplicado! $($trocoErr.Count) linhas com rn>1 e troco>0" }; $multi = $lojaPay | Group-Object id_operacao | Where-Object { $_.Count -gt 1 }; Sub "Vendas multi-pagamento: $($multi.Count)"; foreach ($g in $multi | Select-Object -First 2) { Sub "  Venda #$($g.Name):"; foreach ($r in $g.Group) { Sub "    rn=$($r.rn) | $($r.meio_pagamento) | R`$ $($r.valor) | troco=R`$ $($r.valor_troco)" } } } else { Wrn "Sem pagamentos Loja" }

Write-Host "`n  [G.4] get_loja_vendas_snapshot" -Fore Yellow
$lojaSnap = Sql $DB_GESTAO "SELECT TOP 5 op.id_operacao, op.data_hora_inicio, op.data_hora_termino, DATEDIFF(SECOND, op.data_hora_inicio, op.data_hora_termino) AS duracao_segundos, CONVERT(VARCHAR(36), op.id_turno) AS id_turno, (SELECT COUNT(*) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS qtd_itens, (SELECT ISNULL(SUM(i.valor_total_liquido),0) FROM dbo.item_operacao_pdv i WHERE i.id_operacao=op.id_operacao AND i.cancelado=0) AS total_itens FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.origem=2 AND op.data_hora_termino IS NOT NULL AND op.id_filial=$ID_FILIAL ORDER BY op.data_hora_termino DESC" "loja_snap"
if ($lojaSnap) { Ok "loja_vendas_snapshot: $($lojaSnap.Count) vendas"; foreach ($v in $lojaSnap) { $turnoStr = if ($v.id_turno) { $v.id_turno.Substring(0, [Math]::Min(8, $v.id_turno.Length)) } else { "NULL" }; Sub "op=$($v.id_operacao) | turno=$turnoStr | itens=$($v.qtd_itens) | R`$ $($v.total_itens)" } }

# ═══ H) VALIDACOES CRUZADAS ═══
Hdr "[H] VALIDACOES CRUZADAS"

Write-Host "`n  [H.1] Vendas sem itens (op cancelado=0 mas sem itens ativos)" -Fore Yellow
$semItens = Sql $DB_PDV "SELECT op.id_operacao, op.data_hora_termino FROM dbo.operacao_pdv op WHERE op.operacao=1 AND op.cancelado=0 AND op.data_hora_termino IS NOT NULL AND op.data_hora_termino >= '$FROM_STR' AND op.data_hora_termino < '$TO_STR' AND NOT EXISTS (SELECT 1 FROM dbo.item_operacao_pdv it WHERE it.id_operacao = op.id_operacao AND it.cancelado = 0)" "sem_itens"
if ($semItens -and $semItens.Count -gt 0) { Wrn "PDV: $($semItens.Count) venda(s) sem itens ativos (ops.count > len(vendas))"; foreach ($s in $semItens | Select-Object -First 3) { Sub "op=$($s.id_operacao) | $($s.data_hora_termino)" } } else { Ok "PDV: Todas as vendas tem itens ativos" }

Write-Host "`n  [H.2] Itens sem vendedor (id_usuario_vendedor IS NULL)" -Fore Yellow
$semVend = Sql $DB_PDV "SELECT COUNT(*) AS qtd FROM dbo.item_operacao_pdv it JOIN dbo.operacao_pdv op ON op.id_operacao = it.id_operacao WHERE op.operacao=1 AND op.cancelado=0 AND it.cancelado=0 AND op.data_hora_termino >= '$FROM_STR' AND op.data_hora_termino < '$TO_STR' AND it.id_usuario_vendedor IS NULL" "sem_vendedor"
if ($semVend -and $semVend[0].qtd -gt 0) { Wrn "PDV: $($semVend[0].qtd) itens sem vendedor (gerara warning)" } else { Ok "PDV: Todos os itens tem vendedor" }

Write-Host "`n  [H.3] Anomalia: data_hora_termino no futuro" -Fore Yellow
$futuro = Sql $DB_PDV "SELECT COUNT(*) AS qtd FROM dbo.operacao_pdv WHERE data_hora_termino > GETDATE() AND operacao=1 AND cancelado=0" "futuro"
if ($futuro -and $futuro[0].qtd -gt 0) { Nok "$($futuro[0].qtd) operacoes com data no futuro!" "Relogio da maquina pode estar errado" } else { Ok "Nenhuma data no futuro" }

Write-Host "`n  [H.4] Colisao id_operacao PDV vs Gestao" -Fore Yellow
$colisao = Sql $DB_PDV "SELECT TOP 5 p.id_operacao FROM [$DB_PDV].dbo.operacao_pdv p JOIN [$DB_GESTAO].dbo.operacao_pdv g ON g.id_operacao = p.id_operacao WHERE p.operacao=1 AND p.cancelado=0 AND g.operacao=1 AND g.cancelado=0 AND g.origem=2 AND p.data_hora_termino >= '$FROM_STR'" "colisao"
if ($colisao -and $colisao.Count -gt 0) { Wrn "COLISAO: $($colisao.Count)+ IDs iguais em PDV e Gestao! O agent distingue por canal."; foreach ($c in $colisao) { Sub "id_operacao=$($c.id_operacao)" } } else { Ok "Sem colisao de IDs entre PDV e Gestao" }

Write-Host "`n  [H.5] Turnos curtos (< 5 min)" -Fore Yellow
$curtos = Sql $DB_PDV "SELECT COUNT(*) AS qtd FROM dbo.turno WHERE id_ponto_venda=$ID_PDV AND fechado=1 AND DATEDIFF(MINUTE, data_hora_inicio, data_hora_termino) < 5 AND data_hora_inicio >= '$FROM_STR'" "curtos"
if ($curtos -and $curtos[0].qtd -gt 0) { Wrn "$($curtos[0].qtd) turno(s) < 5 minutos" } else { Ok "Nenhum turno anormalmente curto" }

# ═══ I) EDGE CASES ═══
Hdr "[I] EDGE CASES E ANOMALIAS"

Write-Host "`n  [I.1] Valores negativos" -Fore Yellow
$negItens = Sql $DB_PDV "SELECT COUNT(*) AS qtd FROM dbo.item_operacao_pdv it JOIN dbo.operacao_pdv op ON op.id_operacao=it.id_operacao WHERE op.operacao=1 AND op.cancelado=0 AND it.cancelado=0 AND op.data_hora_termino >= '$FROM_STR' AND (it.valor_total_liquido < 0 OR it.quantidade_primaria < 0)" "negativos"
if ($negItens -and $negItens[0].qtd -gt 0) { Wrn "$($negItens[0].qtd) itens com valor ou qtd negativa" } else { Ok "Nenhum valor negativo em itens" }

Write-Host "`n  [I.2] Vendas Loja com id_turno NULL" -Fore Yellow
$lojaSemTurno = Sql $DB_GESTAO "SELECT COUNT(*) AS qtd FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND origem=2 AND id_filial=$ID_FILIAL AND data_hora_termino >= '$FROM_STR' AND id_turno IS NULL" "loja_null_turno"
if ($lojaSemTurno -and $lojaSemTurno[0].qtd -gt 0) { Sub "$($lojaSemTurno[0].qtd) vendas Loja com id_turno=NULL (normal -- venda sem turno)" } else { Sub "Todas as vendas Loja tem turno associado" }

Write-Host "`n  [I.3] Distribuicao de origem na Gestao" -Fore Yellow
$origens = Sql $DB_GESTAO "SELECT origem, COUNT(*) AS qtd FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 AND id_filial=$ID_FILIAL AND data_hora_termino >= '$FROM_STR' GROUP BY origem ORDER BY origem" "origens"
if ($origens) { foreach ($o in $origens) { $desc = switch ($o.origem) { 1 { "Caixa(PDV)" } 2 { "Loja" } default { "Desconhecido" } }; Sub "origem=$($o.origem) ($desc): $($o.qtd) vendas" } }

# ═══ J) SUMARIO ═══
Write-Host ""
Write-Host "================================================================" -Fore Cyan
Write-Host "  RESULTADO FINAL" -Fore Cyan
Write-Host "================================================================" -Fore Cyan
Write-Host "  [OK]   PASSOU:  $PASS" -Fore Green
Write-Host "  [WARN] AVISOS:  $WARN" -Fore Yellow
Write-Host "  [FAIL] FALHOU:  $FAIL" -Fore Red
Write-Host "================================================================" -Fore Cyan
if ($FAIL -eq 0 -and $WARN -eq 0) { Write-Host "  TUDO PERFEITO! Pode instalar o agent!" -Fore Green } elseif ($FAIL -eq 0) { Write-Host "  OK COM AVISOS -- instalar mas monitorar." -Fore Yellow } else { Write-Host "  FALHAS ENCONTRADAS -- corrigir antes de instalar!" -Fore Red }
Write-Host "================================================================" -Fore Cyan
Write-Host ""

Stop-Transcript | Out-Null
Write-Host "Resultado salvo em: $LOG" -Fore DarkGray
Write-Host "Abrindo arquivo..." -Fore DarkGray
notepad.exe $LOG
