# Respostas ao Time Python - Webhook PDV v3.1

Data: 2026-02-13
De: Time PDV Sync Agent
Para: Backend Team (`maiscapinhas-erp-api`)
Ref: `docs/VALIDACAO_JSON_PDV_V3_1_PRE_DEPLOY_2026-02-13.md`

---

## 3) Perguntas P0 (bloqueantes para go-live)

### P0.1 - Versao efetiva do contrato
**Resposta:** Parcialmente.
**Decisão:** Manteremos `schema_version="3.0"` por enquanto.
**Explicação:** A versão atual (3.0) já contém os novos campos (`cnpj`, `login`) e está estável em 12 lojas. Para evitar o overhead operacional de re-deploy em massa apenas para trocar a string de versão, manteremos "3.0" no header/body.
**Impacto:** O backend deve aceitar payloads marcados como 3.0, mas que já trazem os campos extras do 3.1.

### P0.2 - Nulabilidade de `duracao_minutos`
**Resposta:** Em turnos abertos, o campo vai como `null`.
**Regra Agente:** O cálculo Python faz `int((termino - inicio).total_seconds() / 60)`. Se `termino` for `None`, o resultado é `None` -> JSON `null`.
**Nota:** Isso vale tanto para `turnos[]` (calculado em Python) quanto para `snapshot_turnos[]` (SQL `DATEDIFF` retorna NULL se um dos argumentos for NULL).

### P0.3 - Escopo da lista `turnos[]`
**Resposta:** Apenas turnos da loja configurada (`id_ponto_venda`), mas inclui **todos** os abertos.
**Causa do backlog:** A query busca:
1. Turnos com ação na janela (venda/fechamento).
2. OU Turnos atualmente ABERTOS (`fechado=0` AND `data_hora_termino IS NULL`).
**Impacto:** Se a loja tiver "lixo" antigo (turnos de 2024 nunca fechados no banco), eles virão em **todo** payload como "abertos" para reportar status. O backend deve estar preparado para receber essa lista repetidamente ou ignorar turnos muito antigos. não há limite `LIMIT` nessa lista.

### P0.4 - Coerencia loja x operador
**Resposta:** É comportamento esperado da base de dados (não é bug de query).
**Explicação:** A query filtra `turno.id_ponto_venda = ?`. Se o operador `filial12` abriu um turno na loja `Mata Atlantica` (id 9), o banco Hiper registrou isso e o agente reporta fielmente.
**Ação:** Backend deve aceitar que `operador.login` pode não pertencer ao prefixo da loja.

### P0.5 - Invariante `window.minutes`
**Resposta:** Não. Hoje reflete a **configuração** e não o delta real.
**Comportamento:** O campo `window.minutes` no JSON é preenchido com `settings.sync_window_minutes` (estático, ex: 10), enquanto `from` e `to` são dinâmicos.
**Impacto:** Confiem em `to - from` para cálculo de densidade/cobertura. O campo `minutes` é meramente informativo da "intenção" de configuração.

---

## 4) Perguntas P1 (qualidade de dados e relatorio)

### P1.1 - Autoridade entre `turnos[]` e `snapshot_turnos[]`
**Resposta:** `snapshot_turnos[]` (SQL) é mais "cru" e próximo do banco.
**Recomendação:** Use `snapshot` para auditoria/valores finais. Use `turnos[]` para fluxo detalhado (reconciliação de pagamentos sistema vs declarado).

### P1.2 - Diferenca de `duracao_minutos`
**Resposta:** Divergência de arredondamento Python vs SQL Server.
- **Python (Detalhe):** `int(seconds / 60)` -> Truncate (Floor). Ex: 59s = 0m.
- **SQL (Snapshot):** `DATEDIFF(MINUTE, start, end)` -> Conta *fronteiras* de minuto cruzadas. Ex: 10:00:59 p/ 10:01:01 (2s) = 1 minuto.
**Regra Final:** Aceitar pequena divergência. Snapshot (SQL) tende a ser levemente maior.

### P1.3 - `qtd_vendas` divergente
**Resposta:** Escopo de operações.
- **Detalhe (`turnos[]`):** Considera operações trazidas na memória para detalhamento (focadas na janela atual).
- **Snapshot (`snapshot_turnos[]`):** `COUNT(*)` direto no banco para aquele ID de turno.
**Conclusão:** Snapshot é a verdade absoluta do turno *inteiro*. O detalhe pode estar parcial se o turno spanar múltiplas janelas de sync (embora a lógica tente mitigar, o snapshot é a fonte autoritativa de volume total).

### P1.4 - Presenca de `login` nos snapshots
**Resposta:** BUG CORRIGIDO.
**Causa:** O código Python (`runner.py`) não mapeava os campos `login_operador`, `login_responsavel` e `login_vendedor` nos builders de snapshot, mesmo quando o SQL retornava esses dados. Além disso, faltava o `SELECT u.login AS login_operador` na query `get_turno_snapshot`.
**Fix:** Aplicado em `queries.py` + `runner.py`. Após rebuild, todos os snapshots trarão login preenchido (quando disponível no banco).
**Ref:** `docs/ANALISE_TURNOS_E_LOGIN_NULL.md`

### P1.5 - Unicidade de `login`
**Resposta:** O agente não garante unicidade.
**Logica:** O agente lê a string crua do banco. Se houver duplicidade ou logins iguais em lojas diferentes, será enviado igual. O backend deve tratar namespace se necessário (ex: assumir escopo global ou por loja).

### P1.6 - Invariante `ops` vs `vendas`
**Resposta:** Sim, `ops.count` >= `len(vendas)`.
**Exceção:** Uma operação válida (`op=1`, `cancelado=0`) que, por erro de integridade do banco, não tenha itens na tabela `item_operacao_pdv`, aparecerá em `ops.ids` mas será descartada na montagem de `vendas[]` (inner join implícito na lógica de itens).

---

## 5) Perguntas P2 (operacao e evolucao)

### P2.1 - Volume e backlog
**Resposta:** Payload único.
**Comportamento:** O agente tenta pegar tudo na janela. Se a janela for grande (backlog), o payload cresce.
**Estimativa:**
- 2h offline: ~12 janelas acumuladas em uma (se `window_calculator` expandir). Tamanho estimado: 100-500KB (texto gzipa bem).
- 24h: Pode chegar a MBs. O Python lida bem, o limite será o timeout do POST (padrão 30s).

### P2.2 - Taxonomia de warnings
**Resposta:** Formato atual é lista de strings (`list[str]`).
**Strings Atuais:**
1. `GESTAO_DB_FAILURE: <erro>` (falha ao conectar no banco Loja)
2. `Vendedor NULL encontrado em X cupom(s)`
3. `Meio de pagamento NULL encontrado`
**Evolução:** V3.1 mantém lista de strings. Migração para chave/descrição fica para v3.2+.

### P2.3 - Breaking changes
**Resposta:** Sem breaking changes planejadas para v3.1.
**Campos novos:** `cnpj` e `login` entram como opcionais no schema (mas populados se disponíveis).
