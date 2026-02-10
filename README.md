# PDV Sync Agent v1.1.0

Agente de sincronização que roda silenciosamente no PDV (ponto de venda), extrai dados de vendas do banco **HiperPdv** (SQL Server) e envia para a **API central** via webhook — a cada N minutos, de forma incremental.

---

## Arquitetura Geral

```
┌─────────────────────┐          ┌──────────────┐          ┌───────────────┐
│  SQL Server Local   │──READ───▶│  PDV Sync    │──POST───▶│  Webhook API  │
│  (HiperPdv)         │          │  Agent       │          │  (Central)    │
│                     │          │              │          │               │
│  operacao_pdv       │          │  --loop      │          │  Recebe JSON  │
│  item_operacao_pdv  │          │  a cada 10m  │          │  com vendas   │
│  finalizador_*      │          │              │          │               │
│  turno              │          │  Outbox p/   │          │               │
│  ponto_venda        │          │  offline     │          │               │
│  usuario            │          │              │          │               │
└─────────────────────┘          └──────────────┘          └───────────────┘
```

---

## Fluxo de Sincronização

```
1. Inicia (boot ou manual)
2. Processa outbox (payloads que falharam antes)
3. Calcula janela de tempo: [last_sync_to → agora]
4. Consulta SQL Server:
   a. IDs de operações válidas na janela
   b. Vendas agrupadas por vendedor (CTE)
   c. Pagamentos agrupados por meio (CTE)
   d. Info da loja e turno atual
5. Se NÃO há vendas novas → pula o POST (v1.1+)
6. Se HÁ vendas → monta JSON + envia POST
7. Se POST falhar → salva no outbox (retry automático)
8. Avança o ponteiro last_sync_to
9. Aguarda N minutos (modo --loop) e volta ao 2
```

---

## Tabelas do Banco (HiperPdv)

### `dbo.operacao_pdv` — Cupons/Operações

Tabela central. Cada linha = 1 cupom fiscal / venda.

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (PK) | Identificador único, vai no `ops.ids[]` |
| `id_ponto_venda` | int (FK) | Filtro por loja |
| `id_turno` | uniqueidentifier (FK) | Associa ao turno aberto |
| `id_usuario` | int (FK) | Operador do caixa |
| `data_hora_inicio` | datetime | Quando o cupom foi aberto |
| `data_hora_termino` | datetime | **⭐ Campo-chave da janela de sync** |
| `operacao` | int | `1` = venda (filtro: `operacao = 1`) |
| `cancelado` | bit | `0` = válido (filtro: `cancelado = 0`) |

**Filtros aplicados em TODAS as queries:**
```sql
WHERE operacao = 1           -- Somente vendas
  AND cancelado = 0          -- Não cancelados
  AND data_hora_termino IS NOT NULL  -- Finalizados
  AND data_hora_termino >= @dt_from
  AND data_hora_termino <  @dt_to
```

---

### `dbo.item_operacao_pdv` — Itens do Cupom

Cada linha = 1 item vendido dentro de um cupom.

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (FK) | JOIN com `operacao_pdv` |
| `id_usuario_vendedor` | int (FK) | Vendedor que registrou o item |
| `valor_total_liquido` | decimal | **⭐ Valor usado na soma de vendas** |

**Agregação por vendedor:**
```sql
SUM(ISNULL(it.valor_total_liquido, 0)) AS total_vendido
COUNT(DISTINCT ops.id_operacao)         AS qtd_cupons
```

---

### `dbo.finalizador_operacao_pdv` — Pagamentos do Cupom

Cada linha = 1 forma de pagamento usada em um cupom.

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (FK) | JOIN com `operacao_pdv` |
| `id_finalizador` | int (FK) | Tipo de pagamento (dinheiro, cartão, etc.) |
| `valor` | decimal | **⭐ Valor pago nessa forma** |

**Agregação por meio de pagamento:**
```sql
SUM(ISNULL(fo.valor, 0)) AS total_pago
```

---

### `dbo.finalizador_pdv` — Cadastro de Meios de Pagamento

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_finalizador` | int (PK) | JOIN com `finalizador_operacao_pdv` |
| `nome` ou `descricao` | varchar | Nome legível (ex: "Dinheiro", "Cartão Crédito") |

> O agent detecta automaticamente se a coluna se chama `nome` ou `descricao`.

---

### `dbo.turno` — Turnos/Caixas

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_turno` | uniqueidentifier (PK) | Identificador do turno |
| `id_ponto_venda` | int (FK) | Filtro por loja |
| `id_usuario` | int (FK) | Operador que abriu o turno |
| `sequencial` | int | Número sequencial do turno |
| `fechado` | bit | Se o caixa já foi fechado |
| `data_hora_inicio` | datetime | Abertura do caixa |
| `data_hora_termino` | datetime | Fechamento (NULL se aberto) |

**Query:** Pega o `TOP 1` mais recente para o `id_ponto_venda`, ordenado por `data_hora_inicio DESC`.

---

### `dbo.ponto_venda` — Cadastro da Loja

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_ponto_venda` | int (PK) | Identificador da loja |
| `apelido` / `nome` / `descricao` | varchar | Nome legível (detectado automaticamente) |

---

### `dbo.usuario` — Cadastro de Usuários

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_usuario` | int (PK) | FK dos vendedores |
| `nome` | varchar | Nome legível do vendedor |

---

## Estrutura do JSON (Payload)

Cada POST enviado ao webhook contém este JSON:

```json
{
  "agent": {
    "version": "1.1.0",
    "machine": "DESKTOP-LOJA01",
    "sent_at": "2026-02-10T00:15:00"
  },
  "store": {
    "id_ponto_venda": 10,
    "nome": "Loja 1 - MC Komprão Centro TJ",
    "alias": "TIJUCAS-01"
  },
  "window": {
    "from": "2026-02-10T00:05:00",
    "to": "2026-02-10T00:15:00",
    "minutes": 10
  },
  "turno": {
    "id_turno": "6A91E9F2-FF8C-4E40-BA90-8BF04B889A57",
    "sequencial": 1,
    "fechado": false,
    "data_hora_inicio": "2026-02-10T08:00:00",
    "data_hora_termino": null,
    "id_usuario_operador": 5
  },
  "ops": {
    "count": 3,
    "ids": [1001, 1002, 1003]
  },
  "sales": {
    "by_vendor": [
      {
        "id_usuario": 12,
        "nome": "Maria Silva",
        "qtd_cupons": 2,
        "total_vendido": 250.50
      },
      {
        "id_usuario": 8,
        "nome": "João Santos",
        "qtd_cupons": 1,
        "total_vendido": 89.90
      }
    ],
    "by_payment": [
      {
        "id_finalizador": 1,
        "meio": "Dinheiro",
        "total": 150.00
      },
      {
        "id_finalizador": 3,
        "meio": "Cartão Crédito",
        "total": 190.40
      }
    ]
  },
  "integrity": {
    "sync_id": "a1b2c3d4e5f6...",
    "warnings": []
  }
}
```

### Detalhamento dos Campos

| Seção | Campo | Descrição |
|-------|-------|-----------|
| `agent.version` | string | Versão do agente (ex: `1.1.0`) |
| `agent.machine` | string | Hostname do computador |
| `agent.sent_at` | datetime | Timestamp do envio |
| `store.id_ponto_venda` | int | ID da loja no HiperPdv |
| `store.nome` | string | Nome cadastrado no banco |
| `store.alias` | string | Apelido configurado no `.env` |
| `window.from` | datetime | Início da janela de sync |
| `window.to` | datetime | Fim da janela de sync |
| `window.minutes` | int | Largura da janela (config) |
| `turno.id_turno` | GUID | ID do turno/caixa atual |
| `turno.sequencial` | int | Número sequencial do turno |
| `turno.fechado` | bool | Se o caixa já foi fechado |
| `ops.count` | int | Quantidade de cupons na janela |
| `ops.ids` | int[] | IDs dos cupons (para deduplicação) |
| `sales.by_vendor[].id_usuario` | int | ID do vendedor |
| `sales.by_vendor[].nome` | string | Nome do vendedor |
| `sales.by_vendor[].qtd_cupons` | int | Quantos cupons esse vendedor fez |
| `sales.by_vendor[].total_vendido` | decimal | `SUM(valor_total_liquido)` dos itens |
| `sales.by_payment[].id_finalizador` | int | ID do meio de pagamento |
| `sales.by_payment[].meio` | string | Nome do meio (Dinheiro, Cartão, etc.) |
| `sales.by_payment[].total` | decimal | `SUM(valor)` dos pagamentos |
| `integrity.sync_id` | string | SHA256 de `store_id + from + to` (idempotência) |
| `integrity.warnings` | string[] | Alertas de qualidade (ex: vendedor NULL) |

### Lógica das Somas

| O que é somado | Tabela.Coluna | Função SQL | Agrupamento |
|----------------|---------------|------------|-------------|
| Total vendido por vendedor | `item_operacao_pdv.valor_total_liquido` | `SUM(ISNULL(valor_total_liquido, 0))` | `id_usuario_vendedor` |
| Qtd cupons por vendedor | `operacao_pdv.id_operacao` | `COUNT(DISTINCT id_operacao)` | `id_usuario_vendedor` |
| Total pago por meio | `finalizador_operacao_pdv.valor` | `SUM(ISNULL(valor, 0))` | `id_finalizador` |

> **CTEs:** Todas as queries de agregação usam CTEs (`WITH ops AS (...)`) para evitar multiplicação N×M quando um cupom tem múltiplos itens E múltiplos pagamentos.

---

## Comportamento Chave

### Sem vendas? → Sem POST
Quando não há operações novas na janela de tempo, o agente **pula o POST** para economizar tráfego. O ponteiro `last_sync_to` ainda é avançado para não reprocessar a mesma janela.

### Outbox (Modo Offline)
Se o POST falhar (network, timeout, API 5xx), o payload é salvo localmente em `outbox/`. Na próxima execução, os payloads pendentes são reenviados antes de processar novos dados.

### Idempotência
O `sync_id` é um SHA256 determinístico de `store_id + from + to`. Se o mesmo payload for enviado duas vezes, o servidor pode detectar e ignorar a duplicata.

### Retry com Backoff
O envio HTTP usa **tenacity** com 3 tentativas e backoff exponencial (2s → 4s → max 30s) para erros de rede.

---

## Estrutura de Arquivos

```
pdv-sync-agent/
├── agent.py              # Entry point (--loop, --doctor, --version)
├── build.bat             # Compila .exe com PyInstaller
├── src/
│   ├── __init__.py       # __version__ = "1.1.0"
│   ├── settings.py       # Config (.env), ODBC detect, SQL encrypt
│   ├── db.py             # Conexão pyodbc, erros humanos
│   ├── queries.py        # 4 queries SQL (operações, vendas, pagamentos, turno)
│   ├── payload.py        # 7 modelos Pydantic (JSON do webhook)
│   ├── runner.py         # Orquestração: window → query → build → send
│   ├── sender.py         # HTTP POST + outbox + retry (tenacity)
│   └── state.py          # state.json (last_sync_to incremental)
├── deploy/
│   ├── install.bat       # Instalador para lojas (admin, ODBC, task)
│   ├── uninstall.bat     # Remove binário e task (preserva dados)
│   ├── update.bat        # Atualiza com hash + rollback
│   ├── task.template.xml # Task Scheduler (boot, restart, SYSTEM)
│   └── config.template.env # Template de .env para produção
└── config/
    └── config.example.env # Exemplo de configuração para dev
```

---

## Pré-Instalação: Reconhecimento via PowerShell

Rode estes comandos **no PowerShell da máquina do cliente** (não precisa de SSMS nem instalar nada):

### Passo 1 — Descobrir a instância SQL Server

```powershell
Get-Service | Where-Object { $_.Name -like "MSSQL*" } | Format-Table Name, DisplayName, Status
```

O resultado mostra o nome da instância. Exemplo:
```
Name          DisplayName            Status
----          -----------            ------
MSSQL$HIPER   SQL Server (HIPER)    Running     ← Instância = HIPER
```

> Se aparecer `MSSQL$SQLEXPRESS`, a instância é `SQLEXPRESS`. Use esse nome nos comandos abaixo.

### Passo 2 — Verificar o ODBC Driver instalado

```powershell
Get-ItemProperty "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\*" | Where-Object { $_.PSChildName -like "*SQL Server*" } | Select-Object PSChildName
```

Deve mostrar `ODBC Driver 17 for SQL Server` ou `ODBC Driver 18 for SQL Server`.

### Passo 3 — Descobrir o Store ID (id_ponto_venda)

```powershell
sqlcmd -S "localhost\HIPER" -d HiperPdv -E -C -Q "SELECT id_ponto_venda, apelido FROM dbo.ponto_venda" -W
```

> **⚠️ Importante:** O `-C` é **obrigatório** com Driver 18 (trust certificate). Troque `HIPER` pelo nome da instância do passo 1.

Resultado esperado:
```
id_ponto_venda apelido
-------------- -------
2              Loja 6 - MC Gov Celso Ramos
10             Loja 1 - MC Komprão Centro TJ   ← Use este ID no .env
13             Loja 12 - MC Porto Belo
```

### Passo 4 — Verificar se as tabelas do agent existem

```powershell
sqlcmd -S "localhost\HIPER" -d HiperPdv -E -C -Q "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('operacao_pdv','item_operacao_pdv','finalizador_operacao_pdv','finalizador_pdv','turno','ponto_venda','usuario') ORDER BY TABLE_NAME" -W
```

Devem aparecer as **7 tabelas**. Se faltar alguma, o banco pode ter schema diferente.

### Passo 5 — Verificar últimas vendas

```powershell
sqlcmd -S "localhost\HIPER" -d HiperPdv -E -C -Q "SELECT TOP 5 id_operacao, id_ponto_venda, data_hora_termino FROM dbo.operacao_pdv WHERE operacao=1 AND cancelado=0 ORDER BY data_hora_termino DESC" -W
```

Valida que existem vendas recentes e o `data_hora_termino` está sendo preenchido.

### Passo 6 — Ver turno atual

```powershell
sqlcmd -S "localhost\HIPER" -d HiperPdv -E -C -Q "SELECT TOP 1 id_turno, sequencial, fechado, data_hora_inicio FROM dbo.turno ORDER BY data_hora_inicio DESC" -W
```

---

## Instalação (Lojas)

Com as informações coletadas acima, proceda:

```
1. Copiar PDVSyncAgent_v1.1.0.zip para o PC da loja
2. Extrair em qualquer pasta temporária
3. Abrir PowerShell como Administrador
4. Executar install.bat
5. Após instalação, editar o .env:
   - STORE_ID_PONTO_VENDA = ID do passo 3
   - STORE_ALIAS = apelido livre (ex: komprao-centro-tj-01)
   - SQL_SERVER_INSTANCE = nome do passo 1
   - SQL_TRUSTED_CONNECTION = true (Windows Auth) ou false (SQL Auth)
   - API_ENDPOINT = URL do webhook
   - API_TOKEN = token de autenticação
6. O instalador automaticamente:
   - Verifica ODBC Driver (instala se necessário)
   - Copia binário para C:\Program Files\PDVSyncAgent
   - Cria config em C:\ProgramData\PDVSyncAgent\.env
   - Registra tarefa no Agendador do Windows
   - Roda --doctor para validar tudo
   - Inicia o agente
```

---

## Comandos Úteis

```powershell
# Versão
& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --version

# Diagnóstico completo
& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --doctor --config "C:\ProgramData\PDVSyncAgent\.env"

# Status da tarefa agendada
schtasks /query /tn "PDVSyncAgent" /fo LIST

# Ver logs
Get-Content "C:\ProgramData\PDVSyncAgent\logs\agent.log" -Tail 30

# Parar/iniciar
schtasks /end /tn "PDVSyncAgent"
schtasks /run /tn "PDVSyncAgent"
```

---

## Configuração

Arquivo: `C:\ProgramData\PDVSyncAgent\.env`

| Variável | Default | Descrição |
|----------|---------|-----------|
| `SQL_SERVER_HOST` | `localhost` | Host do SQL Server |
| `SQL_SERVER_INSTANCE` | `HIPER` | Instância nomeada |
| `SQL_DATABASE` | `HiperPdv` | Banco de dados |
| `SQL_DRIVER` | `auto` | ODBC driver (auto-detecta 18→17→13) |
| `SQL_ENCRYPT` | `no` | Encrypt conexão (Driver 18: `no` para localhost) |
| `SQL_TRUST_SERVER_CERT` | `yes` | Confiar certificado do servidor |
| `SQL_TRUSTED_CONNECTION` | `true/false` | `true` = Windows Auth, `false` = SQL Auth |
| `SQL_USERNAME` | - | Usuário SQL (quando SQL Auth) |
| `SQL_PASSWORD` | - | Senha SQL |
| `STORE_ID_PONTO_VENDA` | - | ID da loja no HiperPdv |
| `STORE_ALIAS` | - | Apelido legível |
| `API_ENDPOINT` | - | URL do webhook |
| `API_TOKEN` | - | Token Bearer |
| `SYNC_WINDOW_MINUTES` | `10` | Intervalo de sync (minutos) |
| `LOG_ROTATION` | `10 MB` | Rotação do log |
| `LOG_RETENTION` | `30 days` | Retenção dos logs |
