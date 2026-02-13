# Respostas Pós-Análise — Time JSON PDV Sync Agent v3.0

**Data:** 2026-02-12
**De:** Time Integração PDV (gerador do JSON / agente)
**Para:** Time Backend (`maiscapinhas-erp-api`)
**Método:** Análise minuciosa do código-fonte do agente + código-fonte do backend

> [!IMPORTANT]
> Todas as respostas foram verificadas diretamente no código. Cada resposta inclui o arquivo e linha exata de onde a evidência vem.

---

## 🔴 BUG ENCONTRADO DURANTE ANÁLISE

Antes das respostas, um **bug real** encontrado que afeta P0.3:

```diff
# sender.py:201
- "X-PDV-Schema-Version": "2.0",
+ "X-PDV-Schema-Version": SCHEMA_VERSION,  # = "3.0"
```

O header está **hardcoded** como `"2.0"` no [sender.py:201](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/sender.py#L201), mesmo com o agente já na versão 3.0.0 (`__init__.py:6` → `SCHEMA_VERSION = "3.0"`). Isso explica o mismatch que o backend observou nos payloads do n8n.

**Ação necessária:** Corrigir o agente para usar `SCHEMA_VERSION` importado de `__init__.py`. O backend também precisa incluir `'3.0'` na lista `pdv.supported_schema_versions` do config.

---

## Respostas P0 (Bloqueantes)

---

### P0.1 — `line_id` de item/pagamento pode colidir entre canais?

- **ID:** P0.1
- **Resposta curta:** ✅ **SIM, pode colidir.**
- **Detalhe técnico:**

`line_id` de **itens** vem de:
- HiperPdv: `it.id_item_operacao_pdv` → [queries.py:468](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L468)
- Hiper Gestão: `it.id_item_operacao_pdv` → [queries_gestao.py:126](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L126)

`line_id` de **pagamentos** vem de:
- HiperPdv: `fo.id_finalizador_operacao_pdv` → [queries.py:514](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L514)
- Hiper Gestão: `fo.id_finalizador_operacao_pdv` → [queries_gestao.py:180](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L180)

São colunas `IDENTITY` em **databases SQL Server separados**. Cada database gera sua sequência independentemente.

> Cenário real: HiperPdv pode ter `id_item_operacao_pdv = 50000` e Hiper Gestão também pode ter `id_item_operacao_pdv = 50000` — itens completamente diferentes.

- **Exemplo de payload:**
```json
{"canal": "HIPER_CAIXA", "id_operacao": 12380, "itens": [{"line_id": 50000, "nome": "Capinha X"}]}
{"canal": "HIPER_LOJA",  "id_operacao": 12380, "itens": [{"line_id": 50000, "nome": "Capinha Y"}]}
```

- **Impacto para o backend:**

A chave de UPSERT atual `(store_pdv_id, line_id)` no `ProcessPdvSyncJob.php:597` pode sobrescrever linhas de um canal com linhas de outro:

```php
// ProcessPdvSyncJob.php:594-598
$this->upsertRows(
    'pdv_venda_itens',
    $itemRowsByLineId,
    ['store_pdv_id', 'line_id'],  // ← PRECISA incluir 'canal'
    $itemUpdateColumnsByLineId
);
```

- **Decisão final:** Adicionar coluna `canal` nas tabelas filhas (`pdv_venda_itens`, `pdv_venda_pagamentos`) e alterar chave UPSERT para `(store_pdv_id, canal, line_id)`.
- **Prazo:** Requer migration no backend + atualização do job. Agente já envia `canal` no nível da venda; basta persistir nas linhas.
- **Responsável:** Time Backend (migration + job).

---

### P0.2 — Mesma tupla `(store, id_operacao, line_id)` com conteúdo diferente entre canais?

- **ID:** P0.2
- **Resposta curta:** ✅ **SIM, confirmado. Risco real.**
- **Detalhe técnico:**

Como demonstrado acima:
1. `id_operacao` colide entre canais (IDENTITY independentes por DB)
2. `line_id` colide entre canais (mesma razão)
3. Portanto a mesma tupla `(store=13, id_operacao=12380, line_id=50000)` pode existir com **produtos completamente diferentes** — um é HIPER_CAIXA, outro é HIPER_LOJA.

- **Impacto para o backend:**

Sem `canal` como discriminador, relatórios agregados hoje podem estar misturando dados dos dois sistemas. Isto afeta:
- Ranking de vendedores (itens de HIPER_LOJA atribuídos ao canal errado)
- Totais financeiros por meio de pagamento
- Contagem de itens por venda

- **Decisão final:** `canal` é **obrigatório** como parte da chave em todas as tabelas que referenciam vendas (pai e filhas).

---

### P0.3 — Header `X-PDV-Schema-Version` em produção

- **ID:** P0.3
- **Resposta curta:** **BUG CONFIRMADO no agente.**
- **Detalhe técnico:**

O agente v3.0.0 está enviando:
- **Body:** `"schema_version": "3.0"` ✅ correto (vem de `__init__.py:6`)
- **Header:** `"X-PDV-Schema-Version": "2.0"` ❌ hardcoded em [sender.py:201](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/sender.py#L201)

Não existe proxy que sobrescreve. O bug está no código do agente.

- **Exemplo do código atual:**
```python
# sender.py:195-202
def _get_headers(self) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {self.token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-PDV-Schema-Version": "2.0",  # ← BUG: deveria ser SCHEMA_VERSION
    }
```

- **Correção necessária (agente):**
```python
from . import SCHEMA_VERSION

def _get_headers(self) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {self.token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-PDV-Schema-Version": SCHEMA_VERSION,  # → "3.0"
    }
```

- **Impacto para o backend:**

Enquanto não corrigido, o backend tem duas opções:
1. **Recomendada:** Ignorar o header e confiar apenas no body `schema_version` para roteamento
2. **Alt:** Aceitar ambos `2.0` e `3.0` como válidos temporariamente

O controller ([PdvSyncController.php:69-78](file:///c:/Users/Usuario/Desktop/maiscapinhas/maiscapinhas-erp-api/app/Http/Controllers/Api/V1/PdvSyncController.php#L69-L78)) rejeita com `422` quando header ≠ body. Enquanto a config `pdv.supported_schema_versions` não incluir `3.0`, qualquer header `3.0` seria rejeitado. Porém, como o header chega `2.0` e body `3.0`, o mismatch check na linha 80 causará 422.

**Paradoxo atual:** O payload v3 está passando porque o backend ainda lista `supported_schema_versions = ['2.0']` e header = `2.0`, então o header check passa, mas o mismatch check (`header 2.0 ≠ body 3.0`) deveria rejeitar. Verificar se existe algum ambiente onde essa validação está desabilitada.

- **Prazo:** Correção no agente: imediata (1 linha). Atualização do backend: incluir `3.0` na config.
- **Responsável:** Time Integração (fix no agente) + Time Backend (config update).

---

### P0.4 — Semântica oficial de cancelamento em curto prazo

- **ID:** P0.4
- **Resposta curta:** **"Não confiar para cancelamento automático"** — com mitigação via snapshot.
- **Detalhe técnico:**

O agente **somente consulta vendas com** `cancelado = 0`:
- [queries.py:313](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L313): `AND op.cancelado = 0`
- [queries_gestao.py:53](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L53): `AND op.cancelado = 0`

Uma venda cancelada **nunca é enviada como evento de cancelamento**. Se foi enviada como válida e depois cancelada no Hiper:
1. No próximo sync, ela simplesmente **não aparece** (porque `cancelado = 1` no DB de origem)
2. No `snapshot_vendas[]`, ela **sai do TOP 10** (o snapshot só mostra `cancelado = 0`)

Porém, o snapshot não garante cobertura:
- Se a venda cancelada já saiu do TOP 10 por idade, ela desaparece silenciosamente
- Se a venda está fora da janela recente, o backend nunca sabe que foi cancelada

- **Regra oficial recomendada:**

```
1. NÃO cancelar automaticamente vendas que "sumiram do snapshot"
2. Usar snapshots para DETECTAR possíveis cancelamentos (flag/alerta)
3. Manter vendas como ATIVAS até prova em contrário
4. Para reconciliação formal, consultar base de origem manualmente
```

- **Impacto para o backend:** Adicionar campo `last_seen_in_snapshot_at` opcional em `pdv_vendas` para tracking. Se uma venda não aparece no snapshot por X dias consecutivos, gerar alerta.
- **Prazo:** Sem mudança no agente agora. Evento dedicado de cancelamento previsto para v3.1.

---

### P0.5 — `id_turno` para vendas `HIPER_LOJA`

- **ID:** P0.5
- **Resposta curta:** `id_turno` **pode vir preenchido** para HIPER_LOJA.
- **Detalhe técnico:**

Na query de Gestão, o `id_turno` é lido diretamente da tabela `operacao_pdv`:

```sql
-- queries_gestao.py:42-50
SELECT op.id_operacao, ...,
       CONVERT(VARCHAR(36), op.id_turno) AS id_turno
FROM dbo.operacao_pdv op
WHERE op.operacao = 1 AND op.cancelado = 0 AND op.origem = 2
```

O campo `id_turno` existe na tabela `operacao_pdv` do Gestão (Hiper Loja). Vendas de Loja **são vinculadas a turnos** quando o sistema PDV está operando com turno aberto. O turno é o **mesmo UUID** usado no HiperPdv (a tabela `turno` é compartilhada).

Cenários:
| Cenário | `id_turno` em HIPER_LOJA |
|---|---|
| **Loja com turno aberto** (terminal PDV ativo) | ✅ Preenchido (mesmo UUID do turno) |
| **Loja sem terminal PDV** (venda somente pela interface Gestão) | ⚠️ Pode ser NULL |
| **Loja com turno fechado** (operação fora de turno) | ⚠️ Pode ser NULL |

- **Impacto para o backend:** Filtros por turno podem retornar vendas Loja se o turno for compartilhado. Isso é **comportamento esperado** — se a loja operou durante aquele turno, as vendas de Loja pertencem ao turno.
- **Decisão final:** Manter `id_turno` nullable para HIPER_LOJA. Em telas de fechamento de turno, incluir vendas de ambos os canais vinculadas ao mesmo `id_turno`.

---

### P0.6 — Eventual terceiro canal

- **ID:** P0.6
- **Resposta curta:** **Não há roadmap definido**, mas é possível a médio prazo.
- **Detalhe técnico:**

Atualmente o agente suporta apenas dois canais, definidos no código:
- `canal = "HIPER_CAIXA"` (default) → [payload.py:174](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L174)
- `canal = "HIPER_LOJA"` (explícito) → [runner.py:375](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/runner.py#L375)

Possíveis canais futuros:
- `HIPER_DELIVERY` → se/quando o Hiper adicionar módulo de delivery nativo
- `HIPER_ECOMMERCE` → para vendas de e-commerce

- **Estratégia de compatibilidade:**

```php
// NÃO fazer:
if ($canal === 'HIPER_CAIXA') { ... }
elseif ($canal === 'HIPER_LOJA') { ... }

// FAZER:
// Usar canal como valor dinâmico, não enum hardcoded
$canaisConhecidos = ['HIPER_CAIXA', 'HIPER_LOJA'];
if (!in_array($canal, $canaisConhecidos)) {
    // Aceitar mas marcar risk_flag 'canal_desconhecido'
    Log::warning('Unknown canal', ['canal' => $canal]);
}
```

- **Impacto para o backend:** Armazenar `canal` como `VARCHAR(30)` (não enum). Tratar canais desconhecidos como risk flag, não como rejeição.
- **Decisão final:** Design para flexibilidade. Canal é string livre com valores conhecidos.

---

## Respostas P1 (Alta Prioridade)

---

### P1.1 — Regra exata de `responsavel` no turno

- **ID:** P1.1
- **Resposta curta:** Desempate é **arbitrário** (SQL Server decide).
- **Detalhe técnico:**

A query em [queries.py:688-698](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L688-L698):

```sql
SELECT TOP 1 uv.id_usuario, uv.nome
FROM dbo.operacao_pdv ov
JOIN dbo.item_operacao_pdv iv ON iv.id_operacao = ov.id_operacao
JOIN dbo.usuario uv ON uv.id_usuario = iv.id_usuario_vendedor
WHERE ov.id_turno = ? AND ov.operacao = 1 AND ov.cancelado = 0 AND iv.cancelado = 0
GROUP BY uv.id_usuario, uv.nome
ORDER BY COUNT(*) DESC
```

- Critério primário: `COUNT(*)` de itens vendidos (DESC)
- Em empate: SQL Server retorna o primeiro da iteração interna — **não determinístico**
- Não há `ORDER BY` secundário (nem por valor, nem por id, nem por horário)

- **Impacto para o backend:** Se o backend precisa de reproducibilidade exata:
  1. Aceitar o `responsavel` como vem (autoridade é o agente)
  2. OU recalcular usando `pdv_venda_itens` com tiebreaker explícito

- **Sugestão:** Adicionar tiebreaker `ORDER BY COUNT(*) DESC, SUM(valor_total_liquido) DESC, uv.id_usuario ASC` no agente para determinismo.
- **Decisão final:** Para v3.0, aceitar como está. Melhoria de tiebreaker na v3.1.

---

### P1.2 — `total_sistema` vs `total_vendas`

- **ID:** P1.2
- **Resposta curta:** São **conceitos diferentes** e podem divergir.
- **Detalhe técnico:**

Fonte: [payload.py:312-338](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L312-L338)

| Campo | Semântica | Origem | Pode divergir? |
|---|---|---|---|
| `totais_sistema.total` | Soma dos **pagamentos** (finalizadores) de todas as vendas do turno | `SUM(fo.valor)` agrupado por finalizador, método `get_payments_by_method_for_turno` | — |
| `totais_sistema.qtd_vendas` | Quantidade de vendas distintas (operações) | `MAX(qtd_vendas)` dos métodos de pagamento (aprox.) | — |
| `snapshot_turnos[].total_vendas` | Soma dos **itens** (`valor_total_liquido`) de todas as vendas do turno | `SUM(it.valor_total_liquido)` em [queries.py:594-598](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L594-L598) | ✅ |

**Quando divergem:** Quando há **troco**. O `total_sistema` inclui os valores pagos (incluindo o excedente em dinheiro). O `total_vendas` soma apenas o valor líquido dos itens.

Exemplo:
- Venda de R$ 95,00 paga com R$ 100,00 em dinheiro (troco R$ 5,00)
- `total_vendas` = R$ 95,00 (valor dos itens)
- `total_sistema` via finalizadores = R$ 100,00 (valor pago — troco é separado)

- **Decisão final:**
  - Para **fechamento de caixa**: usar `totais_sistema.total` (visão do pagamento)
  - Para **faturamento**: usar soma dos itens (total_vendas via snapshot ou recalcular)
  - Para **dashboard geral**: usar `totais_sistema.total` para consistência

---

### P1.3 — `falta_caixa.total` pode ser negativo?

- **ID:** P1.3
- **Resposta curta:** ✅ **SIM, pode ser negativo** (significa sobra).
- **Detalhe técnico:**

`falta_caixa` vem da operação tipo 4 (`op=4`) no SQL Server. A query em [queries.py:261-287](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L261-L287):

```sql
SELECT fo.id_finalizador, ..., SUM(ISNULL(fo.valor, 0)) AS total_falta
FROM dbo.operacao_pdv op
JOIN dbo.finalizador_operacao_pdv fo ON fo.id_operacao = op.id_operacao
WHERE op.id_turno = ? AND op.operacao = 4 AND op.cancelado = 0
```

O Hiper ERP grava o valor da falta/sobra diretamente na `op=4`. A fórmula é calculada **pelo Hiper**, não pelo agente:

```
falta_caixa = sistema - declarado
  → positivo = FALTA (operador tem menos que o sistema espera)
  → negativo = SOBRA (operador tem mais que o sistema espera)
```

O agente simplesmente lê e repassa o valor como está.

- **Impacto para o backend:** Aceitar valores negativos. Nos dashboards:
  - `falta_caixa.total > 0` → exibir como "Falta: R$ X,XX" (vermelho)
  - `falta_caixa.total < 0` → exibir como "Sobra: R$ X,XX" (verde)
  - `falta_caixa.total = 0` → "Conferido" (neutro)

---

### P1.4 — Precisão decimal oficial

- **ID:** P1.4
- **Resposta curta:** Moeda = 2 casas, quantidade = 3 casas.
- **Detalhe técnico:**

| Campo | Tipo no SQL Server | Escala no payload | Tipo no backend |
|---|---|---|---|
| `valor`, `total`, `preco_unit`, `troco` | `decimal(18,2)` / `money` | 2 casas | `decimal(14,2)` |
| `qtd` (quantidade) | `decimal(18,3)` | 3 casas | `decimal(14,3)` sugerido |
| `desconto` | `decimal(18,2)` | 2 casas | `decimal(14,2)` |

O agente usa `Decimal` do Python para manter precisão: [payload.py:90](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L90).

- **Exceções:** Não existem. Todas as moedas são BRL com 2 casas. Quantidade usa 3 casas para suportar produtos vendidos por peso (0.500 kg).
- **Impacto para o backend:** Verificar que `pdv_venda_itens.qtd` usa `decimal(14,3)` e não `decimal(14,2)`.

---

### P1.5 — Timezone operacional

- **ID:** P1.5
- **Resposta curta:** Todos os datetimes saem com offset BRT (`-03:00`).
- **Detalhe técnico:**

A função `_aware()` em [payload.py:27-33](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L27-L33):

```python
BRT = timezone(timedelta(hours=-3))  # __init__.py:7

def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    """Attach BRT timezone to naive datetimes from SQL Server."""
    if dt is None:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=BRT)
    return dt
```

SQL Server armazena datetimes **naive** (sem timezone). O agente assume que todos são BRT (America/Sao_Paulo sem DST) e anexa `-03:00`.

- **Atenção:** Não há verificação se a loja está em timezone diferente. Para lojas fora de UTC-3 (hipotético), os datetimes viriam com offset incorreto.
- **Impacto para o backend:**
  - O `PdvDateTime::parseToUtc()` no controller já converte para UTC — ✅ correto
  - Garantir que `pdv.naive_datetime_timezone` em `config/pdv.php:41` está como `'America/Sao_Paulo'`
  - **Todas as lojas atualmente** estão no BRT. Sem risco imediato.

---

### P1.6 — Classificação de `periodo`

- **ID:** P1.6
- **Resposta curta:** Baseado no **horário de início** do turno.
- **Detalhe técnico:**

Código em [runner.py:296-305](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/runner.py#L296-L305):

```python
inicio = row.get("data_hora_inicio")
periodo = None
if inicio:
    hora = inicio.hour if hasattr(inicio, 'hour') else 0
    if hora < 12:
        periodo = "MATUTINO"
    elif hora < 18:
        periodo = "VESPERTINO"
    else:
        periodo = "NOTURNO"
```

| Período | Faixa horária | Critério |
|---|---|---|
| `MATUTINO` | 00:00 – 11:59 | `hora < 12` |
| `VESPERTINO` | 12:00 – 17:59 | `12 <= hora < 18` |
| `NOTURNO` | 18:00 – 23:59 | `hora >= 18` |

- Usa **hora de início** do turno (não fim, nem predominância)
- Um turno que começa às 11:50 e vai até 20:00 é classificado como `MATUTINO`
- O campo só aparece em `snapshot_turnos[]` (não no `turnos[]` principal — turnos principais não têm `periodo`)

- **Impacto para o backend:** Se quiser recalcular, usar mesma lógica. Considere se faz sentido alterar para "hora predominante" no futuro.

---

### P1.7 — `ops.ids` e `ops.loja_ids` em `turno_closure` sem vendas

- **ID:** P1.7
- **Resposta curta:** ✅ **SIM, ambos são arrays vazios.**
- **Detalhe técnico:**

Em [payload.py:539-553](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L539-L553):

```python
ops_ids = ops_ids or []
loja_ids = loja_ids or []
# ...
has_sales = len(ops_ids) > 0 or len(loja_ids) > 0
has_closed_turno = any(t.fechado for t in turno_details if t.fechado)

if has_sales and has_closed_turno:
    event_type = "mixed"
elif has_closed_turno:
    event_type = "turno_closure"
else:
    event_type = "sales"
```

Em `turno_closure`: `has_sales = False`, logo `ops.ids = []`, `ops.loja_ids = []`, `ops.count = 0`.

**NÃO existe cenário** de `ops.count > 0` com `vendas = []`. Se `ops.count > 0`, haverá vendas e o `event_type` será `sales` ou `mixed`.

---

### P1.8 — Ordenação e replay

- **ID:** P1.8
- **Resposta curta:** Usar `window.from` / `window.to` para ordenação.
- **Detalhe técnico:**

As janelas são sequenciais via `state.py`:
```
Payload 1: window = [09:00, 09:10]
Payload 2: window = [09:10, 09:20]
Payload 3: window = [09:20, 09:30]
```

Em caso de replay de outbox, os payloads chegam fora de ordem no `received_at`, mas as janelas continuam corretas. O campo mais confiável para ordenação é:

1. **`window.from`** — determina de onde o payload cobre (melhor para ordenação lógica)
2. **`integrity.sync_id`** — contém timestamp de criação (UUID v4, sem garantia de ordem)
3. **`agent.sent_at`** — momento do envio original (não do replay)

- **Decisão final:** Ordenar por `window_from ASC`. Para replays, o `window_from` será anterior ao timestamp atual, o que é esperado.

---

### P1.9 — Vendedor nulo em item

- **ID:** P1.9
- **Resposta curta:** **Manter nulo.** Não atribuir ao operador.
- **Detalhe técnico:**

A query em [queries.py:477-482](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L477-L482):

```sql
it.id_usuario_vendedor,
uv.nome AS nome_vendedor
-- LEFT JOIN com usuario (permite null)
```

`id_usuario_vendedor` pode ser NULL quando:
- Item vendido sem vendedor associado (auto-atendimento)
- Item de taxa/serviço sem vendedor
- Configuração da loja não obriga vendedor por item

Atribuir ao operador do turno seria incorreto semanticamente — o operador (caixa) nem sempre é o vendedor. Em lojas com vários vendedores por turno, a atribuição seria arbitrária.

- **Decisão final:**
  - Em ranking: itens sem vendedor vão para categoria "Sem vendedor"
  - Em métricas: excluir de produtividade por vendedor
  - Em relatórios: exibir como "N/A"

---

### P1.10 — Troco em meios não-dinheiro e parcelas

- **ID:** P1.10
- **Resposta curta:** `troco` só faz sentido em dinheiro; `parcelas` tem default 1.
- **Detalhe técnico:**

**Troco:**
- Em HiperPdv: `ISNULL(fo.valor_troco, 0)` — [queries.py:519](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py#L519)
- Em Hiper Gestão: `ISNULL(ValorTroco, 0)` vem de `operacao_pdv.ValorTroco` (nível operação, não finalizador) — [queries_gestao.py:170](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L170)

O `troco` pode tecnicamente aparecer em qualquer registro de pagamento, mas na prática:
- Dinheiro: `troco > 0` é o caso normal
- Cartão/Pix: `troco = 0` sempre (nunca tem troco)
- ⚠️ Em Gestão, o `troco` é **por operação** (não por finalizador), então pode aparecer em TODOS os registros de pagamento da mesma venda. Backend deve somar troco apenas do primeiro registro ou deduplicar.

**Parcelas:**
- `fo.parcela` no SQL Server. Pode ser NULL para dinheiro/Pix.
- Backend já usa `max(1, (int) data_get(..., 'parcelas', 1))` — correto.
- Default oficial: `1` quando não informado.

| Meio | `troco` possível? | `parcelas` esperado |
|---|---|---|
| Dinheiro | ✅ Sim | 1 |
| Cartão Crédito | ❌ Sempre 0 | 1-12 |
| Cartão Débito | ❌ Sempre 0 | 1 |
| Pix | ❌ Sempre 0 | 1 |
| Cheque | ❌ Sempre 0 | 1 (geralmente) |
| Vale troca | ❌ Sempre 0 | 1 |

---

## Respostas P2 (Operação e Evolução)

---

### P2.1 — Envelopes de amostra oficiais

- **Resposta:** ✅ **SIM, compromisso de fornecer.**
- **Matriz de regressão:**

| # | Cenário | `event_type` | `canal` | Detalhe |
|---|---|---|---|---|
| 1 | Vendas só caixa | `sales` | Todos `HIPER_CAIXA` | 5 vendas, 15 itens, 5 pagamentos |
| 2 | Vendas só loja | `sales` | Todos `HIPER_LOJA` | 3 vendas Gestão |
| 3 | Mixed com colisão de `id_operacao` | `mixed` | Ambos | Mesmo `id_operacao` em canais diferentes |
| 4 | Turno closure sem vendas | `turno_closure` | N/A | `vendas=[]`, turno fechado |
| 5 | Replay com snapshots alterados | `sales` | Ambos | Snapshot com venda que mudou |

- **Prazo:** 48h após alinhamento desta doc.

---

### P2.2 — `corrections[]` no v3.1

- **Resposta:** Planejamos, mas formato ainda aberto.
- **Estrutura sugerida:**
```json
{
  "corrections": [
    {
      "type": "venda_cancelada",
      "canal": "HIPER_CAIXA",
      "id_operacao": 12380,
      "motivo": "cancelamento_pos_emissao",
      "data_correcao": "2026-02-12T15:30:00-03:00"
    }
  ]
}
```
- **Prazo:** Definição de contrato na v3.1 (estimativa: 4-6 semanas).

---

### P2.3 — SLA de comunicação

- **Resposta:** Mantemos aviso mínimo de **7 dias** para breaking changes.
- **Canal oficial:** PR no repositório do agente + doc versionada + notificação direta ao backend.
- **Para campos opcionais novos:** Sem aviso prévio (backward compat).

---

### P2.4 — Limites de volume e burst

- **Resposta:**
- **Por loja:** 1 payload a cada 10 minutos (intervalo padrão do scheduler)
- **Pico por payload:** ~50 vendas, ~200 itens, ~50 pagamentos, ~100 KB JSON
- **Burst:** Se loja ficou offline 2 horas → 1 payload grande cobrindo 2 horas de janela (não N payloads pequenos)
- **Rate limit do backend:** `pdv.rate_limit_per_minute = 180` está adequado (muito acima do necessário)

---

### P2.5 — Backlog em janela única ou múltiplas

- **Resposta:** **Janela única.**
- **Detalhe:** O agente calcula `dt_from = last_sync_to` (salvo em `state.json`) e `dt_to = now()`. Se a loja ficou offline 6 horas, o payload cobrirá 6 horas de vendas em uma única janela.
- **Não existe** divisão automática em sub-janelas.
- **Impacto:** O backend pode receber payloads com dezenas/centenas de vendas se houve backlog longo. O timeout do worker (`pdv.worker_timeout_seconds = 180`) deve ser suficiente, mas considere aumentar para 300s em cenários extremos.

---

## Respostas P3 (Dicas e Boas Práticas)

---

### P3.1 — Checks de consistência recomendados

1. **Soma dos itens ≈ total da venda:** `SUM(itens[].total)` deve ser ≈ `venda.total` (diferença pode existir por arredondamento, mas > 1% é suspeito)
2. **Soma dos pagamentos ≥ total da venda:** Pagamentos incluem troco, então soma pode ser > total
3. **ops.count = len(vendas):** Se divergir, alguma venda foi filtrada ou adicionada
4. **Turno referenciado por venda existe no payload ou no histórico:** Se `venda.id_turno` não aparece em `turnos[]` nem no banco, flag
5. **Snapshot turnos qtd_vendas > 0 quando total_vendas > 0:** Inconsistência se houver total sem vendas

---

### P3.2 — Dicionário oficial de meios de pagamento

- **Resposta:** O dicionário vem da tabela `finalizador_pdv` no Hiper. Os IDs **são universais** (confirmado em [queries_gestao.py:10](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L10)).

Dicionário padrão Hiper (configuração de fábrica):

| `id_finalizador` | Nome Hiper | Categoria sugerida |
|---|---|---|
| 1 | Dinheiro | `DINHEIRO` |
| 2 | Cheque | `CHEQUE` |
| 3 | Cartão Débito | `DEBITO` |
| 4 | Cartão Crédito | `CREDITO` |
| 5 | Pix | `PIX` |
| 6 | Vale Troca | `VALE` |
| 7+ | Customizado pela loja | `OUTROS` |

> [!WARNING]
> Lojas podem customizar nomes e adicionar finalizadores. Recomendamos **auto-cadastro via UPSERT** em `pdv_meios_pagamento` usando `(id_finalizador, nome)` como chave, com categoria inferida por pattern matching do nome.

---

### P3.3 — Sinais operacionais mais críticos

Recomendamos monitorar (em ordem de criticidade):

1. 🔴 **Ausência de sync por loja > 30 min** — Indica loja offline ou agente parado
2. 🔴 **`risk_flags` contém `store_mapping_missing`** — Loja não mapeada, dados vão para limbo
3. 🟡 **`integrity.warnings[]` não vazio** — O agente detectou algo anormal
4. 🟡 **Queda brusca de `ops.count`** — Indica possível problema no caixa
5. 🟡 **Mudança de proporção caixa/loja** — Se `ops.loja_count` sobe e `ops.count` cai, pode indicar migração não planejada
6. 🟢 **Snapshot turno sem vendas com `fechado=true`** — Normal em turnos de teste/administrativos

O backend já tem `PdvOpsMonitorCommand` e `PdvInfraCheckCommand` — excelente base. Recomendamos adicionar:
- Alerta por ausência de sync por loja (cron que verifica `MAX(received_at)` por `store_pdv_id`)
- Dashboard de proporção caixa vs loja ao longo do tempo

---

### P3.4 — Snapshot vs evento: quem prevalece?

- **Resposta:** ✅ **Snapshot SEMPRE prevalece**, sem exceção formal.
- **Raciocínio:** Os snapshots são recalculados a cada execução do agente diretamente a partir do banco de dados de origem. Se houver divergência, o snapshot reflete o **estado mais recente e correto** do Hiper.
- **Exceção possível:** Se o snapshot estiver cobrindo um período anterior ao do evento e a venda foi modificada entre os dois momentos. Nesse caso, o snapshot está mais atualizado.
- **Regra única:** `UPSERT cego com dados do snapshot, sem condificional.`

---

## Resumo de Ações Necessárias

### Agente (Time Integração)
| # | Ação | Prioridade | Prazo |
|---|---|---|---|
| 1 | Fix header `X-PDV-Schema-Version` em `sender.py` | 🔴 P0 | Imediato |
| 2 | Adicionar tiebreaker em `responsavel` query | 🟡 P1 | v3.1 |
| 3 | Fornecer payloads de regressão anonimizados | 🟡 P1 | 48h |

### Backend (Time API)
| # | Ação | Prioridade | Prazo |
|---|---|---|---|
| 1 | Adicionar `canal` em `pdv_vendas`, `pdv_venda_itens`, `pdv_venda_pagamentos` | 🔴 P0 | Sprint atual |
| 2 | Alterar unique constraints para incluir `canal` | 🔴 P0 | Sprint atual |
| 3 | Incluir `'3.0'` em `pdv.supported_schema_versions` | 🔴 P0 | Imediato |
| 4 | Atualizar `ProcessPdvSyncJob` para extrair/persistir `canal` | 🔴 P0 | Sprint atual |
| 5 | Aceitar `falta_caixa.total` negativo (sobra) | 🟡 P1 | Próximo sprint |
| 6 | Considerar `last_seen_in_snapshot_at` para detecção de cancelamento | 🟢 P2 | Futuro |
