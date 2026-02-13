# Análise Detalhada: Turnos Antigos e Login NULL nos Snapshots

Data: 2026-02-13  
Autor: PDV Sync Agent Team  
Status: **3 BUGS CORRIGIDOS** ✅

---

## 1. Resumo Executivo

Foram identificados **2 problemas distintos** no payload v3.0:

| # | Problema | Causa | Severidade | Status |
|---|---------|-------|------------|--------|
| 1 | Turnos antigos (2024/2025) em todo payload | Lógica intencional com efeito colateral | ⚠️ Média | Documentado |
| 2 | `login = null` em snapshots | **Bug de código** (3 pontos) | 🔴 Alta | **Corrigido** |

---

## 2. Problema 1: Turnos Antigos no Payload

### 2.1 Sintoma Observado

A loja `Loja 11 - MC Camboriú Caledônia` (id_ponto_venda=2) envia em **todo** payload turnos de Set/2025 e Nov/2025, todos com `fechado: false`.

Exemplo do payload recebido:
```
turnos[0] -> BD505180... | 2025-09-16 | fechado=false | qtd_vendas=1
turnos[1] -> 57BBBBCF... | 2025-09-17 | fechado=false | qtd_vendas=0
turnos[2] -> D5390DEB... | 2025-11-27 | fechado=false | qtd_vendas=0
turnos[3] -> B778806C... | 2026-02-12 | fechado=true  | qtd_vendas=1  ← apenas este é relevante
```

### 2.2 Causa Raiz

A query `get_turnos_with_activity` em `queries.py` (linha 146-205) busca turnos de **3 maneiras**:

```sql
WHERE t.id_ponto_venda = ?
  AND (
    -- Case 1: turno teve operação na janela (venda/fechamento)
    t.id_turno IN (SELECT ... WHERE op.data_hora_termino >= ? AND < ?)
    
    -- Case 2: turno FECHOU na janela
    OR (t.fechado = 1 AND t.data_hora_termino >= ? AND < ?)
    
    -- Case 3: turno ABERTO (reportar status live) ← PROBLEMA
    OR (t.fechado = 0 AND t.data_hora_termino IS NULL)
  )
```

**O Case 3 não tem filtro de data.** Isso é intencional (reportar status de turnos abertos), mas causa o efeito colateral de trazer **qualquer turno jamais fechado**, mesmo de meses/anos atrás.

### 2.3 O Que Está Acontecendo no Banco

Esses turnos estão genuinamente **abertos** na tabela `dbo.turno`:
- Nunca receberam `fechado = 1`
- Nunca receberam `data_hora_termino`
- Provavelmente foram criados por erro operacional (operador abriu turno e não fechou) ou por falha de software

### 2.4 Impacto no Backend

| Aspecto | Impacto |
|---------|---------|
| **Volume** | 3 turnos extras por payload × ~144 payloads/dia = ruído |
| **Dados** | `qtd_vendas=0` ou `=1` (venda antiga) sem utilidade |
| **Confusão** | Turno de Set/2025 misturado com turnos atuais |

### 2.5 Recomendações

#### Para o Backend (curto prazo):
- **Filtrar** turnos recebidos por data: ignorar turnos com `data_hora_inicio` > 48h atrás
- **Ou** ignorar turnos com `fechado=false` e `qtd_vendas=0`

#### Para o Agente (próxima versão):
- Adicionar filtro temporal no Case 3:
```sql
OR (
    t.fechado = 0
    AND t.data_hora_termino IS NULL
    AND t.data_hora_inicio >= DATEADD(DAY, -2, GETDATE())  -- apenas últimos 2 dias
)
```

> [!IMPORTANT]
> Não alteramos a query agora para não causar regressão. O backend deve estar preparado para receber esses turnos e filtrar por idade.

---

## 3. Problema 2: Login NULL nos Snapshots

### 3.1 Sintoma Observado

No mesmo payload, o campo `login` aparece preenchido em `turnos[]` mas como `null` em `snapshot_turnos[]` e `snapshot_vendas[]`:

```
// ✅ turnos[] -> login preenchido
"operador": { "id_usuario": 86, "nome": "Loja 11 - Caledônia", "login": "filial11" }

// ❌ snapshot_turnos[] -> login NULL
"operador": { "id_usuario": 86, "nome": "Loja 11 - Caledônia", "login": null }

// ❌ snapshot_vendas[] -> login NULL
"vendedor": { "id_usuario": 88, "nome": "Julia Thais", "login": null }
```

### 3.2 Causa Raiz: 3 Bugs Identificados

#### Bug A: SQL faltando coluna (`queries.py`)

A query `get_turno_snapshot` fazia JOIN com a tabela `usuario` mas **não selecionava** `u.login`:

```diff
  t.id_usuario AS id_operador,
  u.nome AS nome_operador,
+ u.login AS login_operador,   ← FALTAVA
```

**Nota:** A query JÁ buscava `login_responsavel` (via subquery), mas o login do **operador** (quem abriu o turno) não era trazido.

#### Bug B: Python não mapeando login do responsável (`runner.py` L325-332)

O método `_build_turno_snapshots()` construía `OperatorInfo` sem o campo `login`, mesmo quando o SQL retornava `login_responsavel`:

```diff
  responsavel=OperatorInfo(
      id_usuario=row.get("id_responsavel"),
      nome=row.get("nome_responsavel"),
+     login=row.get("login_responsavel"),   ← FALTAVA
  ),
```

#### Bug C: Python não mapeando login do vendedor (`runner.py` L362-365)

O método `_build_venda_snapshots_combined()` construía o vendedor sem `login`, mesmo quando o SQL retornava `login_vendedor`:

```diff
  vendedor=OperatorInfo(
      id_usuario=row.get("id_vendedor"),
      nome=row.get("nome_vendedor"),
+     login=row.get("login_vendedor"),   ← FALTAVA
  ),
```

### 3.3 Por Que Funcionava em `turnos[]`?

A query `get_turnos_with_activity` (usada para `turnos[]` no detalhe) **JÁ buscava** `u.login AS login_operador` e a função `build_turno_detail` **JÁ mapeava** corretamente:

```python
# payload.py L426 - CORRETO (já existia)
login=turno.get("login_operador"),
```

Esse mesmo tratamento não foi replicado nos builders de snapshot.

### 3.4 Correções Aplicadas

| Arquivo | Linha | Correção |
|---------|-------|----------|
| `queries.py` | 596 | Adicionado `u.login AS login_operador` na query SQL |
| `runner.py` | 327 | Adicionado `login=row.get("login_operador")` no operador |
| `runner.py` | 333 | Adicionado `login=row.get("login_responsavel")` no responsável |
| `runner.py` | 365 | Adicionado `login=row.get("login_vendedor")` no vendedor PDV |
| `runner.py` | 389 | Adicionado `login=row.get("login_vendedor")` no vendedor Loja |

### 3.5 Resultado Esperado Após Fix

```json
// snapshot_turnos[] -> login agora será preenchido
"operador": { "id_usuario": 86, "nome": "Loja 11 - Caledônia", "login": "filial11" }
"responsavel": { "id_usuario": 88, "nome": "Julia Thais", "login": "JuliaThais" }

// snapshot_vendas[] -> login agora será preenchido
"vendedor": { "id_usuario": 88, "nome": "Julia Thais", "login": "JuliaThais" }
```

---

## 4. Resumo de Alterações por Arquivo

### `src/queries.py`
- Adicionada coluna `u.login AS login_operador` na query `get_turno_snapshot`

### `src/runner.py`
- `_build_turno_snapshots()`: Adicionado mapeamento de `login` para `operador` e `responsavel`
- `_build_venda_snapshots_combined()`: Adicionado mapeamento de `login` para `vendedor` (PDV e Loja)

---

## 5. Ações Necessárias

| Ação | Responsável | Prioridade |
|------|-------------|------------|
| Rebuild e redeploy do agente com fixes de login | Time Python | 🔴 Alta |
| Backend aceitar payloads 3.0 com campos extras | Time PHP | 🟡 Média |
| Backend filtrar turnos antigos (>48h abertos) | Time PHP | 🟡 Média |
| Fechar turnos antigos diretamente no banco | Time Operações | 🟢 Baixa |
