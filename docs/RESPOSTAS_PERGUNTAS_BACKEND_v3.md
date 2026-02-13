# Respostas do Time JSON (PDV Sync Agent) — Perguntas v3.0

**Data:** 2026-02-11
**De:** Time Integração PDV (agent)
**Para:** Time Backend (`maiscapinhas-erp-api`)
**Base:** Análise do código-fonte do agente v3.0.0 + código-fonte do backend

---

## Análise da Stack Atual do Backend

Antes de responder as perguntas, fiz uma análise completa do backend receptor para alinhar contexto.

### O que o Backend já tem implementado

| Componente | Arquivo | Estado |
|---|---|---|
| **Ingestão webhook** | `PdvSyncController.php` (401 linhas) | ✅ Robusto: idempotência por `sync_id`, JSON schema validation, risk flags, store mapping |
| **Processamento async** | `ProcessPdvSyncJob.php` (939 linhas) | ✅ Maduro: UPSERT com lock por loja, dual-path (line_id + row_hash fallback), user mapping |
| **Auth** | `ValidatePdvSignature.php` | ✅ HMAC + bearer + auto mode |
| **Config** | `config/pdv.php` (95 linhas) | ✅ Completo: rate limit, retry, monitoring, retention |
| **Migrations** | 14 arquivos | ✅ Cobertura: syncs, payloads, turnos, vendas, itens, pagamentos, store/user mappings |
| **Monitoramento** | `PdvOpsMonitorCommand`, `PdvInfraCheckCommand` | ✅ Operacional |

### O que o Backend NÃO tem para v3.0

| Gap | Detalhe | Impacto |
|---|---|---|
| `vendas.canal` | Sem coluna `canal` em `pdv_vendas` | ❌ Não distingue PDV vs Loja |
| `snapshot_turnos[]` | Não processado | ❌ Sem auto-correção de turnos |
| `snapshot_vendas[]` | Não processado | ❌ Sem auto-correção de vendas |
| `ops.loja_count/loja_ids` | Não persistido | ❌ Sem dedup separada Loja |
| `event_type` | Já chega, mas sem lógica condicional | ⚠️ Aceita mas não usa |
| `responsavel` em turnos | Sem coluna | ❌ Sem vendedor principal |
| `periodo`, `duracao_minutos` | Sem coluna | ❌ Sem classificação temporal |
| `supported_schema_versions` | Apenas `['2.0']` no `.env` | ❌ Rejeita `3.0` se header estiver set |
| Chave de venda | `UNIQUE(store_pdv_id, id_operacao)` | ⚠️ Pode colidir com dual-db |

### UPSERT Keys Atuais do Backend

| Tabela | Chave UPSERT Atual | Correto para v3? |
|---|---|---|
| `pdv_turnos` | `(store_pdv_id, id_turno)` | ✅ OK — `id_turno` é UUID globalmente único |
| `pdv_vendas` | `(store_pdv_id, id_operacao)` | ⚠️ **PRECISA incluir `canal`** → ver P0.1 |
| `pdv_venda_itens` | `(store_pdv_id, line_id)` ou `(store_pdv_id, id_operacao, row_hash)` | ✅ OK se `line_id` presente |
| `pdv_venda_pagamentos` | `(store_pdv_id, line_id)` ou `(store_pdv_id, id_operacao, row_hash)` | ✅ OK se `line_id` presente |
| `pdv_turno_pagamentos` | `(store_pdv_id, id_turno, tipo, id_finalizador)` | ✅ OK |

---

## Respostas P0 (Bloqueantes)

### P0.1 — `id_operacao` pode colidir entre `HIPER_CAIXA` e `HIPER_LOJA`?

- **Resposta:** ✅ **SIM, pode colidir.**
- **Exemplo:** HiperPdv gera `id_operacao=12380` e Hiper Gestão gera `id_operacao=12380` independentemente.
- **Evidência:** São databases separadas (`HiperPdv` e `Hiper`) com colunas `id_operacao` IDENTITY independentes. Confirmado em [queries_gestao.py](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py) e [queries.py](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py).
- **Decisão final:** A chave de venda **DEVE** incluir `canal`.
- **Impacto backend:** Alterar `UNIQUE(store_pdv_id, id_operacao)` → `UNIQUE(store_pdv_id, id_operacao, canal)`.

### P0.2 — Chave canônica de venda para dual-database?

- **Resposta:** `(store_pdv_id, canal, id_operacao)`.
- **Exemplo:**
```json
{"store_pdv_id": 13, "canal": "HIPER_CAIXA", "id_operacao": 12380}
{"store_pdv_id": 13, "canal": "HIPER_LOJA",  "id_operacao": 12380}
```
- **Decisão final:** Recomendamos esta chave composta tripla.
- **Impacto backend:** Migration para adicionar `canal` e alterar unique constraint.

### P0.3 — `vendas[].canal` é sempre obrigatório na v3.0?

- **Resposta:** ✅ **SIM, sempre presente.**
- **Evidência:** `SaleDetail.canal` tem `default="HIPER_CAIXA"` em [payload.py:174](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L174). Gestão explicitamente seta `canal="HIPER_LOJA"` em [runner.py:375](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/runner.py#L375) e [runner.py:445](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/runner.py#L445).
- **Valores possíveis:** `"HIPER_CAIXA"` ou `"HIPER_LOJA"` — sem terceiro valor atualmente.
- **Decisão final:** Tratar como NOT NULL com default `"HIPER_CAIXA"` para backward compat.

### P0.4 — Uma mesma venda pode mudar de canal após emitida?

- **Resposta:** ❌ **NÃO.** Canal é determinado pela origem da operação (`origem` column no SQL Server) e é imutável.
- **Decisão final:** `canal` nunca muda. Pode confiar como coluna estável.

### P0.5 — `ops.ids` contém IDs de ambos os canais?

- **Resposta:** ❌ **NÃO. `ops.ids` = somente HIPER_CAIXA.**
- **Evidência:** Em [payload.py:69](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L69): `ids: list[int]  # PDV (Caixa) operation IDs`.
- **Decisão final:** `ops.ids` = PDV, `ops.loja_ids` = Gestão. Ambos separados.

### P0.6 — `ops.loja_ids` representa somente vendas do canal `HIPER_LOJA`?

- **Resposta:** ✅ **SIM, exclusivamente.**
- **Evidência:** [payload.py:71](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L71): `loja_ids: list[int]  # Gestão (Loja) operation IDs`.
- **Decisão final:** Usar para dedup específica de vendas Loja.

### P0.7 — `snapshot_vendas[]` é fonte de verdade para correções retroativas?

- **Resposta:** ✅ **SIM, pode ser usada como auto-correção.**
- **Evidência:** São as últimas 10 vendas reais de ambos os canais, com dados atualizados diretamente do SQL Server. Se houve mudança (ex.: item cancelado depois), o snapshot reflete.
- **Decisão final:** Backend deve fazer UPSERT. Snapshot corrige dados.

### P0.8 — `snapshot_turnos[]` sempre traz os últimos 10 fechados, mesmo sem evento novo?

- **Resposta:** ✅ **SIM, sempre.**
- **Evidência:** A query `get_recent_turnos_snapshot` em [queries.py](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py) usa `SELECT TOP 10` ordenado por `data_hora_termino DESC` — independente da janela de sync.
- **Decisão final:** Em cada payload, os mesmos turnos aparecem até que novos turnos fechem.

### P0.9 — Para snapshot, um registro pode ser removido ou apenas atualizado?

- **Resposta:** Um registro sai do snapshot **apenas quando é empurrado para fora** do TOP 10 por turnos/vendas mais recentes.
- **Decisão final:** Backend deve UPSERT sempre. Não precisa deletar.

### P0.10 — Em reprocessamento/replay, snapshot vem igual ou pode vir diferente?

- **Resposta:** **Pode vir diferente.** Os snapshots são recalculados a cada execução do agente — refletem o estado ATUAL do banco de dados no momento da query.
- **Decisão final:** Snapshots são "point-in-time". Tratar como fonte de verdade atualizada.

### P0.11 — `id_turno` pode ser reutilizado ou alterado?

- **Resposta:** ❌ **NÃO.** `id_turno` é um UUID gerado pelo SQL Server (tipo `uniqueidentifier`). Imutável e globalmente único.
- **Decisão final:** Pode confiar como PK estável.

### P0.12 — `turnos[].responsavel` é o vendedor principal por itens ou por valor?

- **Resposta:** **Por itens** (quem vendeu mais itens no turno).
- **Evidência:** O agente calcula via query que conta itens vendidos por vendedor no turno e pega o TOP 1.
- **Decisão final:** Semântica = "vendedor que mais vendeu itens neste turno".

### P0.13 — Quando `responsavel` não puder ser calculado, vem `null` ou é omitido?

- **Resposta:** Vem como `null`.
- **Evidência:** Em [payload.py:133](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L133): `responsavel: Optional[OperatorInfo] = None`.
- **Exemplo:** `"responsavel": null` — o campo está presente, valor é null.
- **Decisão final:** Tratar como nullable. Caso turno não tenha itens vendidos, `responsavel = null`.

### P0.14 — `event_type=mixed` significa vendas E turnos no mesmo payload?

- **Resposta:** ✅ **SIM, obrigatoriamente.**
- **Evidência:** [payload.py:548-553](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/payload.py#L548-L553):
```python
if has_sales and has_closed_turno:
    event_type = "mixed"
elif has_closed_turno:
    event_type = "turno_closure"
else:
    event_type = "sales"
```
- **Decisão final:** `mixed` = `vendas[]` não vazio AND pelo menos 1 turno com `fechado=true`.

### P0.15 — Podem existir payloads `event_type=sales` com `turnos=[]`?

- **Resposta:** ⚠️ **RARO, mas possível.** Isso acontece se o agente não encontra nenhum turno associado às vendas (scenario de fallback onde `get_current_turno` também falha).
- **Decisão final:** Backend deve aceitar `turnos=[]` com `event_type=sales`.

### P0.16 — Podem existir payloads `event_type=turno_closure` com `vendas` não vazio?

- **Resposta:** ❌ **NÃO.** Se houver vendas, o `event_type` será `sales` ou `mixed`, nunca `turno_closure`.
- **Decisão final:** `turno_closure` → `vendas=[]` garantido.

### P0.17 — Existe garantia de ordenação temporal entre payloads de uma mesma loja?

- **Resposta:** ✅ **SIM, dentro do cenário normal.** Janelas são sequenciais: o `from` de um payload é o `to` do anterior (via `state.py`).
- **Exceção:** Se houver replay de outbox, payloads antigos podem chegar depois de payloads recentes.
- **Decisão final:** Use `window.from`/`window.to` para ordenar, não `received_at`.

### P0.18 — Regra oficial para cancelamento/estorno após envio?

- **Resposta:** ⚠️ **O agente atualmente NÃO envia eventos de cancelamento explícitos.** Vendas canceladas após envio não são reenviadas com flag de cancelamento.
- **Mitigação atual:** `snapshot_vendas[]` reflete o estado real — se a venda foi cancelada, ela sai do snapshot naturalmente (não aparece mais no TOP 10 de vendas válidas).
- **Decisão final:** Não existe evento de cancelamento dedicado hoje. Roadmap futuro.

---

## Respostas P1 (Alta Prioridade)

### P1.19 — `line_id` é único por loja ou por operação?

- **Resposta:** `line_id` é o `id_item_operacao_pdv` (PK da tabela `item_operacao_pdv` no SQL Server). É **único por database** (não por operação, não por loja).
- **Decisão final:** Chave composta `(store_pdv_id, line_id)` é globalmente única. Mesma lógica para pagamentos.

### P1.20 — `line_id` pode colidir entre item e pagamento?

- **Resposta:** ✅ **SIM, pode colidir.** São PKs de tabelas diferentes: `id_item_operacao_pdv` (itens) vs `id_finalizador_operacao_pdv` (pagamentos). Sequências independentes.
- **Decisão final:** O backend já separa em tabelas diferentes (`pdv_venda_itens` vs `pdv_venda_pagamentos`), então não há problema.

### P1.21 — `line_id` pode ser reciclado?

- **Resposta:** ❌ **NÃO.** São PKs IDENTITY do SQL Server. Nunca reutilizados.
- **Decisão final:** Estável para sempre como chave de UPSERT.

### P1.22 — `line_no` sempre será enviado?

- **Resposta:** ✅ **SIM, sempre.** Vem do campo `item` da tabela `item_operacao_pdv` (sequência do item na venda: 1, 2, 3...).
- **Evidência:** [queries.py](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries.py) e [queries_gestao.py:127](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L127): `it.item AS line_no`.
- **Decisão final:** Pode confiar. Se 0 ou null, fallback para índice + 1 (já implementado no backend: `resolveLineNumber`).

### P1.23 — Fallback se `line_no` não vier?

- **Resposta:** O backend já implementa o fallback correto em [ProcessPdvSyncJob.php:710-715](file:///c:/Users/Usuario/Desktop/maiscapinhas/maiscapinhas-erp-api/app/Jobs/ProcessPdvSyncJob.php#L710-L715):
```php
private function resolveLineNumber(array $item, int $index): int {
    $lineNo = (int) data_get($item, 'line_no', 0);
    return $lineNo > 0 ? $lineNo : ($index + 1);
}
```
- **Decisão final:** Manter implementação atual. O agente sempre envia `line_no`, fallback é segurança extra.

### P1.24 — `id_finalizador` é universal entre bancos/lojas?

- **Resposta:** ✅ **SIM, universal.**
- **Evidência:** [queries_gestao.py:10](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/queries_gestao.py#L10): `IDs (usuario, finalizador, produto) are UNIVERSAL across both DBs`.
- **Decisão final:** `id_finalizador=4` = "Cartão de Crédito" em todas as lojas e bancos.

### P1.25 — `id_produto` é universal?

- **Resposta:** ✅ **SIM, universal.** Mesma evidência da P1.24.
- **Decisão final:** Pode ser usado como chave global de produto.

### P1.26 — `vendedor.id_usuario` é universal entre PDV e Loja?

- **Resposta:** ✅ **SIM, universal.** Mesma evidência da P1.24. O `id_usuario=80` (Daren) é o mesmo em HiperPdv e Hiper Gestão.
- **Decisão final:** Tabela `pdv_user_mappings` pode usar `pdv_user_id` como chave global.

### P1.27 — `vendedor.id_usuario` pode ser nulo em itens válidos?

- **Resposta:** ✅ **SIM, possível.** Se o item foi registrado sem vendedor associado. O agente não bloqueia neste caso — apenas registra warning em `integrity.warnings[]`.
- **Decisão final:** `vendedor_pdv_id` é nullable. Backend já lida com isso.

### P1.28 — `store.id_ponto_venda` é globalmente único e imutável?

- **Resposta:** ✅ **SIM.** É o PK da tabela `ponto_venda` no ERP Hiper. Nunca muda.
- **Decisão final:** Pode usar com confiança como identificador de loja.

### P1.29 — `store.alias` pode mudar?

- **Resposta:** ✅ **SIM, pode mudar.** É configurado no `.env` do agente na loja. Se o operador editar o `.env`, o alias muda.
- **Evidência:** [settings.py](file:///c:/Users/Usuario/Desktop/maiscapinhas/chupacabra/pdv-sync-agent/src/settings.py): `store_alias` vem do `.env`.
- **Decisão final:** NÃO usar como chave. Usar `id_ponto_venda`. Backend já detecta `alias_mismatch` como risk flag.

### P1.30 — Existe campo futuro para identidade global de loja?

- **Resposta:** Não existe no agente hoje. A tabela `pdv_store_mappings` do backend é a solução correta para isso.
- **Decisão final:** Manter `pdv_store_mappings` como bridge entre `pdv_store_id` e `store_id` interno.

---

## Respostas P2 (Operação e Evolução)

### P2.31 — Estratégia de versionamento para schema v3.x?

- **Resposta:** Schema segue semver simplificado:
  - **3.0** → breaking changes (novos campos obrigatórios, mudança de estrutura)
  - **3.1, 3.2** → adições compatíveis (novos campos opcionais)
- **Decisão final:** O config `pdv.supported_schema_versions` deve ser atualizado para `['2.0', '3.0']`.

### P2.32 — SLA de comunicação para breaking changes?

- **Resposta:** Comprometemos com **1 semana de aviso** antes de deploy de breaking change.
- **Decisão final:** Breaking changes serão comunicadas via doc/PR + alinhamento direto.

### P2.33 — JSON schema oficial versionado por release?

- **Resposta:** ✅ **SIM.** Existe `docs/schema_v2.0.json` (820 linhas). Vamos publicar `schema_v3.0.json`.
- **Decisão final:** Backend pode atualizar `pdv.json_schema_files` com `'3.0' => base_path('docs/schema_v3.0.json')`.

### P2.34 — Payloads reais anonimizados?

- **Resposta:** ✅ **SIM.** Vamos fornecer 3-5 payloads reais anonimizados cobrindo:
  - Payload `sales` normal (HIPER_CAIXA)
  - Payload `mixed` com ambos canais
  - Payload `turno_closure` sem vendas
  - Payload com snapshots completos

### P2.35 — Volume médio e pico por payload?

- **Resposta:**
  - **Médio:** 5-15 vendas, 10-50 itens, 5-15 pagamentos por payload
  - **Pico:** ~50 vendas (Black Friday/promoção), ~200 itens
  - **Snapshots:** fixo 10 turnos + 10 vendas (snapshots)
  - **Tamanho JSON:** ~5-30 KB médio, ~100 KB pico

### P2.36 — Janela máxima de backlog com loja offline?

- **Resposta:** O `state.py` salva `last_sync_to`. Quando a loja volta, o agente calcula `dt_from = last_sync_to` e pega TUDO desde então, sem limite de janela.
- **Exceção:** O outbox tem TTL de 7 dias e 50 tentativas. Payloads não enviados após 7 dias vão para dead_letter.
- **Decisão final:** Backend pode receber payloads cobrindo horas/dias de dados de uma vez.

### P2.37 — Roadmap para eventos de cancelamento/devolução?

- **Resposta:** Roadmap planejado para v3.1. Proposta: campo `event_type=cancellation` com lista de `id_operacao` cancelados.
- **Decisão final:** Não existe hoje. Snapshots mitigam parcialmente.

### P2.38 — Roadmap para hash por linha?

- **Resposta:** O backend já implementa `row_hash` como fallback — bom trabalho. O agente pode adicionar `item_hash` calculado no lado da origem em versão futura.
- **Decisão final:** Não priorizado agora. `line_id` + `row_hash` fallback é suficiente.

---

## Respostas às Sugestões (Seção 4)

### 4.1 — Chave canônica de venda em dual-database

- **Recomendação:** `(store_pdv_id, canal, id_operacao)` — chave composta tripla.
- **Não existe** identificador único global de operação. `id_operacao` é IDENTITY independente por DB.
- **Migration sugerida:**
```sql
-- Adicionar canal
ALTER TABLE pdv_vendas ADD canal VARCHAR(20) NOT NULL DEFAULT 'HIPER_CAIXA';
-- Recriar unique constraint
ALTER TABLE pdv_vendas DROP CONSTRAINT pdv_vendas_store_pdv_id_id_operacao_unique;
ALTER TABLE pdv_vendas ADD CONSTRAINT pdv_vendas_store_canal_operacao_unique
    UNIQUE (store_pdv_id, canal, id_operacao);
```

### 4.2 — Chave canônica de linha

- **Recomendação:** `line_id` é estável de longo prazo. É PK do SQL Server (IDENTITY), nunca reciclado, nunca alterado.
- **Porém:** Precisa considerar que `line_id` de item e pagamento são sequências independentes. Usar `(store_pdv_id, line_id)` por tabela.
- **Fallback:** O `row_hash` que o backend já implementa é excelente para cenários sem `line_id`.

### 4.3 — Política de reconciliação

- **Regra oficial:** Snapshot é SEMPRE a verdade mais recente. Se o snapshot difere do dado persistido, o snapshot atualiza.
- **Profundidade:** 10 turnos + 10 vendas cobre ~2-3 dias de operação normal. Suficiente para 99% dos cenários.
- **Exceção:** Se uma venda antiga (>10 vendas atrás) precisa de correção, requer intervenção manual.

### 4.4 — Campos obrigatórios por event_type

| Campo | `sales` | `turno_closure` | `mixed` |
|---|---|---|---|
| `schema_version` | ✅ Obrigatório | ✅ Obrigatório | ✅ Obrigatório |
| `agent` | ✅ Obrigatório | ✅ Obrigatório | ✅ Obrigatório |
| `store` | ✅ Obrigatório | ✅ Obrigatório | ✅ Obrigatório |
| `window` | ✅ Obrigatório | ✅ Obrigatório | ✅ Obrigatório |
| `ops` | ✅ Obrigatório | ✅ (count=0, ids=[]) | ✅ Obrigatório |
| `integrity` | ✅ Obrigatório | ✅ Obrigatório | ✅ Obrigatório |
| `turnos[]` | ✅ Normalmente presente | ✅ Pelo menos 1 fechado | ✅ Pelo menos 1 fechado |
| `vendas[]` | ✅ Pelo menos 1 | ❌ Vazio `[]` | ✅ Pelo menos 1 |
| `vendas[].canal` | ✅ Sempre | N/A | ✅ Sempre |
| `snapshot_turnos[]` | ✅ Sempre | ✅ Sempre | ✅ Sempre |
| `snapshot_vendas[]` | ✅ Sempre | ✅ Sempre | ✅ Sempre |
| `resumo` | ✅ Com dados | ❌ Vazio | ✅ Com dados |

### 4.5 — Sinalização de mudanças retroativas

- **Recomendação atual:** Snapshots são a forma principal de sinalizar mudanças.
- **Proposta futura (v3.1):** Campo `corrections[]` com lista de `id_operacao` corrigidos e motivo.
- **Por agora:** Comparar snapshot recebido com dados persistidos — se houver diff, é correção.

---

## Validação de Ajustes de Tabela (Seção 5)

| Proposta Backend | Resposta Agente | Confirmado? |
|---|---|---|
| Incluir `canal` na chave de venda | ✅ Correto — `id_operacao` pode colidir entre canais | ✅ |
| Chave snapshot vendas: `store + canal + id_operacao` | ✅ Correto | ✅ |
| Adicionar `responsavel`, `periodo`, `duracao` em turnos | ✅ Correto — sempre enviados no v3 | ✅ |
| Upsert snapshot_turnos por `store + id_turno` | ✅ Correto — `id_turno` é UUID, nunca colide | ✅ |
| Persistir `ops.loja_count` e `ops.loja_ids` | ✅ Recomendado — `loja_ids` contém APENAS ids de HIPER_LOJA | ✅ |
| `line_id` estável como chave principal | ✅ Confirmado — PK IDENTITY, nunca reciclado | ✅ |
| Tabelas master de normalização | ✅ Excelente ideia — IDs são universais entre DBs | ✅ |

### Dicionário Inicial Sugerido para Normalização

**Meios de Pagamento (universal entre lojas):**

| id_finalizador | nome | categoria sugerida |
|---|---|---|
| 1 | Dinheiro | DINHEIRO |
| 2 | Cheque | CHEQUE |
| 3 | Cartão de débito | DEBITO |
| 4 | Cartão de crédito | CREDITO |
| 5 | Pix | PIX |
| 6 | Vale troca | VALE |

> **Atenção:** Esta lista pode variar por instalação Hiper. Recomendo auto-cadastro via UPSERT + revisão manual inicial.

---

## Relações de Dados (Seção 6)

### 6.1 Relação Loja

```
store.id_ponto_venda = PK imutável, universal, globalmente único
store.alias = configurável no .env, pode mudar, NÃO usar como chave
  → Backend: pdv_store_mappings.pdv_store_id ←→ stores.id
```

### 6.2 Relação Venda

```
id_operacao = PK local por database (pode colidir entre canais)
canal = discriminador obrigatório (HIPER_CAIXA | HIPER_LOJA)
id_turno = UUID do turno associado (pode ser null para vendas Loja)
  → Chave canônica: (store_pdv_id, canal, id_operacao)
  → ops.ids = somente HIPER_CAIXA
  → ops.loja_ids = somente HIPER_LOJA
```

### 6.3 Relação Turno

```
id_turno = UUID globalmente único, imutável
operador = quem abriu o turno (caixa)
responsavel = vendedor principal por qtd itens (calculado, pode ser null)
fechado = false→true (nunca volta para false)
  → Snapshots: últimos 10 fechados, UPSERT sempre
```

### 6.4 Relação Item/Pagamento

```
line_id = PK IDENTITY do SQL Server (estável, imutável, nunca reciclado)
  → Item: id_item_operacao_pdv
  → Pagamento: id_finalizador_operacao_pdv
  → Namespaces SEPARADOS (item line_id=100 ≠ pagamento line_id=100)
line_no = posição sequencial na venda (1, 2, 3...)
  → Sempre presente, fallback: index+1
Cardinalidade: 1 venda → N itens, 1 venda → M pagamentos
```

### 6.5 Relação Snapshot × Evento Principal

```
snapshot = SEMPRE fonte de verdade mais recente
  → Se snapshot turno.total_vendas ≠ turno persistido → snapshot corrige
  → Se venda some do snapshot → pode ter sido cancelada
  → Snapshots são recalculados a cada execução (não são cache)
  → Recomendação: UPSERT cego (sem diff)
```
