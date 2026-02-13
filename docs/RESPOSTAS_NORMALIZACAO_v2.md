# Respostas Técnicas — Normalização de Lojas e Usuários (Webhook PDV JSON)

**Data:** 2026-02-11
**Autor:** PDV Sync Agent Team
**Versão do Agente:** 2.0.0 | **Schema:** 2.0
**Fonte de evidência:** Código-fonte do `pdv-sync-agent` + banco HiperPdv SQL Server local

---

## Legenda de Confiança

| Tag | Significado |
|---|---|
| ✅ **CONFIRMADO** | Validado no código-fonte e/ou SQL Server real |
| ⚠️ **OBSERVADO** | Comportamento observado nos dados, mas sem documentação oficial Hiper |
| ❓ **NÃO SABEMOS** | Não temos como confirmar — depende do ERP Hiper ou de decisão de negócio |
| 🔧 **PROPOSTA** | Sugestão de solução para fechar o contrato |

---

## 3.1 Identidade de Loja (`store.id_ponto_venda`)

### Pergunta 1: `id_ponto_venda` é globalmente único em toda a rede ou apenas único por banco local?

**Tag:** ⚠️ OBSERVADO

**Resposta:** `id_ponto_venda` é a **PK da tabela `dbo.ponto_venda`** no banco SQL Server **local de cada loja**. Cada loja tem seu próprio banco `HiperPdv` isolado. No nosso ambiente de testes, `id_ponto_venda = 10`.

**Evidência SQL:**
```sql
-- queries.py:49-54
SELECT id_ponto_venda, {name_column} AS nome
FROM dbo.ponto_venda
WHERE id_ponto_venda = ?
```

**Evidência Config:**
```env
# config.template.env:51
STORE_ID_PONTO_VENDA=__STORE_ID__
```

**Risco:** Como cada loja tem seu próprio banco, é **possível** que duas lojas tenham o mesmo `id_ponto_venda` (ex: ambas = 10). O agente envia o valor configurado no `.env` de cada máquina. **Não temos como garantir unicidade global a partir do agente.**

---

### Pergunta 2: `id_ponto_venda` pode mudar após reinstalação/migração de banco?

**Tag:** ❓ NÃO SABEMOS

**Resposta:** Não temos informação sobre o comportamento do ERP Hiper em caso de reinstalação/migração de banco. O `id_ponto_venda` é um campo inteiro que normalmente é auto-increment ou fixo na tabela `ponto_venda`. **O agente usa o valor configurado no `.env`**, não detecta mudanças automaticamente.

**Evidência:**
```python
# settings.py:83
store_id_ponto_venda: int = Field(default=10, alias="STORE_ID_PONTO_VENDA")
```

Se o banco for reinstalado e o ID mudar, o `.env` precisaria ser atualizado manualmente.

---

### Pergunta 3: `id_ponto_venda` pode ser reutilizado para outra loja no futuro?

**Tag:** ❓ NÃO SABEMOS

Depende da política do ERP Hiper. Como cada banco é local e independente, **tecnicamente sim**, cada banco pode ter qualquer `id_ponto_venda`. Não existe coordenação central no nível do agente.

---

### Pergunta 4: Existe identificador imutável melhor que `id_ponto_venda` (GUID, CNPJ, código legado)?

**Tag:** ⚠️ OBSERVADO + 🔧 PROPOSTA

**O que sabemos:** A tabela `ponto_venda` no banco HiperPdv que exploramos tem colunas limitadas (apenas `id_ponto_venda`, `apelido`/`nome`/`descricao` conforme a versão). **Não encontramos** CNPJ, GUID ou código externo na tabela.

**Proposta:** O melhor identificador imutável que **controlamos** é a combinação:
```
STORE_ID_PONTO_VENDA + STORE_ALIAS (configurados no .env)
```

O `STORE_ALIAS` é preenchido pelo técnico na instalação e funciona como slug humano (ex: `loja-komprão-centro-tj`).

**Alternativa:** Adicionar `STORE_CNPJ` ou `STORE_EXTERNAL_ID` no `.env` e no payload — requer mudança no agente.

---

### Pergunta 5: `store.nome` e `store.alias` são apenas display ou podem ser usados como chave de negócio?

**Tag:** ✅ CONFIRMADO

| Campo | Fonte | Uso |
|---|---|---|
| `store.id_ponto_venda` | `.env` → `STORE_ID_PONTO_VENDA` | **Chave de mapping** (INT configurado por loja) |
| `store.nome` | Tabela `dbo.ponto_venda` (coluna `apelido`/`nome`/`descricao`) | **Display only** — vem do banco local |
| `store.alias` | `.env` → `STORE_ALIAS` | **Display only** — preenchido manualmente na instalação |

**Evidência código:**
```python
# runner.py:139-140 (_build_payload)
store_name = store_info["nome"] if store_info else f"PDV {self.settings.store_id_ponto_venda}"
# runner.py:147
store_alias=self.settings.store_alias,
```

**Recomendação:** Usar `id_ponto_venda` como chave de mapping no backend, `nome` e `alias` apenas para exibição.

---

### Pergunta 6: Quando uma loja muda nome/alias, isso muda retroativamente nos payloads futuros?

**Tag:** ✅ CONFIRMADO

**Sim.** O `nome` é lido do banco local a cada sync. O `alias` é lido do `.env` a cada boot do agente.

- Se o ERP Hiper renomear a loja no banco → `store.nome` muda no **próximo payload**
- Se o técnico alterar `STORE_ALIAS` no `.env` → `store.alias` muda no **próximo restart**

**Payloads antigos já enviados não são afetados** — o agente não reenvia dados passados.

---

### Pergunta 7: Existe evento formal de abertura/fechamento/renomeação de loja?

**Tag:** ❓ NÃO SABEMOS

O agente não monitora nem detecta eventos de abertura/fechamento/renomeação. Ele simplesmente lê `dbo.ponto_venda` a cada ciclo de sync.

---

### Pergunta 8: A rede pode ter 2 lojas com mesmo `store.nome` em regiões diferentes?

**Tag:** ❓ NÃO SABEMOS

Depende da configuração do ERP Hiper. Como cada banco é local, o nome é definido no banco de cada loja independentemente. **Tecnicamente possível** ter nomes duplicados.

---

### Pergunta 9: Existe timezone por loja diferente de `America/Sao_Paulo`?

**Tag:** ✅ CONFIRMADO

**Hoje não.** O timezone é fixo no código (`UTC-3`, BRT) e não é configurável por loja:

```python
# __init__.py:7
BRT = timezone(timedelta(hours=-3))
```

Todas as lojas da rede Mais Capinhas operam em SC (fuso BRT). Se houver expansão para outra timezone (ex: Manaus, UTC-4), seria necessário adicionar `STORE_TIMEZONE` no `.env` e ajustar o agente.

---

### Pergunta 10: Qual o SLA para aviso de nova loja antes de começar a enviar webhook?

**Tag:** ❓ NÃO SABEMOS

O agente é instalado manualmente em cada loja nova. O processo atual é:

1. Técnico vai à loja
2. Executa `install.bat` (que pede `STORE_ID_PONTO_VENDA` e `STORE_ALIAS`)
3. Agente começa a enviar payloads imediatamente

**Não existe aviso prévio ao backend.** Se o mapping não existir, o backend deve aceitar e marcar `risk_flag=store_mapping_missing` (como vocês já fazem).

🔧 **Proposta:** Criar um endpoint `POST /api/v1/pdv/register` que o agente chame na primeira execução para avisar o backend. Ou o técnico de instalação registrar no painel admin antes de instalar.

---

## 3.2 Identidade de Usuário (`operador.id_usuario`, `itens[].vendedor.id_usuario`)

### Pergunta 11: `id_usuario` é globalmente único entre lojas ou único apenas dentro de cada loja?

**Tag:** ⚠️ OBSERVADO

**Único apenas dentro de cada loja.** O `id_usuario` é PK da tabela `dbo.usuario` no banco **local** de cada loja. Como cada loja tem seu próprio banco HiperPdv, o `id_usuario = 5` na Loja A pode ser uma pessoa diferente do `id_usuario = 5` na Loja B.

**Evidência SQL:**
```sql
-- queries.py:126 (turno → operador)
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario

-- queries.py:270 (item → vendedor)
LEFT JOIN dbo.usuario u ON u.id_usuario = it.id_usuario_vendedor
```

---

### Pergunta 12: A mesma pessoa pode ter IDs diferentes em lojas diferentes?

**Tag:** ⚠️ OBSERVADO

**Sim, muito provável.** Como cada loja tem cadastro de usuário local no HiperPdv, se uma pessoa trabalha em 2 lojas, ela terá IDs diferentes em cada banco. Não existe cadastro centralizado no ERP.

---

### Pergunta 13: Um mesmo `id_usuario` pode representar pessoas diferentes em lojas distintas?

**Tag:** ⚠️ OBSERVADO

**Sim.** `id_usuario = 5` na Loja A pode ser "João" e na Loja B pode ser "Maria". O ID é local ao banco.

**Implicação para o backend:** A chave de dedup de usuário deve ser composta: `(store_id_ponto_venda, id_usuario)`.

---

### Pergunta 14: Existe identificador central de pessoa (matrícula/CPF/e-mail)?

**Tag:** ❓ NÃO SABEMOS

Não encontramos CPF, matrícula ou e-mail na tabela `dbo.usuario` do banco que exploramos. As colunas que usamos são:
- `id_usuario` (INT, PK)
- `nome` (VARCHAR)

O ERP Hiper pode ter mais campos, mas **não os consultamos** porque nosso objetivo é leitura mínima (SELECT read-only).

🔧 **Proposta:** Podemos adicionar uma query para listar todas as colunas da tabela `usuario` em produção e verificar se existe CPF ou matrícula:
```sql
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'usuario'
ORDER BY ORDINAL_POSITION
```

---

### Pergunta 15: `operador.id_usuario` (turno) é sempre o mesmo conceito de `vendedor.id_usuario` (item)?

**Tag:** ✅ CONFIRMADO

**Sim, mesma tabela, mas conceitos diferentes:**

| Campo no Payload | Tabela Origem | Coluna | Significado |
|---|---|---|---|
| `turnos[].operador.id_usuario` | `dbo.turno` | `id_usuario` | Quem **abriu/fechou** o turno (caixa) |
| `vendas[].itens[].vendedor.id_usuario` | `dbo.item_operacao_pdv` | `id_usuario_vendedor` | Quem **vendeu** o item específico |

Ambos referenciam a tabela `dbo.usuario`, mas representam papéis diferentes. JOINs relevantes:

```sql
-- Operador (turno)
LEFT JOIN dbo.usuario u ON u.id_usuario = t.id_usuario

-- Vendedor (item)
LEFT JOIN dbo.usuario uv ON uv.id_usuario = it.id_usuario_vendedor
```

---

### Pergunta 16: Um operador pode abrir turno e outro vendedor vender no mesmo turno?

**Tag:** ✅ CONFIRMADO

**Sim.** Observamos isso nos dados reais. Exemplo:
- Turno aberto pelo `operador.id_usuario = 5` ("João")
- Itens vendidos com `vendedor.id_usuario = 92` ("Vitória")

Isso é o comportamento normal: o operador de caixa recebe os pagamentos, enquanto o vendedor de loja traz os clientes.

**Evidência no resumo:**
```sql
-- queries.py:264-265 (vendas por vendedor)
it.id_usuario_vendedor,
u.nome AS vendedor_nome
```

O `resumo.by_vendor` agrupa por `id_usuario_vendedor`, que pode ser diferente do operador do turno.

---

### Pergunta 17: `id_usuario` pode ser reciclado após desligamento/reativação?

**Tag:** ❓ NÃO SABEMOS

Não temos informação sobre a política do ERP Hiper. Como o `id_usuario` parece ser um INT auto-increment, **provavelmente não é reciclado** (padrão SQL Server IDENTITY), mas não podemos confirmar.

---

### Pergunta 18: Alteração de nome de usuário ocorre com frequência? Existe histórico?

**Tag:** ❓ NÃO SABEMOS

O agente lê `usuario.nome` a cada ciclo de sync. Se o nome mudar no ERP Hiper, o payload seguinte trará o nome novo. **Não mantemos histórico de nomes** — isso ficaria a cargo do backend.

---

### Pergunta 19: Quando `id_usuario` for null, qual regra aplicar para metas/comissão?

**Tag:** ✅ CONFIRMADO (detecção) + ❓ NÃO SABEMOS (regra de negócio)

**O que o agente faz:** Detecta e reporta vendedor NULL como warning:

```python
# runner.py:234-236 (_check_warnings)
null_vendors = [v for v in sales_by_vendor if v.get("id_usuario_vendedor") is None]
if null_vendors:
    total_null = sum(v.get("qtd_cupons", 0) for v in null_vendors)
    warnings.append(f"Vendedor NULL encontrado em {total_null} cupom(s)")
```

O campo `vendedor` no item será `null` quando `id_usuario_vendedor` for NULL no banco:

```python
# payload.py:404-407
vendedor=OperatorInfo(
    id_usuario=item.get("id_usuario_vendedor"),
    nome=item.get("nome_vendedor"),
) if item.get("id_usuario_vendedor") else None,
```

**Quando acontece:** Venda feita sem vendedor atribuído (ex: venda direta no caixa).

**Regra de negócio:** Compete ao time de produto definir se venda sem vendedor vai para "Não atribuído", para o operador do turno, ou se é excluída de metas.

---

### Pergunta 20: Existe tabela mestre de usuários por loja para exportação periódica?

**Tag:** 🔧 PROPOSTA

**Não existe exportação periódica hoje.** Mas podemos adicionar uma query ao agente que envie a lista de usuários uma vez por dia:

```sql
SELECT id_usuario, nome
FROM dbo.usuario
ORDER BY id_usuario
```

Isso poderia ser enviado como carga especial (ex: payload type `user_sync`) para o backend reconciliar.

---

## 3.3 Correção Retroativa e Consistência Histórica

### Pergunta 21: Venda/item já enviado pode mudar vendedor depois?

**Tag:** ⚠️ OBSERVADO + ❓ NÃO SABEMOS

**O que o agente faz:** O agente usa `data_hora_termino` como janela temporal. Só envia vendas cujo `data_hora_termino` caia na janela atual. **Vendas já concluídas e enviadas não são reenviadas**, mesmo que o vendedor mude depois.

```sql
-- queries.py:230-231
AND op.data_hora_termino >= ?
AND op.data_hora_termino < ?
```

**Não sabemos** se o ERP Hiper permite editar o vendedor de um item após a venda ser finalizada. Se isso ocorrer, **o agente não detectará** a mudança.

---

### Pergunta 22: Turno fechado pode ser reaberto e alterar operador/totais?

**Tag:** ❓ NÃO SABEMOS

O agente lê `turno.fechado` como boolean. Não monitoramos mudanças nesse campo. Se o ERP Hiper reabrir um turno, o agente não reenviará os dados desse turno (já passaram da janela temporal).

---

### Pergunta 23: Se houver correção retroativa, o agente reenviará o mesmo `id_operacao` com novos dados?

**Tag:** ✅ CONFIRMADO — **NÃO**

O agente **não reenvia dados passados**. A janela de sync é sempre "os últimos N minutos" (padrão: 10). Uma vez que a janela avança, os dados antigos não são consultados novamente.

O `sync_id` é determinístico baseado em `(store_id, dt_from, dt_to)`, então se por algum motivo o agente processar a mesma janela duas vezes (ex: outbox retry), o backend pode ignorar com base no `sync_id`.

```python
# payload.py:254
data = f"{store_id}|{dt_from.isoformat()}|{dt_to.isoformat()}"
return hashlib.sha256(data.encode()).hexdigest()
```

---

### Pergunta 24: Comportamento oficial para cancelamento após envio?

**Tag:** ✅ CONFIRMADO

O agente filtra `cancelado = 0` em **todas** as queries de vendas:

```sql
-- queries.py:228
AND op.cancelado = 0
-- queries.py:398
WHERE it.cancelado = 0
```

**Se uma venda for cancelada depois de enviada:**
- O agente **não envia evento de cancelamento** (PR-08 foi skippado)
- O backend ficará com a venda como válida
- O cancelamento só seria detectado em uma reconciliação manual

🔧 **Proposta futura (PR-08):** Implementar detecção de cancelamento pós-envio, comparando `ops.ids` enviados vs. estado atual no banco.

---

### Pergunta 25: Existem casos de divergência entre `resumo.by_vendor` e soma real de `vendas[].itens[]`?

**Tag:** ⚠️ OBSERVADO

**É possível** em casos de borda:
- `resumo.by_vendor` vem de uma query agregada (`get_sales_by_vendor`) com CTE
- `vendas[].itens[]` vem de outra query individual (`get_sale_items`)

Ambas filtram `operacao = 1 AND cancelado = 0`, mas em caso de **race condition** (venda finalizada entre as duas queries), pode haver pequena divergência.

**Na prática:** Com janela de 10 minutos e queries rodando em sequência (~100ms de gap), a chance de divergência é extremamente baixa.

---

## 4.1 Dicionários de Apoio para Normalização

### Pergunta 26: Podem enviar carga inicial de lojas?

**Tag:** 🔧 PROPOSTA

**Hoje não enviamos.** Mas o agente já envia `store.id_ponto_venda`, `store.nome` e `store.alias` em **todo payload**. O backend pode construir o cadastro de lojas incrementalmente.

Para carga inicial formal, seria necessário:
1. Coletar manualmente de cada loja: `id_ponto_venda`, CNPJ, endereço
2. Ou criar planilha/endpoint de cadastro

---

### Pergunta 27: Podem enviar carga inicial de usuários por loja?

**Tag:** 🔧 PROPOSTA

Similarmente, podemos adicionar uma query ao agente:

```sql
SELECT id_usuario, nome FROM dbo.usuario ORDER BY id_usuario
```

E enviar como payload especial periódico. **Hoje não existe.**

---

### Pergunta 28: Qual campo define usuário ativo/inativo?

**Tag:** ❓ NÃO SABEMOS

Não exploramos se a tabela `dbo.usuario` tem campo de status (ativo/inativo). Precisaria rodar:
```sql
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'usuario'
```

---

### Pergunta 29: Em quanto tempo uma mudança cadastral entra no payload?

**Tag:** ✅ CONFIRMADO

**Imediatamente no próximo ciclo de sync** (a cada 10 minutos). O agente lê os dados frescos do banco a cada execução, sem cache.

---

### Pergunta 30: Podem publicar endpoint/arquivo de referência para reconciliação?

**Tag:** 🔧 PROPOSTA

Não existe hoje. Sugestões:
1. **Abordagem push:** Agente envia `user_sync` payload diário
2. **Abordagem pull:** Backend expõe endpoint `GET /api/v1/pdv/stores/{id}/users` e o agente verifica

---

## 4.2 Pagamentos e Produto

### Pergunta 31: `id_finalizador` é estável por loja ao longo do tempo?

**Tag:** ⚠️ OBSERVADO

Sim, na prática. `id_finalizador` é PK da tabela `dbo.finalizador_pdv` e representa o meio de pagamento (ex: 1=Dinheiro, 2=Cartão Crédito, 3=Cartão Débito, 4=Pix). No banco que exploramos, esses IDs são estáveis.

**Evidência:**
```sql
-- queries.py:320
LEFT JOIN dbo.finalizador_pdv fpv ON fpv.id_finalizador = fo.id_finalizador
```

---

### Pergunta 32: `id_finalizador` pode apontar para nomes diferentes em lojas diferentes?

**Tag:** ⚠️ OBSERVADO

**Sim, provável.** Como cada loja tem seu banco local, o `id_finalizador = 1` pode ser "Dinheiro" em uma loja e "Cartão Crédito" em outra (embora improvável na prática com o ERP Hiper, que tende a ter configuração padrão).

O agente envia **tanto `id_finalizador` quanto `meio` (nome)** para permitir mapping seguro:

```json
{
  "id_finalizador": 1,
  "meio": "Dinheiro",
  "total": 135.00
}
```

**Recomendação:** O backend deve usar `(store_id_ponto_venda, id_finalizador)` como chave composta, e `meio` como fallback para display.

---

### Pergunta 33: Em caso de reconfiguração de finalizador, existe evento de versão?

**Tag:** ❓ NÃO SABEMOS

Não monitoramos mudanças na tabela `finalizador_pdv`. Se o ERP Hiper mudar o nome de um finalizador, o agente enviará o nome novo no próximo sync sem aviso.

---

### Pergunta 34: `id_produto` é estável entre lojas ou somente local por loja?

**Tag:** ⚠️ OBSERVADO

`id_produto` é PK da tabela `dbo.produto` no banco **local**. Como a rede é da mesma franquia e usa o mesmo ERP, é **possível** que os IDs sejam sincronizados entre lojas (cadastro central no Hiper), mas **não podemos confirmar**.

---

### Pergunta 35: `codigo_barras` é sempre o mesmo cadastro entre lojas?

**Tag:** ⚠️ OBSERVADO

O `codigo_barras` vem de `dbo.item_operacao_pdv.codigo_barras`. **Código de barras (EAN)** é por definição global e imutável por produto, então deveria ser consistente entre lojas.

**Recomendação:** Use `codigo_barras` como chave canônica de produto, não `id_produto`.

---

## 5. Operação e Governança (P2)

### Pergunta 36: Contato técnico para emergências de mapping?

**Tag:** ❓ NÃO SABEMOS

Definição de responsável é decisão organizacional. Sugerimos definir junto com a liderança.

---

### Pergunta 37: SLA de resposta para incidentes de dados inconsistentes?

**Tag:** ❓ NÃO SABEMOS

Não temos SLA definido. O agente opera 24/7 com sync a cada 10 minutos, mas inconsistências só seriam detectadas pelo backend.

---

### Pergunta 38: Como será comunicado breaking change de identificadores?

**Tag:** ✅ CONFIRMADO

O agente envia o header `X-PDV-Schema-Version: 2.0`. Qualquer mudança de schema incrementará essa versão. O backend pode validar e rejeitar payloads com versão desconhecida.

```
Header: X-PDV-Schema-Version: 2.0
Body: { "schema_version": "2.0", ... }
```

---

### Pergunta 39: Podem fornecer massa de teste com casos de borda?

**Tag:** ✅ CONFIRMADO — veja Seção 8 abaixo

---

### Pergunta 40: Existe roadmap para `user_external_id` e `store_external_id`?

**Tag:** 🔧 PROPOSTA

**Não existe hoje**, mas é viável implementar:
1. Adicionar `STORE_EXTERNAL_ID` e buscar `user_external_id` no `.env` e nas queries
2. Requer descoberta das colunas reais da tabela `usuario` em produção
3. Estimativa: 1 sprint de trabalho no agente + 1 sprint no backend

---

## 6. Decisões para Fechar por Escrito

### 1. Chave canônica de loja

| Opção | Prós | Contras |
|---|---|---|
| `id_ponto_venda` (atual) | Já existe, simples | Pode colidir entre lojas |
| `id_ponto_venda + STORE_ALIAS` | Composta, mais segura | STORE_ALIAS é manual |
| **`store_external_id`** (novo) | Imutável, controlado por nós | Requer mudança no agente |

🔧 **Recomendação:** Usar `STORE_ID_PONTO_VENDA` como chave **enquanto cada loja tem ID diferente** (verificar na instalação), e implementar `store_external_id` no próximo sprint.

### 2. Chave canônica de usuário

🔧 **Recomendação:** `(store_id_ponto_venda, id_usuario)` — chave composta obrigatória. Nunca usar `id_usuario` sozinho.

### 3. Regra oficial para `id_usuario` null

🔧 **Proposta:**
- Venda sem vendedor → atribuir ao operador do turno para fins de comissão
- Ou categorizar como "Venda direta" e excluir de metas individuais
- **O agente gera warning** para facilitar auditoria

### 4. Política de alteração retroativa

✅ **Situação atual do agente:** Não detecta nem reenvia alterações retroativas. Dados já enviados são imutáveis do ponto de vista do agente.

🔧 **Proposta:** Implementar PR-08 (detecção de cancelamento pós-envio) como próximo milestone.

### 5. Fonte oficial da verdade

| Dado | Fonte | Observação |
|---|---|---|
| Lojas | `.env` por máquina | Manual, sem cadastro central |
| Usuários | `dbo.usuario` local | Por loja, sem cadastro central |
| Produtos | `dbo.produto` local | Possivelmente sincronizado pelo Hiper |
| Finalizadores | `dbo.finalizador_pdv` local | Configuração padrão Hiper |

---

## 7. Entregáveis

### 7.1 Contrato de identidade

Documentado acima neste documento.

### 7.2 & 7.3 Carga inicial de lojas e usuários

❓ **Hoje não disponível** — requer coleta manual ou nova feature no agente.

### 7.4 Lista de eventos de correção retroativa

| Evento | O agente detecta? | Enviado ao backend? |
|---|---|---|
| Cancelamento dentro da janela (10min) | ✅ Sim (filtro `cancelado=0`) | Sim — venda não aparece no payload |
| Cancelamento fora da janela | ❌ Não | Não — dados antigos não são relidos |
| Mudança de vendedor | ❌ Não | Não |
| Reabertura de turno | ❌ Não | Não |
| Mudança de nome de usuário | ✅ Sim (próximo sync) | Sim, no campo `nome` |

### 7.5 Exemplos JSON reais para 6 cenários de borda

---

## 8. Exemplos JSON para Cenários de Borda

### Cenário A: Loja sem mapping prévio (nova loja)

```json
{
  "schema_version": "2.0",
  "agent": {"version": "2.0.0", "machine": "PDV-NOVA-LOJA", "sent_at": "2026-02-11T10:00:00-03:00"},
  "store": {
    "id_ponto_venda": 15,
    "nome": "MC Shopping Beira Rio",
    "alias": "beira-rio"
  },
  "window": {"from": "2026-02-11T09:50:00-03:00", "to": "2026-02-11T10:00:00-03:00", "minutes": 10},
  "turnos": [],
  "vendas": [],
  "resumo": {"by_vendor": [], "by_payment": []},
  "ops": {"count": 0, "ids": []},
  "integrity": {"sync_id": "abc123...", "warnings": []}
}
```

> Backend deve aceitar, criar mapping com `risk_flag=store_mapping_missing`, e alertar admin.

---

### Cenário B: Vendedor NULL

```json
{
  "vendas": [{
    "id_operacao": 12500,
    "data_hora": "2026-02-11T15:30:00-03:00",
    "id_turno": "AAA-BBB-CCC",
    "itens": [{
      "line_id": 88001,
      "line_no": 1,
      "id_produto": 5353,
      "codigo_barras": "7156",
      "nome": "Cap. Iphone 15 Pro Max",
      "qtd": 1.0,
      "preco_unit": 99.90,
      "total": 99.90,
      "desconto": 0.00,
      "vendedor": null
    }],
    "pagamentos": [{"line_id": 99001, "id_finalizador": 1, "meio": "Dinheiro", "valor": 99.90, "troco": 0.10, "parcelas": null}],
    "total": 99.90
  }],
  "integrity": {
    "sync_id": "def456...",
    "warnings": ["Vendedor NULL encontrado em 1 cupom(s)"]
  }
}
```

> `vendedor: null` indica venda sem vendedor atribuído. Warning no integrity confirma.

---

### Cenário C: Mesma pessoa em duas lojas (IDs diferentes)

**Loja A (id_ponto_venda=10):**
```json
{
  "store": {"id_ponto_venda": 10, "nome": "MC Centro", "alias": "centro"},
  "vendas": [{
    "itens": [{
      "vendedor": {"id_usuario": 5, "nome": "Maria Silva"}
    }]
  }]
}
```

**Loja B (id_ponto_venda=12):**
```json
{
  "store": {"id_ponto_venda": 12, "nome": "MC Shopping", "alias": "shopping"},
  "vendas": [{
    "itens": [{
      "vendedor": {"id_usuario": 8, "nome": "Maria Silva"}
    }]
  }]
}
```

> Mesma "Maria Silva" mas `id_usuario=5` na Loja 10 e `id_usuario=8` na Loja 12. Backend precisa resolver via chave composta `(store_id, id_usuario)`.

---

### Cenário D: Troca de nome de usuário

**Antes (payload das 10:00):**
```json
{
  "vendas": [{
    "itens": [{
      "vendedor": {"id_usuario": 92, "nome": "Vitoria Santos"}
    }]
  }]
}
```

**Depois (payload das 10:10, nome alterado no ERP):**
```json
{
  "vendas": [{
    "itens": [{
      "vendedor": {"id_usuario": 92, "nome": "Vitória Oliveira Santos"}
    }]
  }]
}
```

> Mesmo `id_usuario=92`, nome diferente. Backend deve usar `id_usuario` como chave e atualizar `nome` no cadastro.

---

### Cenário E: Turno reaberto (hipotético)

```json
{
  "turnos": [{
    "id_turno": "656335C4-D6C4-455A-8E3D-FF6B3F570C64",
    "sequencial": 2,
    "fechado": false,
    "data_hora_inicio": "2026-02-11T08:00:00-03:00",
    "data_hora_termino": null,
    "operador": {"id_usuario": 5, "nome": "João"},
    "totais_sistema": {"total": 500.00, "qtd_vendas": 8, "por_pagamento": []},
    "fechamento_declarado": null,
    "falta_caixa": null
  }]
}
```

> Se o turno foi reaberto: `fechado=false`, `data_hora_termino=null`, sem `fechamento_declarado`. O agente reporta o estado atual, não o histórico.

---

### Cenário F: Cancelamento após envio (não detectado pelo agente)

**Payload original (10:00) — venda ativa:**
```json
{
  "ops": {"count": 3, "ids": [12390, 12391, 12395]},
  "vendas": [
    {"id_operacao": 12390, "total": 50.00},
    {"id_operacao": 12391, "total": 75.00},
    {"id_operacao": 12395, "total": 99.90}
  ]
}
```

**Payload das 10:10 — venda 12391 cancelada NO ERP mas fora da janela:**
```json
{
  "ops": {"count": 2, "ids": [12400, 12401]},
  "vendas": [
    {"id_operacao": 12400, "total": 120.00},
    {"id_operacao": 12401, "total": 45.00}
  ]
}
```

> A venda `12391` não aparece em nenhum payload futuro, mas o backend ainda a tem como válida. **Sem PR-08, o cancelamento não é comunicado ao backend.**

---

## 9. Resumo de Gaps e Próximos Passos

| # | Gap | Impacto | Solução | Esforço |
|---|---|---|---|---|
| 1 | `id_ponto_venda` pode colidir entre lojas | Mapping incorreto | Verificar unicidade na instalação ou criar `store_external_id` | Baixo |
| 2 | `id_usuario` é local por loja | Duplicidade de pessoas | Usar chave composta `(store_id, id_usuario)` | Nenhum (backend) |
| 3 | Sem evento de cancelamento pós-envio | Dados fantasma no backend | Implementar PR-08 | Médio |
| 4 | Sem carga inicial de usuários | Mapping reativo em vez de proativo | Adicionar `user_sync` periódico ao agente | Baixo |
| 5 | Sem CNPJ/CPF/matrícula nos payloads | Normalização manual | Explorar colunas da tabela `usuario` e `ponto_venda` | Baixo |
| 6 | `id_finalizador` local por loja | Possível mapping errado de pagamentos | Usar chave composta + nome como fallback | Nenhum (backend) |
