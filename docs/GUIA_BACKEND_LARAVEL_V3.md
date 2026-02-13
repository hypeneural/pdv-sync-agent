# 📋 Guia para o Time Backend (PHP/Laravel) — Agent v3.0 Melhorias

**Data:** 2026-02-12
**De:** Time Agent Python → **Para:** Time Backend Laravel
**Contexto:** O agent Python que roda no PDV foi atualizado. Este documento descreve o que mudou no JSON do webhook, o que vocês precisam saber, e dicas para consumir os dados corretamente.

---

## 1. O que mudou no JSON do Agent v3.0

### 1.1 Header `X-PDV-Schema-Version` corrigido

| Antes | Depois |
|---|---|
| `"X-PDV-Schema-Version": "2.0"` (hardcoded) | `"X-PDV-Schema-Version": "3.0"` (dinâmico) |

> [!WARNING]
> Se vocês fazem validação do header contra `schema_version` do body, agora vai bater (`"3.0"` = `"3.0"`). Antes havia mismatch (`"2.0"` header vs `"3.0"` body).

**Ação necessária:** Nenhuma — o backend já lê `schema_version` do body. Se houver validação de header, verificar que aceita `"3.0"`.

---

### 1.2 Novos campos em `turnos[]` (TurnoDetail)

Antes esses campos só vinham via `snapshot_turnos[]`. Agora **também** vêm em `turnos[]` (dados em tempo real).

| Campo | Tipo | Exemplo | Quando vem |
|---|---|---|---|
| `duracao_minutos` | `int \| null` | `480` | Quando turno tem início E término |
| `periodo` | `string \| null` | `"MATUTINO"` / `"VESPERTINO"` / `"NOTURNO"` | Quando turno tem início |
| `qtd_vendas` | `int` | `42` | Sempre (0 se sem vendas) |
| `total_vendas` | `decimal` | `"3250.50"` | Sempre |
| `qtd_vendedores` | `int` | `3` | Sempre (0 no detalhe, preciso no snapshot) |

> [!NOTE]
> O `ProcessPdvSyncJob.php` **já lê** esses campos nas linhas 298-308:
> ```php
> 'duracao_minutos' => $this->asInt(data_get($turno, 'duracao_minutos')),
> 'periodo'         => $this->asString(data_get($turno, 'periodo')),
> 'qtd_vendas'      => max(0, (int) data_get($turno, 'qtd_vendas', 0)),
> 'total_vendas'    => $this->asDecimal(data_get($turno, 'total_vendas', 0), 2),
> 'qtd_vendedores'  => max(0, (int) data_get($turno, 'qtd_vendedores', 0)),
> ```
> **Ação:** Nenhuma. Antes esses campos vinham `null`/`0`, agora vêm preenchidos.

---

### 1.3 `canal` agora é setado na construção (não patcheado)

Antes o campo `canal` em `vendas[]` era adicionado manualmente depois de construir o objeto. Agora é setado na construção — **o JSON output não muda**, mas é mais confiável internamente.

**Ação necessária:** Nenhuma. O campo `canal` já existia e continua com os mesmos valores:
- `"HIPER_CAIXA"` — vendas do caixa (HiperPdv)
- `"HIPER_LOJA"` — vendas de balcão (Hiper Gestão)

---

### 1.4 Troco corrigido em vendas Loja (`HIPER_LOJA`)

**Bug corrigido:** Antes, em vendas da Loja com múltiplos meios de pagamento, o troco era **duplicado em todos os finalizadores**. Por exemplo:

```
# ANTES (BUG) — Venda com Dinheiro + Cartão
pagamentos: [
  { "meio": "Dinheiro", "valor": 50.00, "troco": 5.00 },  ← correto
  { "meio": "Cartão",   "valor": 30.00, "troco": 5.00 }   ← ERRADO! troco deveria ser 0
]

# DEPOIS (CORRIGIDO)
pagamentos: [
  { "meio": "Dinheiro", "valor": 50.00, "troco": 5.00 },  ← correto
  { "meio": "Cartão",   "valor": 30.00, "troco": 0.00 }   ← correto
]
```

> [!IMPORTANT]
> Se vocês fazem soma de troco por venda, **o valor vai mudar** para vendas Loja que tinham múltiplos finalizadores. Antes somava troco duplicado; agora soma apenas 1x.
>
> Se vocês têm relatórios de troco, revisem vendas Loja históricas que tinham 2+ finalizadores.

---

### 1.5 Warning quando banco Gestão falha

O JSON agora inclui warnings diagnósticos em `integrity.warnings`:

```json
{
  "integrity": {
    "sync_id": "abc123...",
    "warnings": [
      "GESTAO_DB_FAILURE: [Errno ...] Connection refused"
    ]
  }
}
```

**Dica para o backend:**
```php
$warnings = data_get($payload, 'integrity.warnings', []);
$hasGestaoFailure = collect($warnings)->contains(fn($w) => str_starts_with($w, 'GESTAO_DB_FAILURE'));

if ($hasGestaoFailure) {
    // Dados HIPER_LOJA podem estar incompletos neste ciclo
    // Considerar: não zerrar contadores Loja, apenas ignorar
    Log::warning('Dados Loja podem estar incompletos', ['sync_id' => $sync->sync_id]);
}
```

---

## 2. Mapa Completo: JSON → Tabelas

### 2.1 `vendas[]` → `pdv_vendas` + `pdv_venda_itens` + `pdv_venda_pagamentos`

```
vendas[].id_operacao     → pdv_vendas.id_operacao        (UPSERT KEY)
vendas[].canal           → pdv_vendas.canal              (UPSERT KEY: "HIPER_CAIXA"|"HIPER_LOJA")
vendas[].data_hora       → pdv_vendas.data_hora
vendas[].total           → pdv_vendas.total
vendas[].id_turno        → pdv_vendas.id_turno

vendas[].itens[].line_id       → pdv_venda_itens.line_id     (UPSERT KEY se > 0)
vendas[].itens[].id_produto    → pdv_venda_itens.id_produto
vendas[].itens[].nome          → pdv_venda_itens.nome_produto
vendas[].itens[].qtd           → pdv_venda_itens.qtd
vendas[].itens[].preco_unit    → pdv_venda_itens.preco_unit
vendas[].itens[].total         → pdv_venda_itens.total
vendas[].itens[].desconto      → pdv_venda_itens.desconto
vendas[].itens[].vendedor.id_usuario  → pdv_venda_itens.vendedor_pdv_id
vendas[].itens[].vendedor.nome        → pdv_venda_itens.vendedor_nome

vendas[].pagamentos[].line_id         → pdv_venda_pagamentos.line_id  (UPSERT KEY se > 0)
vendas[].pagamentos[].id_finalizador  → pdv_venda_pagamentos.id_finalizador
vendas[].pagamentos[].meio            → pdv_venda_pagamentos.meio_pagamento  ⚠️
vendas[].pagamentos[].valor           → pdv_venda_pagamentos.valor
vendas[].pagamentos[].troco           → pdv_venda_pagamentos.troco
vendas[].pagamentos[].parcelas        → pdv_venda_pagamentos.parcelas
```

> [!CAUTION]
> **Atenção ao campo `meio`:** O JSON envia `"meio"` mas a coluna no banco é `meio_pagamento`. O backend já faz essa conversão na linha 545:
> ```php
> $meioPagamento = $this->asString(data_get($pagamento, 'meio'));
> ```
> **NÃO renomear no agent.** O nome `meio` é o contrato correto.

---

### 2.2 `turnos[]` → `pdv_turnos` + `pdv_turno_pagamentos`

```
turnos[].id_turno                → pdv_turnos.id_turno       (UPSERT KEY)
turnos[].sequencial              → pdv_turnos.sequencial
turnos[].fechado                 → pdv_turnos.fechado
turnos[].data_hora_inicio        → pdv_turnos.data_hora_inicio
turnos[].data_hora_termino       → pdv_turnos.data_hora_termino
turnos[].duracao_minutos         → pdv_turnos.duracao_minutos      🆕 agora preenchido
turnos[].periodo                 → pdv_turnos.periodo              🆕 agora preenchido
turnos[].operador.id_usuario     → pdv_turnos.operador_pdv_id
turnos[].operador.nome           → pdv_turnos.operador_nome
turnos[].responsavel.id_usuario  → pdv_turnos.responsavel_pdv_id
turnos[].responsavel.nome        → pdv_turnos.responsavel_nome
turnos[].qtd_vendas              → pdv_turnos.qtd_vendas           🆕 agora preenchido
turnos[].total_vendas            → pdv_turnos.total_vendas         🆕 agora preenchido
turnos[].qtd_vendedores          → pdv_turnos.qtd_vendedores       🆕 (placeholder=0)
turnos[].totais_sistema.total    → pdv_turnos.total_sistema
turnos[].totais_sistema.qtd_vendas → pdv_turnos.qtd_vendas_sistema
turnos[].fechamento_declarado.total → pdv_turnos.total_declarado
turnos[].falta_caixa.total       → pdv_turnos.total_falta

turnos[].totais_sistema.por_pagamento[].id_finalizador → pdv_turno_pagamentos.id_finalizador
turnos[].totais_sistema.por_pagamento[].meio           → pdv_turno_pagamentos.meio_pagamento
turnos[].totais_sistema.por_pagamento[].total          → pdv_turno_pagamentos.total
turnos[].totais_sistema.por_pagamento[].qtd_vendas     → pdv_turno_pagamentos.qtd_vendas
```

---

### 2.3 `snapshot_turnos[]` → `pdv_turnos` (via processSnapshotTurnos)

Snapshots são as **últimas 10 turnos fechados**. Upsert na mesma tabela `pdv_turnos` com dados mais completos (inclusive `qtd_vendedores` preciso).

### 2.4 `snapshot_vendas[]` → `pdv_vendas_resumo`

Snapshots das **últimas 10 vendas** (PDV + Loja combinados). Upsert por `[store_pdv_id, canal, id_operacao]`.

---

## 3. Chaves de Deduplicação (como não duplicar)

| Tabela | Upsert Keys | Quando usar |
|---|---|---|
| `pdv_turnos` | `[store_pdv_id, id_turno]` | Sempre — agent pode reenviar mesmo turno |
| `pdv_turno_pagamentos` | `[store_pdv_id, id_turno, tipo, id_finalizador]` | `tipo` = sistema/declarado/falta |
| `pdv_vendas` | `[store_pdv_id, canal, id_operacao]` | `canal` diferencia PDV vs Loja |
| `pdv_venda_itens` (com line_id) | `[store_pdv_id, canal, line_id]` | Preferencial — PK estável |
| `pdv_venda_itens` (sem line_id) | `[store_pdv_id, canal, id_operacao, row_hash]` | Fallback quando line_id é null |
| `pdv_venda_pagamentos` (com line_id) | `[store_pdv_id, canal, line_id]` | Preferencial |
| `pdv_venda_pagamentos` (sem line_id) | `[store_pdv_id, canal, id_operacao, row_hash]` | Fallback |
| `pdv_vendas_resumo` | `[store_pdv_id, canal, id_operacao]` | Snapshot vendas |

> [!TIP]
> **Regra de ouro:** O `sync_id` é determinístico (SHA256 de `store_id|from|to`). Se o agent reenvia o mesmo window, o `sync_id` é idêntico. Use `sync_id` para detectar reprocessamento no nível do payload, mas confie nos upsert keys para deduplicação no nível da row.

---

## 4. Dicas Práticas para o Backend

### 4.1 Filtrar vendas por canal

```php
// Contar vendas PDV vs Loja neste sync
$vendasPdv = collect(data_get($payload, 'vendas', []))
    ->filter(fn($v) => data_get($v, 'canal') === 'HIPER_CAIXA');

$vendasLoja = collect(data_get($payload, 'vendas', []))
    ->filter(fn($v) => data_get($v, 'canal') === 'HIPER_LOJA');

Log::info("PDV: {$vendasPdv->count()}, Loja: {$vendasLoja->count()}");
```

### 4.2 Detectar turnos com falta de caixa

```php
$turnosComFalta = collect(data_get($payload, 'turnos', []))
    ->filter(fn($t) => data_get($t, 'falta_caixa.total', 0) > 0);

foreach ($turnosComFalta as $turno) {
    $falta = data_get($turno, 'falta_caixa.total');
    $operador = data_get($turno, 'operador.nome');
    // Alerta: operador X tem falta de R$ Y
}
```

### 4.3 Usar período do turno para relatórios

```php
// Agrupar vendas por período do dia
$turnosPorPeriodo = collect(data_get($payload, 'turnos', []))
    ->groupBy(fn($t) => data_get($t, 'periodo', 'INDEFINIDO'));

// $turnosPorPeriodo['MATUTINO'] → turnos da manhã
// $turnosPorPeriodo['VESPERTINO'] → turnos da tarde
// $turnosPorPeriodo['NOTURNO'] → turnos da noite
```

### 4.4 Detectar dados Loja incompletos

```php
$warnings = data_get($payload, 'integrity.warnings', []);
$gestaoDown = collect($warnings)->contains(fn($w) => str_starts_with($w, 'GESTAO_DB_FAILURE'));

if ($gestaoDown) {
    // NÃO zerar indicadores Loja — apenas pular a atualização
    // Os dados chegarão no próximo sync quando a conexão voltar
}
```

### 4.5 Validar consistência de totais

```php
// O total em vendas[].total é calculado pela soma dos itens
// Comparar com totais_sistema do turno para detectar inconsistências
foreach (data_get($payload, 'turnos', []) as $turno) {
    $totalSistema = (float) data_get($turno, 'totais_sistema.total', 0);
    $totalVendas  = (float) data_get($turno, 'total_vendas', 0);

    // total_vendas vem do sistema (derivado de totais_sistema.qtd_vendas)
    // Se há divergência significativa, logar warning
    if (abs($totalSistema - $totalVendas) > 0.01) {
        Log::warning('Divergência entre total_sistema e total_vendas', [
            'id_turno' => data_get($turno, 'id_turno'),
            'total_sistema' => $totalSistema,
            'total_vendas' => $totalVendas,
        ]);
    }
}
```

---

## 5. Perguntas Frequentes (Q&A)

### Q: Por que `vendas[].pagamentos[].meio` e não `meio_pagamento`?
**R:** Convenção do agent Python. O backend converte na extração (linha 545). **Não mudar esse nome** — é o contrato estável.

### Q: `qtd_vendedores` vem 0 nos turnos — é bug?
**R:** No `turnos[]` detalhado, `qtd_vendedores` precisa de um JOIN extra que o detalhe não faz (para manter o payload leve). O valor **preciso** vem via `snapshot_turnos[]`, que é processado pela `processSnapshotTurnos()` e faz upsert na mesma tabela `pdv_turnos`. Na prática, o snapshot sobrescreve com o valor correto.

### Q: Uma venda pode aparecer tanto em `vendas[]` quanto em `snapshot_vendas[]`?
**R:** Sim. `vendas[]` são as vendas da janela atual (10 min). `snapshot_vendas[]` são as últimas 10 vendas gerais (podem repetir). Os upsert keys garantem que não há duplicação — a última escrita vence.

### Q: O que acontece se o agent manda o mesmo payload 2x?
**R:** O `sync_id` é determinístico. Na tabela `pdv_syncs`, haverá 2 registros com o mesmo `sync_id` mas `request_id` diferentes. O `ProcessPdvSyncJob` fará upsert nos dados — como as keys são iguais, é idempotente. Nenhum dado duplica.

### Q: Como sei se uma venda é do PDV ou da Loja?
**R:** Campo `canal`:
- `"HIPER_CAIXA"` = PDV (caixa registradora)
- `"HIPER_LOJA"` = Loja (balcão, vendas gestão)

O backend resolve isso via `resolveVendaCanal()` que valida o canal e faz fallback.

### Q: Os `snapshot_turnos` sobrescrevem os `turnos`?
**R:** Sim! Ambos fazem upsert na mesma tabela `pdv_turnos` com key `[store_pdv_id, id_turno]`. O snapshot tem dados mais completos (como `qtd_vendedores` preciso), então a ordem de processamento importa. Atualmente o job executa: `processTurnos()` → `processSnapshotTurnos()`, ou seja o snapshot "completa" o que o turno detalhe não trouxe.

---

## 6. Resumo das Ações para o Backend

| Item | Ação necessária | Urgência |
|---|---|---|
| Header `X-PDV-Schema-Version: "3.0"` | Verificar se aceita `"3.0"` | ⚠️ Média |
| Novos campos TurnoDetail (v3) | Nenhuma — já são lidos | ✅ Zero |
| Canal em vendas | Nenhuma — já processado | ✅ Zero |
| Troco Loja corrigido | Revisar relatórios de troco | ⚠️ Dados históricos |
| Warning Gestão DB | Considerar tratar `GESTAO_DB_FAILURE` | 💡 Sugestão |
| Campo `meio` | **NÃO renomear** — contrato estável | ⛔ Não mexer |
