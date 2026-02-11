# Respostas Técnicas — PDV Sync Agent v2.0

**Data:** 2026-02-11
**Projeto:** `pdv-sync-agent` (lado Hiper/Loja)
**Para:** Time backend `maiscapinhas-erp-api` (lado Laravel)
**Escopo:** Responder as 40 perguntas técnicas + dúvidas adicionais com base no código-fonte em produção

---

## Análise da Estrutura Atual do Agente

### Stack do Agente (lado loja)

| Componente | Tecnologia |
|---|---|
| Linguagem | Python 3.12, compilado com PyInstaller |
| Modelos | Pydantic v2 (15 modelos) |
| HTTP | `requests` + `tenacity` (retry) |
| DB | `pyodbc` → ODBC Driver 17 → SQL Server 2014 |
| Execução | Windows Task Scheduler, roda como `NT AUTHORITY\SYSTEM` |
| Config | `.env` com `pydantic-settings` |
| Estado | `state.json` incremental (last_sync_to) |
| Offline | Outbox queue em disco (JSON files) |

### Fluxo por Ciclo (a cada 10 min)

```
1. Process outbox   → reenvia payloads que falharam
2. Calculate window → [last_sync_to, now()]
3. Query turnos     → turnos com vendas na janela + op=9 + op=4
4. Query vendas     → itens individuais + pagamentos por cupom
5. Query resumo     → agregado por vendedor + por meio
6. Build payload    → SyncPayload (Pydantic) → JSON
7. POST webhook     → 3 tentativas com backoff exponencial
8. Save state       → avança last_sync_to só se POST OK
```

### Arquivos-chave

| Arquivo | Responsabilidade | Linhas |
|---|---|---|
| `runner.py` | Orquestração do fluxo completo | 278 |
| `queries.py` | 12 queries SQL com CTEs | 483 |
| `payload.py` | 15 modelos Pydantic + builders | 494 |
| `sender.py` | HTTP POST + outbox + retry | 226 |
| `state.py` | state.json + cálculo de janela | 124 |
| `settings.py` | Config .env + ODBC detect | 215 |
| `db.py` | Conexão SQL Server + erros amigáveis | 177 |

---

## P0 — Respostas Bloqueantes

### 3.1 Segurança e Autenticação

#### Pergunta 1: HMAC `hash_hmac('sha256', timestamp + "." + rawBody, secret)`?

**Resposta:** ❌ O agente **NÃO implementa HMAC** atualmente. Usa apenas `Authorization: Bearer {token}` com token fixo do `.env`.

**Código atual (`sender.py:110-116`):**
```python
def _get_headers(self) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {self.token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
```

**Impacto:** Implementar HMAC é fácil — basta adicionar `X-PDV-Signature` e `X-PDV-Timestamp` nos headers. Estimativa: ~20 linhas de código, 1 hora de trabalho.

**Proposta de implementação:**
```python
import hmac, hashlib, time

timestamp = str(int(time.time()))
body_bytes = payload_json.encode('utf-8')
signature = hmac.new(secret.encode(), f"{timestamp}.{body_bytes}".encode(), hashlib.sha256).hexdigest()

headers["X-PDV-Signature"] = f"sha256={signature}"
headers["X-PDV-Timestamp"] = timestamp
```

#### Pergunta 2: Formato do `X-PDV-Signature`?

**Resposta:** Ainda não implementado. Sugerimos usar prefixo `sha256=` para facilitar versionamento futuro de algorítmo.

#### Pergunta 3: Rotação de segredo HMAC?

**Resposta:** O token/secret vive no `.env` de cada loja. Para rotacionar, basta:
1. Atualizar o `.env` em cada loja (pode ser via `update.bat`)
2. Reiniciar a task: `schtasks /end /tn PDVSyncAgent && schtasks /run /tn PDVSyncAgent`

**Tempo de troca:** ~5 minutos por loja com acesso remoto.

#### Pergunta 4: Tempo de troca em comprometimento?

**Resposta:** Depende do acesso remoto às lojas. Com AnyDesk/TeamViewer ativo: **~30 minutos para todas as 12 lojas** (2-3 min cada). Sem acesso remoto: depende de visita presencial.

#### Pergunta 5: `X-Request-Id` único por tentativa?

**Resposta:** ❌ **Não implementado.** O `sync_id` é determinístico por janela — se retransmitido do outbox, é o **mesmo** `sync_id`. Não há ID único por tentativa.

**Impacto:** Implementar é simples — gerar UUID4 por tentativa de POST. Estimativa: ~5 linhas.

---

### 3.2 Semântica de Idempotência e Retry

#### Pergunta 6: `sync_id` é determinístico?

**Resposta:** ✅ **Sim.** Calculado como SHA256 de `"{store_id}|{dt_from.isoformat()}|{dt_to.isoformat()}"`.

**Código (`payload.py:236-242`):**
```python
def generate_sync_id(store_id: int, dt_from: datetime, dt_to: datetime) -> str:
    data = f"{store_id}|{dt_from.isoformat()}|{dt_to.isoformat()}"
    return hashlib.sha256(data.encode()).hexdigest()
```

**Garantia:** Mesma loja + mesma janela = **mesmo sync_id**, sempre. Deterministicamente reproduzível.

#### Pergunta 7: Retry do outbox reenvia byte a byte igual?

**Resposta:** ⚠️ **Quase.** O payload é salvo em disco como JSON e relido do arquivo. O `sync_id` é **o mesmo**. Porém:
- `agent.sent_at` pode variar (é o timestamp do envio, não da geração)
- A serialização JSON pode ter variações menores de whitespace

**Na prática:** O backend deve dedupplicar por `sync_id`, não por corpo HTTP inteiro.

#### Pergunta 8: Política de retry do agente?

**Resposta:**

| Parâmetro | Valor | Código |
|---|---|---|
| Tentativas por envio | **3** | `stop_after_attempt(3)` |
| Backoff exponencial | **2s → 4s → 8s → max 30s** | `wait_exponential(multiplier=1, min=2, max=30)` |
| Retry em quais erros | `Timeout` + `ConnectionError` | Não faz retry em 4xx/5xx (salva no outbox) |
| TTL de outbox | **Sem TTL** — persiste até ser enviado | Arquivos em disco, sem limpeza automática |
| Processamento de outbox | A cada ciclo (10 min), **antes** de gerar novo payload | `process_outbox()` no início do `run()` |
| Ordem do outbox | **Cronológica** — archivos `.json` sorted por nome | Nome = `{timestamp}_{sync_id[:12]}.json` |

**Código (`sender.py:118-131`):**
```python
@retry(
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    retry=retry_if_exception_type((requests.Timeout, requests.ConnectionError)),
)
def _send_with_retry(self, payload_json: str) -> requests.Response:
    return requests.post(self.endpoint, data=payload_json, ...)
```

**Comportamento em falha de rede durante outbox:**
```python
except requests.RequestException as e:
    break  # Para de processar outbox se rede está fora
```

#### Pergunta 9: Reenvios fora de ordem?

**Resposta:** ⚠️ **Sim, pode ocorrer.** Cenário:

1. Janela 16:30 falha → salva no outbox como `20260210_163000_abc.json`
2. Janela 16:40 sucesso → enviada normalmente
3. Próximo ciclo: outbox reenvia 16:30

**O outbox é processado em ordem cronológica** (sorted por filename), mas se a rede voltar no meio, uma janela posterior pode ser enviada antes de uma anterior que está no outbox.

**Recomendação:** O backend deve aceitar janelas fora de ordem e usar `ops.ids[]` + `sync_id` para deduplicação, não depender de ordem.

#### Pergunta 10: Backlog máximo esperado?

**Resposta:** O outbox cresce **1 arquivo JSON a cada 10 minutos** (se houver vendas na janela). Em queda de rede:

| Tempo offline | Payloads acumulados | Tamanho estimado |
|---|---|---|
| 1 hora | ~6 | ~30 KB |
| 8 horas | ~48 | ~240 KB |
| 24 horas | ~144 | ~720 KB |
| 1 semana | ~1008 | ~5 MB |

> Cada payload tem em média 1-5 KB dependendo do volume de vendas. Sem limite de TTL — o outbox não expira.

---

### 3.3 Contrato de Tempo e Timezone

#### Pergunta 11: Datetimes com offset?

**Resposta:** ❌ **Sem timezone.** Todos os datetimes são **naive** (sem offset, sem `Z`). Formato: `2026-02-10T21:12:56.620869`.

**Razão:** O SQL Server local armazena datetimes sem timezone (tipo `datetime`), e o Python `datetime.now()` retorna naive.

#### Pergunta 12: Padronizar para ISO-8601 com timezone?

**Resposta:** ⚠️ **Possível mas requer ajuste.** Todas as lojas estão em Santa Catarina (UTC-3). Podemos:

**Opção A — Adicionar `-03:00` em todos os campos:**
```python
from datetime import timezone, timedelta
BRT = timezone(timedelta(hours=-3))
dt = datetime.now(BRT)  # 2026-02-10T21:12:56-03:00
```

**Opção B — Manter naive e documentar que é sempre America/Sao_Paulo.**

**Recomendação:** Opção A é mais robusta. Estimativa: ~2h de trabalho.

#### Pergunta 13: `agent.sent_at` é local ou UTC?

**Resposta:** É **horário local da loja** (`datetime.now()`). Atualmente sem timezone explícito.

**Código (`payload.py:36`):**
```python
sent_at: datetime = Field(default_factory=datetime.now)
```

#### Pergunta 14: NTP nas máquinas das lojas?

**Resposta:** ⚠️ **Sem garantia.** As máquinas usam o Windows Time Service padrão (`w32time`), que sincroniza com `time.windows.com` se tiver internet. O skew típico é **< 2 segundos** em operação normal.

Em caso de queda de internet prolongada, o clock pode driftar. Porém, o sync usa timestamps **do banco SQL Server** (que tem seu próprio clock), não do Python.

---

### 3.4 Integridade de Dados de Venda/Turno

#### Pergunta 15: `id_operacao` é imutável e único?

**Resposta:** ✅ **Sim.** É `int (PK)` autoincrement na tabela `operacao_pdv`. Único dentro do banco da loja. Globalmente único quando combinado com `store.id_ponto_venda`.

**Chave natural global:** `(id_ponto_venda, id_operacao)` — nunca se repete.

#### Pergunta 16: `id_turno` GUID é imutável?

**Resposta:** ✅ **Sim.** O `id_turno` é `uniqueidentifier` gerado pelo SQL Server. Nunca reutilizado. Ex: `6A91E9F2-FF8C-4E40-BA90-8BF04B889A57`.

#### Pergunta 17: `totais_sistema.total` é acumulado do turno completo?

**Resposta:** ⚠️ **Depende.** O `totais_sistema` é calculado pela **soma de todas as vendas (op=1) do turno**, não só da janela de 10 min.

**Query (`queries.py:448-477`):**
```sql
-- get_payments_by_method_for_turno
SELECT f.id_finalizador, fp.nome, SUM(ISNULL(f.valor,0)), COUNT(DISTINCT o.id_operacao)
FROM operacao_pdv o
JOIN finalizador_operacao_pdv f ON f.id_operacao = o.id_operacao
WHERE o.id_turno = @id_turno
  AND o.operacao = 1 AND o.cancelado = 0
GROUP BY f.id_finalizador, fp.nome
```

**Ou seja:** Cada vez que o payload é enviado, o `totais_sistema` reflete o **acumulado do turno inteiro até aquele momento** — não apenas os 10 min da janela. Isso permite que o backend sempre tenha a visão mais atualizada do turno.

#### Pergunta 18: `falta_caixa.total` = `totais_sistema - fechamento_declarado`?

**Resposta:** ⚠️ **Nem sempre exato.** Os valores de `falta_caixa` vêm da **operação 4** (registro do HiperPdv), que calcula a diferença internamente. Não é calculado pelo agente.

A relação esperada é:
```
falta_caixa ≈ totais_sistema - fechamento_declarado
```
Mas pode haver pequenas diferenças por arredondamento ou ajustes manuais no sistema Hiper.

#### Pergunta 19: Dados de turno fechado podem mudar?

**Resposta:** ⚠️ **Tecnicamente sim, mas raro.** No HiperPdv:
- Turno fechado (`fechado=true`) normalmente é imutável
- Porém, um gerente pode reabrir um turno e fazer ajustes
- Se isso acontecer, os dados mudam no banco mas o agente **não** reenvia dados de janelas passadas

**Recomendação:** O backend deve usar `UPSERT` por `id_turno` para permitir atualizações.

#### Pergunta 20: Cancelamento/estorno/devolução?

**Resposta:** No HiperPdv:
- **Cancelamento:** `operacao_pdv.cancelado = 1` — o agente **filtra essas** (`cancelado = 0`), então cupons cancelados **nunca aparecem** no payload
- **Item cancelado:** `item_operacao_pdv.cancelado = 1` — também filtrado
- **Estorno/devolução:** Gera uma **nova operação** com `operacao != 1` — o agente não coleta essas operações
- **Cancelamento após envio:** Se um cupom foi enviado e depois cancelado no banco, ele **não será corrigido** no payload posterior. O backend não receberá notificação do cancelamento.

**Impacto:**  Se quiserem rastrear cancelamentos pós-envio, precisaremos criar query específica.

---

## P1 — Alta Prioridade

### 4.1 Granularidade de Itens/Pagamentos

#### Pergunta 21: `line_no` estável em itens e pagamentos?

**Resposta:** ❌ **Não implementado.** Itens e pagamentos são arrays sem `line_no`. A ordem vem do `ORDER BY` da query SQL.

**Impacto:** Podemos adicionar facilmente:
- Itens: usar `ROW_NUMBER() OVER (PARTITION BY id_operacao ORDER BY id_item)` se existir `id_item`
- Pagamentos: idem com `id_finalizador_operacao`

**Estimativa:** ~1h se os PKs existirem nas tabelas do Hiper.

#### Pergunta 22: Chave natural para evitar duplicação?

**Resposta:** Para itens, a combinação `(id_operacao, id_produto, id_usuario_vendedor)` é **quase única** mas não garantida (mesmo produto pode aparecer 2x no mesmo cupom com vendedores diferentes).

**Melhor opção:** Se a tabela `item_operacao_pdv` tem PK composta ou `IDENTITY`, podemos expor como `line_id`.

#### Pergunta 23: Item pode trocar de vendedor após venda?

**Resposta:** ❌ **Não.** Uma vez registrado, `id_usuario_vendedor` no item é imutável.

#### Pergunta 24: `parcelas` pode vir null?

**Resposta:** ✅ **Sim.** Se a coluna `parcelas` não existir na tabela do Hiper ou se o pagamento for dinheiro, `parcelas` será `null`.

**Default sugerido:** Tratar `null` como `1` (pagamento à vista).

#### Pergunta 25: `valor` no pagamento dinheiro é bruto ou líquido?

**Resposta:** É o **valor bruto recebido** (antes do troco). O troco vem separado no campo `troco`.

**Exemplo:**
```json
{ "meio": "Dinheiro", "valor": 100.00, "troco": 10.10 }
// Valor líquido da venda: 100.00 - 10.10 = 89.90
```

### 4.2 Qualidade e Consistência Funcional

#### Pergunta 26: `resumo.by_vendor` é por item-vendedor ou cupom-vendedor?

**Resposta:** É por **item-vendedor**. A query agrupa pela tabela `item_operacao_pdv.id_usuario_vendedor`:

```sql
-- queries.py get_sales_by_vendor
SELECT u.id_usuario, u.nome,
       COUNT(DISTINCT ops.id_operacao) AS qtd_cupons,
       SUM(ISNULL(it.valor_total_liquido, 0)) AS total_vendido
FROM ops
JOIN item_operacao_pdv it ON it.id_operacao = ops.id_operacao AND it.cancelado = 0
LEFT JOIN usuario u ON u.id_usuario = it.id_usuario_vendedor
GROUP BY u.id_usuario, u.nome
```

**Nota:** Se um cupom tem itens de 2 vendedores diferentes, o cupom é contado para ambos via `COUNT(DISTINCT id_operacao)`.

#### Pergunta 27: Vendedor null em item?

**Resposta:** ✅ **Pode acontecer.** Se `id_usuario_vendedor` for `NULL`, o vendedor aparece como `{"id_usuario": null, "nome": null}`.

O agente gera **warning** para isso:
```python
# runner.py _check_warnings
for vendor in sales_by_vendor:
    if vendor.get("id_usuario") is None:
        warnings.append("Vendedor com id_usuario=NULL encontrado")
```

**Aparece em:** `integrity.warnings[]` no payload.

#### Pergunta 28: `id_finalizador` tem dicionário estável entre lojas?

**Resposta:** ⚠️ **Não garantido.** O `id_finalizador` é definido na tabela `finalizador_pdv` de cada loja. O dicionário **pode variar** entre lojas se configuradas separadamente.

**Na prática (MaisCapinhas):** Como todas as lojas usam a mesma configuração Hiper, os `id_finalizador` **tendem a ser iguais**. Mas não há garantia formal.

**Recomendação:** O backend deve mapear por `(id_ponto_venda, id_finalizador)` ou usar o campo `meio` (nome textual) como referência semântica.

#### Pergunta 29: Tabela oficial de finalizadores?

**Resposta:** Não há tabela centralizada. O agente envia o `nome` do finalizador junto com o `id_finalizador` em cada payload. O backend pode montar a tabela agregando os dados recebidos.

**Finalizadores típicos nas lojas MaisCapinhas:**

| id_finalizador | nome (típico) |
|---|---|
| 1 | Dinheiro |
| 2 | Cartão Débito |
| 3 | Cartão Crédito |
| 4 | PIX |
| 5 | Vale |

> Verificar por loja; pode haver variações.

#### Pergunta 30: Venda sem `id_turno`?

**Resposta:** ⚠️ **Teoricamente possível** se o turno foi corrompido no banco. Na prática, o HiperPdv sempre associa venda a turno. Se `id_turno` for `NULL`, a venda aparece em `vendas[]` sem turno associado e sem dados de conferência.

---

### 4.3 Versionamento de Contrato

#### Pergunta 31: Como será versionado o payload?

**Resposta:** Atualmente via `agent.version` no corpo do JSON (`"2.0.0"`). Não há header ou URL de versão.

**Sugestão aceita:** Podemos adicionar:
- `X-PDV-Schema-Version: 2.0` no header
- E/ou campo `schema_version` no payload raiz

#### Pergunta 32: SLA de aviso prévio para breaking changes?

**Resposta:** Por ser um projeto interno MaisCapinhas, o SLA é flexível. Sugerimos **7 dias** de aviso + período de rollout por loja.

#### Pergunta 33: JSON Schema oficial versionado?

**Resposta:** ❌ **Não existe** formalmente. Porém, os modelos Pydantic v2 do agente **podem gerar JSON Schema automaticamente:**

```python
from src.payload import SyncPayload
schema = SyncPayload.model_json_schema()
```

**Ação:** Podemos gerar e publicar o JSON Schema como artefato versionado por release.

#### Pergunta 34: Lojas em v1 e v2 ao mesmo tempo?

**Resposta:** ✅ **Sim, isso acontecerá durante rollout.** Atualmente temos:
- 1 loja em v2.0 (Komprão Centro TJ, ID 10)
- 11 lojas ainda sem agente

O payload v1 tem `sales` (agregado); v2 tem `turnos[]`, `vendas[]`, `resumo`. O campo `agent.version` indica qual versão.

**Recomendação para o backend:** Detectar `agent.version` e processar campos conforme a versão:
```php
if (version_compare($payload['agent']['version'], '2.0.0', '>=')) {
    // Processar turnos[], vendas[], resumo
} else {
    // Processar sales (legado)
}
```

---

## P2 — Operação e Suporte

#### Pergunta 35: Ambiente de homologação?

**Resposta:** Podemos configurar um agente em modo "dry-run" que:
- Conecta ao banco real (read-only)
- Gera o payload normalmente
- Envia para um endpoint de homologação diferente

Basta alterar `API_ENDPOINT` no `.env` para apontar para staging.

#### Pergunta 36: Payloads de replay?

**Resposta:** ✅ **Possível.** Os payloads ficam salvos no outbox quando falham. Podemos:
1. Coletar payloads reais do outbox
2. Gerar payloads históricos sob demanda com `--run --config` em janelas passadas
3. Mascarar dados sensíveis se necessário

#### Pergunta 37: Canal de suporte?

**Resposta:** Comunicação direta entre os times (interno MaisCapinhas). Sugerimos canal no Slack/WhatsApp com SLA de **4h** para incidentes de integração em horário comercial.

#### Pergunta 38: Monitoramento de taxa de erro?

**Resposta:** O agente loga todo envio com status em `agent.log`. O backend pode agregar:
- Por loja: `pdv_syncs.store_id` + status
- Por hora: volume de syncs por loja

**Do lado do agente**, podemos adicionar um endpoint de health check se necessário.

#### Pergunta 39: Contingência para webhook indisponível?

**Resposta:** ✅ **Já implementado.** O outbox é a contingência:
1. POST falha → payload salvo no outbox (disco local)
2. Cada ciclo (10 min) → tenta reenviar outbox antes de novo sync
3. Sem TTL — payloads persistem até sucesso

**Risco residual:** Se o disco da loja encher. Mas a 5KB por payload, levaria meses.

#### Pergunta 40: Volume médio por payload?

**Resposta:**

| Métrica | Valor típico | Máximo esperado |
|---|---|---|
| Tamanho do JSON | **1-5 KB** | ~50 KB (turno com 100+ vendas) |
| Vendas por payload | **0-15** | ~50 (horário de pico) |
| Itens por venda | **1-5** | ~20 |
| Pagamentos por venda | **1-2** | ~4 |
| Turnos por payload | **1** | 2 (troca de turno durante janela) |

---

## Dúvidas Específicas

#### Pode existir sobreposição de janela `window.from/to`?

**Resposta:** ❌ **Não, por design.** A janela é calculada como `[last_sync_to, now()]`. O `last_sync_to` só avança após POST com sucesso. Janelas são **contíguas e sem gap**.

**Exceção:** Se o `state.json` for apagado/corrompido, a próxima janela cobre apenas os últimos `SYNC_WINDOW_MINUTES` (10 min), podendo perder dados intermediários.

#### Existe garantia de ordenação de `ops.ids`?

**Resposta:** ✅ **Sim.** Ordenado por `id_operacao ASC`:
```sql
SELECT id_operacao FROM operacao_pdv ... ORDER BY id_operacao
```

#### Pode vir venda duplicada em janelas diferentes?

**Resposta:** ❌ **Não, por design.** A janela usa `data_hora_termino >= @dt_from AND data_hora_termino < @dt_to` — intervalo fechado-aberto `[from, to)`. Cada venda aparece em **exatamente uma janela**.

**Exceção teórica:** Se o `data_hora_termino` do banco for alterado retroativamente (altamente improvável no HiperPdv).

#### Pode existir alteração retroativa de venda já enviada?

**Resposta:** ⚠️ **Teoricamente sim** (via SQL direto no banco), mas o HiperPdv não faz isso em operação normal. Se acontecer, o agente **não detecta** e não reenvia.

#### Pode haver mudança de `id_finalizador` no meio do turno?

**Resposta:** ❌ **Não.** O `id_finalizador` é FK para `finalizador_pdv`, tabela cadastral. Não muda durante turno. Pode mudar entre versões do HiperPdv (configuração).

---

## Matriz de Erro/Retry (Proposta Conjunta)

| HTTP Status | Significado | Agente faz... | Backend retorna... |
|---|---|---|---|
| **200** | Aceito (ou duplicado) | ✅ Remove do outbox, avança state | `{"status":"ok","sync_id":"..."}` |
| **201** | Criado (primeiro recebimento) | ✅ Idem | `{"status":"created","sync_id":"..."}` |
| **422** | Payload inválido | ❌ Salva no outbox | `{"error":"validation","details":[...]}` |
| **401/403** | Auth/HMAC inválido | ❌ Salva no outbox | `{"error":"unauthorized"}` |
| **429** | Rate limit | ⏳ Salva no outbox (retry em 10 min) | `Retry-After: 60` |
| **500/503** | Erro transitório | ⏳ Retry 3x com backoff, depois outbox | — |

> **Ajuste sugerido:** O agente deve distinguir 422 (não fazer retry — payload inválido, precisa correção) de 5xx (retry faz sentido). Atualmente trata ambos como falha e salva no outbox.

---

## Sugestões Técnicas — Status de Implementação

| # | Sugestão | Status | Estimativa |
|---|---|---|---|
| 1 | `line_no` em itens/pagamentos | ❌ Não implementado | 1-2h |
| 2 | Timezone explícito em datetimes | ❌ Naive (sem offset) | 2h |
| 3 | `sync_id` determinístico | ✅ Implementado | — |
| 4 | `schema_version` no payload | ❌ Só `agent.version` | 30min |
| 5 | `X-Request-Id` por tentativa | ❌ Não implementado | 30min |
| 6 | JSON Schema publicado | ⚠️ Pydantic pode gerar | 1h |
| 7 | Eventos de exceção documentados | ⚠️ Parcial (warnings) | 2h |
| 8 | Matriz de erro/retry | ⚠️ Parcial (ver acima) | 1h |

**Total estimado para implementar tudo:** ~8-10h de desenvolvimento.

---

## Próximos Passos Propostos

| # | Ação | Responsável | Prazo |
|---|---|---|---|
| 1 | Backend implementar `POST /api/v1/pdv/sync` com UPSERT | Time API | 1 semana |
| 2 | Agente implementar HMAC + `X-Request-Id` | Time Hiper (nós) | 2 dias |
| 3 | Publicar JSON Schema oficial | Time Hiper | 1 dia |
| 4 | Teste de ponta a ponta em homologação | Ambos | 2 dias |
| 5 | Go-live gradual (1-2 lojas com monitoramento reforçado) | Ambos | 1 semana |
| 6 | Rollout para 12 lojas | Time Hiper | 2-3 dias |

---

## Exemplo de Payload Real (Produção)

```json
{
  "agent": {
    "version": "2.0.0",
    "machine": "PDV-TIJUCAS-01",
    "sent_at": "2026-02-10T21:12:56.620869"
  },
  "store": {
    "id_ponto_venda": 10,
    "nome": "Loja 1 - MC Komprão Centro TJ",
    "alias": "tijucas-01"
  },
  "window": {
    "from": "2026-02-10T21:02:56.620869",
    "to": "2026-02-10T21:12:56.620869",
    "minutes": 10
  },
  "turnos": [
    {
      "id_turno": "6A91E9F2-FF8C-4E40-BA90-8BF04B889A57",
      "sequencial": 42,
      "fechado": false,
      "data_hora_inicio": "2026-02-10T08:00:00",
      "data_hora_termino": null,
      "operador": { "id_usuario": 5, "nome": "Carlos" },
      "totais_sistema": {
        "total": 1250.50,
        "qtd_vendas": 15,
        "por_pagamento": [
          { "id_finalizador": 1, "meio": "Dinheiro", "total": 450.00, "qtd_vendas": 6 },
          { "id_finalizador": 3, "meio": "Cartão Crédito", "total": 800.50, "qtd_vendas": 9 }
        ]
      },
      "fechamento_declarado": null,
      "falta_caixa": null
    }
  ],
  "vendas": [
    {
      "id_operacao": 5001,
      "data_hora": "2026-02-10T21:05:30",
      "id_turno": "6A91E9F2-FF8C-4E40-BA90-8BF04B889A57",
      "total": 89.90,
      "itens": [
        {
          "id_produto": 1234,
          "codigo_barras": "7891234567890",
          "nome": "Capinha iPhone 15 Pro",
          "qtd": 2, "preco_unit": 39.95, "total": 79.90, "desconto": 0.00,
          "vendedor": { "id_usuario": 12, "nome": "Maria Silva" }
        }
      ],
      "pagamentos": [
        { "id_finalizador": 3, "meio": "Cartão Crédito", "valor": 89.90, "troco": 0.00, "parcelas": 2 }
      ]
    }
  ],
  "resumo": {
    "by_vendor": [
      { "id_usuario": 12, "nome": "Maria Silva", "qtd_cupons": 1, "total_vendido": 89.90 }
    ],
    "by_payment": [
      { "id_finalizador": 3, "meio": "Cartão Crédito", "total": 89.90 }
    ]
  },
  "ops": { "count": 1, "ids": [5001] },
  "integrity": { "sync_id": "11aeef4dffc8...", "warnings": [] }
}
```
