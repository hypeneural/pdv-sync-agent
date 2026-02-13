# Schema Changelog — PDV Sync Agent

## v2.0.1 (2026-02-11) — PR-09

**Payload raiz:**
- `event_type` (NEW) — tipo de evento: `"sales"` | `"turno_closure"` | `"mixed"` (default: `"sales"`)

**Comportamento:**
- Agente agora envia POST quando turno fecha sem vendas novas (`event_type: "turno_closure"`)
- Payloads com `vendas: []` e `ops.count: 0` são válidos quando `event_type != "sales"`

---

## v2.0 (2026-02-10)

**Payload raiz:**
- `schema_version` (NEW) — versão explícita do schema (`"2.0"`)

**agent:**
- `sent_at` agora com timezone `-03:00`

**turnos[]:**
- `data_hora_inicio`, `data_hora_termino` — agora com timezone `-03:00`
- `totais_sistema` — totais calculados pelo sistema por turno
- `fechamento_declarado` — valores declarados pelo operador (op=9)
- `falta_caixa` — diferença sistema vs declarado (op=4)

**vendas[]:**
- `data_hora` — agora com timezone `-03:00`
- `itens[]` — produtos com vendedor por item
- `pagamentos[]` — pagamentos com troco e parcelas

**resumo:**
- `by_vendor[]` — vendas por vendedor (item-level)
- `by_payment[]` — vendas por meio de pagamento

**integrity:**
- `sync_id` — SHA256 determinístico
- `warnings` — alertas de qualidade de dados

---

## v1.0 (2026-01)

Versão inicial. Payload com `sales` agregado apenas (sem detalhamento de turno ou vendas individuais).
