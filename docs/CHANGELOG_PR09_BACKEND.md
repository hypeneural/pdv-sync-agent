# 🔔 CHANGELOG PR-09 — Nova Lógica de Fechamento de Caixa

**Data:** 2026-02-11
**Agent Version:** 2.0.0 → 2.0.1
**Schema Version:** 2.0 (sem breaking change)

> **TL;DR:** O agente agora envia POST **mesmo quando não há vendas novas**, se um turno (caixa) foi fechado. Vocês vão receber um campo novo `event_type` no JSON e precisam tratar payloads com `vendas: []` e `ops.count: 0`.

---

## 1. Por que mudou?

### Problema anterior

O agente rodava a cada 10 minutos e **só enviava POST se houvesse vendas novas**. Quando o operador fechava o caixa mas não havia vendas nos últimos minutos, o agente pulava o envio. Resultado:

```
20:30 — Última venda do turno
20:40 — Agente roda: 2 vendas → POST ✅
20:50 — Operador fecha o turno (sem vendas novas)
21:00 — Agente roda: 0 vendas → SKIP ❌ (NUNCA enviava o fechamento!)
21:05 — PC desligado
```

**Vocês nunca recebiam:**
- `fechado: true`
- `fechamento_declarado` (valores que o operador declarou ter no caixa)
- `falta_caixa` (diferença entre sistema e declarado)

### Correção

Agora o agente verifica: **tem vendas OU tem turno fechado?** Se sim, envia POST.

---

## 2. Campo novo: `event_type`

### Localização no JSON

```json
{
  "schema_version": "2.0",
  "event_type": "turno_closure",   // ← NOVO
  "agent": { ... },
  "store": { ... },
  // ...
}
```

### Valores possíveis

| `event_type` | Quando acontece | `vendas` | `ops.count` | `turnos[].fechado` |
|---|---|---|---|---|
| `"sales"` | Vendas normais, turno aberto | `[...]` com itens | `> 0` | `false` ou não presente |
| `"turno_closure"` | **Turno fechou, sem vendas novas** | `[]` vazio | `0` | `true` |
| `"mixed"` | Vendas + turno fechou na mesma janela | `[...]` com itens | `> 0` | `true` |

---

## 3. O que muda para vocês (Backend)

### 3.1 Aceitar payload com `vendas: []` e `ops.count: 0`

Antes vocês podiam assumir que todo POST tinha vendas. **Agora não mais.**

```php
// ❌ ANTES (vai quebrar)
if (empty($payload['vendas'])) {
    return response()->json(['error' => 'No sales'], 400);
}

// ✅ DEPOIS
$eventType = $payload['event_type'] ?? 'sales';

if ($eventType === 'turno_closure') {
    // Só fechamento — processar turnos, ignorar vendas
    $this->processTurnoClosure($payload['turnos']);
} elseif ($eventType === 'mixed') {
    // Vendas + fechamento
    $this->processVendas($payload['vendas']);
    $this->processTurnoClosure($payload['turnos']);
} else {
    // Payload normal de vendas
    $this->processVendas($payload['vendas']);
}
```

### 3.2 Processar dados de fechamento do turno

Quando `event_type` for `"turno_closure"` ou `"mixed"`, o array `turnos` terá dados completos de fechamento:

```json
{
  "event_type": "turno_closure",
  "turnos": [{
    "id_turno": "656335C4-D6C4-455A-8E3D-FF6B3F570C64",
    "sequencial": 2,
    "fechado": true,
    "data_hora_inicio": "2026-02-11T16:26:44-03:00",
    "data_hora_termino": "2026-02-11T21:50:29-03:00",
    "operador": {
      "id_usuario": 5,
      "nome": "João"
    },
    "totais_sistema": {
      "total": 1019.70,
      "qtd_vendas": 16,
      "por_pagamento": [
        {"id_finalizador": 2, "meio": "Cartão de crédito", "total": 637.80, "qtd_vendas": 7},
        {"id_finalizador": 1, "meio": "Dinheiro", "total": 135.00, "qtd_vendas": 4}
      ]
    },
    "fechamento_declarado": {
      "total": 940.70,
      "por_pagamento": [
        {"id_finalizador": 2, "meio": "Cartão de crédito", "total": 617.80},
        {"id_finalizador": 1, "meio": "Dinheiro", "total": 105.00}
      ]
    },
    "falta_caixa": {
      "total": -79.00,
      "por_pagamento": [
        {"id_finalizador": 2, "meio": "Cartão de crédito", "total": -20.00},
        {"id_finalizador": 1, "meio": "Dinheiro", "total": -30.00}
      ]
    }
  }],
  "vendas": [],
  "ops": {"count": 0, "ids": []}
}
```

### 3.3 Explicação de cada campo do turno

| Campo | Tipo | Descrição |
|---|---|---|
| `id_turno` | `string (UUID)` | Identificador único do turno no banco local da loja |
| `sequencial` | `int` | Número sequencial do turno no dia (1, 2, 3...) |
| `fechado` | `bool` | `true` = turno encerrado, `false` = turno ainda aberto |
| `data_hora_inicio` | `datetime ISO8601` | Quando o turno abriu (com timezone `-03:00`) |
| `data_hora_termino` | `datetime ISO8601 \| null` | Quando fechou. `null` se ainda aberto |
| `operador.id_usuario` | `int` | ID do operador de caixa (tabela `usuario` local) |
| `operador.nome` | `string` | Nome do operador |
| **`totais_sistema`** | `object` | **O que o sistema calculou** (soma das vendas reais) |
| `totais_sistema.total` | `decimal` | Total vendido no turno segundo o sistema |
| `totais_sistema.qtd_vendas` | `int` | Quantidade de vendas no turno |
| `totais_sistema.por_pagamento[]` | `array` | Breakdown por meio de pagamento (com `id_finalizador`, `meio`, `total`, `qtd_vendas`) |
| **`fechamento_declarado`** | `object \| null` | **O que o operador DECLAROU** ter no caixa ao fechar. `null` se turno aberto |
| `fechamento_declarado.total` | `decimal` | Total que o operador declarou |
| `fechamento_declarado.por_pagamento[]` | `array` | Breakdown declarado por meio (com `id_finalizador`, `meio`, `total`) |
| **`falta_caixa`** | `object \| null` | **Diferença** entre sistema e declarado. `null` se turno aberto |
| `falta_caixa.total` | `decimal` | Total da diferença (negativo = faltou, positivo = sobrou) |
| `falta_caixa.por_pagamento[]` | `array` | Diferença por meio de pagamento |

### 3.4 Regra de negócio sugerida

```
diferenca = totais_sistema.total - fechamento_declarado.total

Se diferenca > 0  → Falta no caixa (operador tem menos que o sistema)
Se diferenca < 0  → Sobra no caixa (operador tem mais que o sistema)
Se diferenca == 0 → Caixa conferido ✅
```

---

## 4. Exemplo completo dos 3 cenários

### Cenário A: `event_type = "sales"` (normal, sem mudança)

```json
{
  "schema_version": "2.0",
  "event_type": "sales",
  "turnos": [{
    "id_turno": "AAA-BBB-CCC",
    "fechado": false,
    "operador": {"id_usuario": 5, "nome": "João"},
    "totais_sistema": {"total": 200.00, "qtd_vendas": 3, "por_pagamento": [...]},
    "fechamento_declarado": null,
    "falta_caixa": null
  }],
  "vendas": [
    {"id_operacao": 12500, "total": 99.90, "itens": [...], "pagamentos": [...]},
    {"id_operacao": 12501, "total": 50.00, "itens": [...], "pagamentos": [...]},
    {"id_operacao": 12502, "total": 50.10, "itens": [...], "pagamentos": [...]}
  ],
  "ops": {"count": 3, "ids": [12500, 12501, 12502]}
}
```

### Cenário B: `event_type = "turno_closure"` (NOVO — caixa fechou sem vendas)

```json
{
  "schema_version": "2.0",
  "event_type": "turno_closure",
  "turnos": [{
    "id_turno": "AAA-BBB-CCC",
    "fechado": true,
    "data_hora_termino": "2026-02-11T21:50:29-03:00",
    "operador": {"id_usuario": 5, "nome": "João"},
    "totais_sistema": {"total": 1019.70, "qtd_vendas": 16, "por_pagamento": [...]},
    "fechamento_declarado": {"total": 940.70, "por_pagamento": [...]},
    "falta_caixa": {"total": -79.00, "por_pagamento": [...]}
  }],
  "vendas": [],
  "ops": {"count": 0, "ids": []}
}
```

> ⚠️ **Atenção:** `vendas` está vazio e `ops.count` é 0. **Isso NÃO é erro.** O dado importante aqui são os `turnos`.

### Cenário C: `event_type = "mixed"` (vendas + fechamento na mesma janela)

```json
{
  "schema_version": "2.0",
  "event_type": "mixed",
  "turnos": [{
    "id_turno": "AAA-BBB-CCC",
    "fechado": true,
    "fechamento_declarado": {"total": 940.70, "por_pagamento": [...]},
    "falta_caixa": {"total": -79.00, "por_pagamento": [...]}
  }],
  "vendas": [
    {"id_operacao": 12510, "total": 45.00, "itens": [...], "pagamentos": [...]}
  ],
  "ops": {"count": 1, "ids": [12510]}
}
```

---

## 5. Validação no backend

```php
// Validação simples do event_type
$validTypes = ['sales', 'turno_closure', 'mixed'];
$eventType = $payload['event_type'] ?? 'sales';

if (!in_array($eventType, $validTypes)) {
    Log::warning("Unknown event_type: $eventType");
    $eventType = 'sales'; // fallback seguro
}

// Se não tem event_type no JSON (agent antigo), assumir "sales"
```

---

## 6. Checklist para o backend

- [ ] Aceitar payloads com `vendas: []` sem retornar erro
- [ ] Ler e armazenar `event_type` do JSON
- [ ] Processar `turnos[].fechamento_declarado` quando presente
- [ ] Processar `turnos[].falta_caixa` quando presente
- [ ] Calcular diferença sistema vs declarado para dashboard
- [ ] Compatibilidade: se `event_type` não existir, assumir `"sales"`
