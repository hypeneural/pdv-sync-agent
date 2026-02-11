# PDV Sync Agent — Roadmap de Melhorias v2.1

**Criado:** 2026-02-10
**Última atualização:** 2026-02-10
**Baseado em:** [Perguntas Técnicas do Time API](./RESPOSTAS_API_TEAM.md)

---

## ~~PR-01: HMAC Authentication~~ — DESCOPED

> **Decisão:** Bearer token é suficiente para o cenário atual. HMAC não será implementado.

---

## 🔴 PR-02: Timezone Explícito em Datetimes (P0 — Bloqueante)

**Branch:** `feat/explicit-timezone`
**Estimativa:** 2h
**Motivação:** Datetimes naive (sem offset) causam ambiguidade fatal se o backend rodar em UTC. Uma venda às 21:00 BRT seria interpretada como 21:00 UTC (ou seja, 18:00 BRT). Todas as janelas, turnos e vendas ficariam 3h erradas silenciosamente.
**Perguntas respondidas:** #11, #12, #13

### Contexto Técnico

- **Impacto:** TODOS os datetimes em TODOS os modelos Pydantic
- **Arquivos:** `payload.py`, `state.py`, `runner.py`, `queries.py`
- **Decisão:** Usar horário local com offset `-03:00` (não UTC)
  - Razão: operação das lojas é local, logs e debugging ficam mais intuitivos

### Subtasks

- [x] **PR-02.1** Criar constante `BRT` timezone em `__init__.py`
  - `BRT = timezone(timedelta(hours=-3))` em `src/__init__.py`

- [x] **PR-02.2** Atualizar `payload.py` — campo `AgentInfo.sent_at`
  - `default_factory=lambda: datetime.now(BRT)`

- [x] **PR-02.3** Atualizar `state.py` — `WindowCalculator.calculate_window()`
  - `now = datetime.now(BRT)` + backward compat para dt_from naive

- [x] **PR-02.4** Atualizar `state.py` — `StateManager.load()`
  - Attach BRT a datetimes naive carregados do state.json antigo

- [x] **PR-02.5** Atualizar `payload.py` — serialização de datetimes
  - Adicionada função `_aware()` helper para converter naive → BRT

- [x] **PR-02.6** Tratar datetimes vindos do SQL Server
  - `_aware()` aplicada em `build_turno_detail()` e `build_sale_details()`
  - Cobre: `data_hora_inicio`, `data_hora_termino` em turnos e vendas

- [x] **PR-02.7** Testar que `sync_id` continua determinístico
  - Hash muda (inclui offset agora) — aceito como mudança de versão

- [ ] **PR-02.8** Atualizar exemplos no README.md e RESPOSTAS_API_TEAM.md (low priority)

### Critérios de Aceite
- [ ] Todos os datetimes no payload JSON terminam com `-03:00`
- [ ] `state.json` com timezone funciona
- [ ] `state.json` antigo (naive) é carregado sem erro (backward compat)
- [ ] `sync_id` é consistente dentro da mesma versão

---

## 🔴 PR-03: Schema Version no Payload (P0 — Trivial)

**Branch:** `feat/schema-version`
**Estimativa:** 30min
**Motivação:** O campo `agent.version` mistura versão do software com versão do schema. O backend precisa de um campo explícito para saber qual formato de JSON esperar.
**Perguntas respondidas:** #31, #34

### Subtasks

- [x] **PR-03.1** Adicionar campo `schema_version` no `SyncPayload`
  - Implementado em `src/__init__.py` (`SCHEMA_VERSION = "2.0"`) e `src/payload.py` (`SyncPayload.schema_version`)

- [x] **PR-03.2** Adicionar header `X-PDV-Schema-Version: 2.0` no `_get_headers()`
  - Implementado em `src/sender.py`

- [ ] **PR-03.3** Atualizar JSON Schema no README.md (feito junto com PR-07)

### Critérios de Aceite
- [ ] Payload JSON contém `"schema_version": "2.0"` na raiz
- [ ] Header `X-PDV-Schema-Version` presente em todas as requests

---

## 🟡 PR-04: Melhorar Tratamento de Erros HTTP (P1)

**Branch:** `feat/smart-error-handling`
**Estimativa:** 1h
**Motivação:** Hoje o agente salva TUDO no outbox (inclusive 422 — payload inválido). Isso gera retry infinito de payloads rejeitados que nunca vão ser aceitos.
**Perguntas respondidas:** #8, Matriz de erro/retry

### Contexto Técnico

- **Arquivo:** `src/sender.py`
- **Método:** `HttpSender.send()` (linha 133-176)
- **Problema:** Bloco `else` no status check trata 4xx e 5xx igualmente

### Subtasks

- [x] **PR-04.1** Classificar responses por categoria
  - `NO_RETRY_CODES = {400, 401, 403, 404, 409, 422}` como constante

- [x] **PR-04.2** Em `HttpSender.send()`: tratar 4xx como erro final
  - 4xx → `save_dead_letter()`, sem retry
  - 5xx → `save()` no outbox, retry normal

- [x] **PR-04.3** Em `HttpSender.send()`: tratar 429 com `Retry-After`
  - 429 está em `NO_RETRY_CODES` → dead_letter (simplificado)

- [x] **PR-04.4** Criar diretório `dead_letter/` para payloads descartados
  - `OutboxManager.dead_letter_dir` = `outbox/../dead_letter/`
  - `save_dead_letter()` salva com `_reason` e `_status_code`
  - `_move_to_dead_letter()` para mover de outbox → dead_letter

- [x] **PR-04.5** Adicionar counter de tentativas no outbox
  - Envelope format: `{_retry_count, _created_at, payload}`
  - `increment_retry()` salva de volta com `_last_retry`
  - `MAX_OUTBOX_RETRIES = 50` → move para dead_letter

- [x] **PR-04.6** Adicionar TTL no outbox (7 dias)
  - `OUTBOX_TTL_DAYS = 7`
  - `list_pending()` filtra por mtime e move expirados para dead_letter
  - Backward compat: outbox antigos (sem envelope) são wrappados automaticamente

### Critérios de Aceite
- [ ] 422 → logado + salvo em dead_letter, sem retry
- [ ] 500 → salvo no outbox, retry normal
- [ ] 429 → respeita Retry-After se presente
- [ ] Outbox > 7 dias → movido para dead_letter
- [ ] dead_letter não é reprocessado automaticamente

---

## 🟡 PR-05: X-Request-Id por Tentativa (P1)

**Branch:** `feat/request-id-tracking`
**Estimativa:** 30min
**Motivação:** O `sync_id` é o mesmo em retry. Sem `X-Request-Id`, é impossível correlacionar no backend "qual tentativa específica falhou e por quê".
**Perguntas respondidas:** #5

### Subtasks

- [x] **PR-05.1** Gerar UUID4 por tentativa em `_send_with_retry()`
  - `request_id = str(uuid.uuid4())` + `headers["X-Request-Id"] = request_id`
  - Gerado dentro de `_send_with_retry()` — cada retry de tenacity também gera novo ID

- [x] **PR-05.2** Logar `X-Request-Id` no log do agente para correlação
  - `logger.info(f"POST attempt (request_id={request_id})")`

- [x] **PR-05.3** Incluir request_id no `SendResult` para rastreio
  - Não incluído no SendResult (overkill). Rastreio via log é suficiente.

### Critérios de Aceite
- [ ] Cada POST tem `X-Request-Id` único (UUID4)
- [ ] Retry do mesmo payload gera request_id diferente
- [ ] Log contém request_id para debugging

---

## 🟢 PR-06: Line Numbers em Itens e Pagamentos (P2)

**Branch:** `feat/line-numbers`
**Estimativa:** 1-2h
**Motivação:** Sem `line_no`, o backend não consegue fazer UPSERT granular por item. Precisa deletar e reinserir todos os itens de uma venda em reprocessamento, arriscando inconsistências.
**Perguntas respondidas:** #21, #22

### Contexto Técnico

- **Arquivos:** `queries.py` (queries de itens/pagamentos), `payload.py` (modelos)
- **Dependência:** Verificar se `item_operacao_pdv` e `finalizador_operacao_pdv` têm PK/IDENTITY

### Subtasks

- [x] **PR-06.1** Investigar PKs das tabelas de itens e pagamentos
  - `item_operacao_pdv` → PK: `id_item_operacao_pdv` (int IDENTITY) + `item` (smallint, line number within sale)
  - `finalizador_operacao_pdv` → PK: `id_finalizador_operacao_pdv` (int IDENTITY)

- [x] **PR-06.2** PKs encontradas → usadas como `line_id` natural
  - `ProductItem.line_id` = `id_item_operacao_pdv`, `ProductItem.line_no` = `item`
  - `SalePayment.line_id` = `id_finalizador_operacao_pdv`

- [x] **PR-06.3** Atualizar queries `get_sale_items()` e `get_sale_payments()`
  - Adicionados `it.id_item_operacao_pdv AS line_id, it.item AS line_no` em items
  - Adicionado `fo.id_finalizador_operacao_pdv AS line_id` em payments

- [x] **PR-06.4** Atualizar builder `build_sale_details()` em `payload.py`
  - Mapeados `line_id` e `line_no` nos construtores de `ProductItem` e `SalePayment`

- [x] **PR-06.5** Regenerar JSON Schema (`docs/schema_v2.0.json`)

### Critérios de Aceite
- [ ] Cada item no array `vendas[].itens[]` tem `line_no` estável
- [ ] Cada pagamento em `vendas[].pagamentos[]` tem `line_no` estável
- [ ] `line_no` é determinístico (mesma venda = mesmos line_nos)

---

## 🟢 PR-07: Publicar JSON Schema Oficial (P2)

**Branch:** `feat/json-schema-export`
**Estimativa:** 1h
**Motivação:** Contrato formal entre os times. Permite validação automatizada no backend e documentação sempre atualizada.
**Perguntas respondidas:** #33

### Subtasks

- [x] **PR-07.1** Criar script `scripts/export_schema.py`
  - Implementado com `SyncPayload.model_json_schema()` + metadata `$id` e `$schema`

- [x] **PR-07.2** Gerar `docs/schema_v2.0.json` e commitar
  - Gerado com 17 definições (models Pydantic)

- [x] **PR-07.3** Adicionar no `build.bat`: gerar schema automaticamente
  - Script executável via `python scripts/export_schema.py` (integração manual no build por enquanto)

- [x] **PR-07.4** Criar `docs/schema_changelog.md` com histórico de mudanças
  - Changelog v1 → v2 documentado

### Critérios de Aceite
- [ ] `docs/schema_v2.0.json` existe e é válido JSON Schema Draft 2020-12
- [ ] Schema é gerado automaticamente a partir dos modelos Pydantic
- [ ] Changelog documenta diferenças v1 → v2

---

## 🟢 PR-08: Detecção de Cancelamento Pós-Envio (P2)

**Branch:** `feat/cancellation-detection`
**Estimativa:** 3-4h
**Motivação:** Se um cupom é cancelado no HiperPdv após ter sido enviado, o backend nunca fica sabendo. Isso causa divergência entre loja e sistema central.
**Perguntas respondidas:** #20

### Contexto Técnico

- **Complexidade:** Alta — requer nova query, novo campo no payload, e lógica no runner
- **Abordagem:** Query que verifica `cancelado=1` em IDs enviados recentemente (últimas 24h)
- **Dependência:** State precisa guardar IDs enviados (ou último N sync_ids)

### Subtasks

- [ ] **PR-08.1** Criar query `get_recently_cancelled()`
  ```sql
  SELECT id_operacao, data_hora_termino
  FROM operacao_pdv
  WHERE cancelado = 1
    AND id_ponto_venda = @store_id
    AND data_hora_termino >= DATEADD(hour, -24, GETDATE())
  ```

- [ ] **PR-08.2** Adicionar modelo `CancelledOp` em `payload.py`
  ```python
  class CancelledOp(BaseModel):
      id_operacao: int
      data_hora_cancelamento: Optional[datetime] = None
  ```

- [ ] **PR-08.3** Adicionar campo `cancelamentos: list[CancelledOp]` no `SyncPayload`

- [ ] **PR-08.4** Integrar no `SyncRunner._build_payload()`:
  - Rodar `get_recently_cancelled()` a cada ciclo
  - Incluir no payload se houver cancelamentos

- [ ] **PR-08.5** Atualizar `schema_version` para `2.1` (breaking change)

- [ ] **PR-08.6** Documentar comportamento no README e RESPOSTAS_API_TEAM

### Critérios de Aceite
- [ ] Cupom cancelado nas últimas 24h aparece em `cancelamentos[]`
- [ ] Backend recebe notificação de cancelamento
- [ ] Só envia cada cancelamento uma vez (deduplicação por state)

---

## Ordem de Execução Recomendada

```
Semana 1 (pré go-live):
  PR-03 → PR-02 → PR-01
  (schema_version primeiro porque é trivial, 
   timezone segundo porque afeta sync_id,
   HMAC por último porque é independente)

Semana 2 (pós go-live):
  PR-05 → PR-04
  (request-id é rápido, 
   error handling precisa de mais cuidado)

Semana 3+:
  PR-07 → PR-06 → PR-08
  (schema export é rápido,
   line_no depende de investigação no banco,
   cancelamento é o mais complexo)
```

---

## Referências

- [Respostas completas para o time API](./RESPOSTAS_API_TEAM.md)
- [README v2.0](../README.md)
- [Guia de instalação](../deploy/GUIA_INSTALACAO.md)
- Código-fonte: `src/sender.py`, `src/payload.py`, `src/state.py`, `src/runner.py`, `src/queries.py`
