# PDV Sync Agent v2.0

Agente de sincronização que roda silenciosamente no PDV (ponto de venda), extrai dados detalhados de vendas do banco **HiperPdv** (SQL Server) e envia para a **API central** via webhook — a cada 10 minutos, de forma incremental.

## O que mudou na v2.0

| Feature | v1.x | v2.0 |
|---------|------|------|
| Turnos | 1 turno atual | Array com todos os turnos da janela |
| Vendas | Apenas resumo agregado | **Extrato individual** (itens + pagamentos) |
| Fechamento de caixa | Não coletado | Valores declarados pelo operador (op=9) |
| Falta de caixa | Não coletado | Diferença sistema vs declarado (op=4) |
| Instalador | Manual (.bat + editar .env) | **Automático** (PowerShell, ODBC, SQL user, .env) |
| SQL Auth | Precisa criar manualmente | Criação automática do user `pdv_sync` |
| Validação | Apenas `--doctor` manual | Doctor + task SYSTEM automática |

---

## Arquitetura

```
┌─────────────────────┐          ┌──────────────┐          ┌───────────────┐
│  SQL Server Local   │──READ───▶│  PDV Sync    │──POST───▶│  Webhook API  │
│  (HiperPdv)         │          │  Agent v2.0  │          │  (Central)    │
│                     │          │              │          │               │
│  operacao_pdv       │          │  --loop      │          │  Recebe JSON  │
│  item_operacao_pdv  │          │  a cada 10m  │          │  com extrato  │
│  finalizador_*      │          │              │          │  de vendas    │
│  turno              │          │  Outbox p/   │          │               │
│  ponto_venda        │          │  offline     │          │               │
│  usuario            │          │              │          │               │
└─────────────────────┘          └──────────────┘          └───────────────┘
```

---

## Fluxo de Sincronização

```
1. Inicia (boot via Task Scheduler como SYSTEM)
2. Processa outbox (payloads que falharam antes)
3. Calcula janela de tempo: [last_sync_to → agora]
4. Consulta SQL Server:
   a. IDs de operações válidas na janela
   b. Turnos com atividade na janela (op=1)
   c. Para cada turno: totais, fechamento (op=9), falta (op=4)
   d. Vendas individuais: itens + pagamentos por cupom
   e. Resumo agregado por vendedor e por meio de pagamento
   f. Info da loja
5. Se NÃO há vendas novas → pula o POST
6. Se HÁ vendas → monta JSON v2.0 + envia POST
7. Se POST falhar → salva no outbox (retry automático)
8. Avança o ponteiro last_sync_to
9. Aguarda 10 minutos e volta ao 2
```

---

## Tipos de Operação (HiperPdv)

| Código | Tipo | Usado Para |
|--------|------|------------|
| 0 | Abertura de Caixa | (legacy, não coletado) |
| **1** | **Venda** | **Dados principais — filtro em todas as queries** |
| 3 | Sangria | Lançamento de falta no Caixa |
| **4** | **Falta de Caixa** | **Diferença sistema vs declarado (v2.0)** |
| 8 | Raro | Não usado |
| **9** | **Fechamento de Turno** | **Valores declarados pelo operador (v2.0)** |

---

## Tabelas do Banco (HiperPdv)

### `dbo.operacao_pdv` — Cupons/Operações

Tabela central. Cada linha = 1 operação. Vendas usam `operacao = 1`.

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (PK) | Identificador único, vai no `ops.ids[]` |
| `id_ponto_venda` | int (FK) | Filtro por loja |
| `id_turno` | uniqueidentifier (FK) | Associa ao turno |
| `id_usuario` | int (FK) | Operador do caixa |
| `data_hora_inicio` | datetime | Abertura do cupom |
| `data_hora_termino` | datetime | **⭐ Campo-chave da janela de sync** |
| `operacao` | int | Tipo de operação (1, 4, 9, etc.) |
| `cancelado` | bit | `0` = válido |

**Filtros aplicados nas queries de vendas:**
```sql
WHERE operacao = 1
  AND cancelado = 0
  AND data_hora_termino IS NOT NULL
  AND data_hora_termino >= @dt_from
  AND data_hora_termino <  @dt_to
```

### `dbo.item_operacao_pdv` — Itens do Cupom

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (FK) | JOIN com operacao_pdv |
| `id_produto` | int (FK) | ID do produto |
| `id_usuario_vendedor` | int (FK) | Vendedor que registrou |
| `valor_total_liquido` | decimal | **⭐ Valor do item (usado em somas)** |
| `quantidade` | decimal | Quantidade vendida |
| `preco_unitario` | decimal | Preço unitário |
| `desconto` | decimal | Desconto aplicado |
| `cancelado` | bit | Filtro: `cancelado = 0` |

### `dbo.finalizador_operacao_pdv` — Pagamentos do Cupom

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_operacao` | int (FK) | JOIN com operacao_pdv |
| `id_finalizador` | int (FK) | Tipo de pagamento |
| `valor` | decimal | **⭐ Valor pago** |
| `troco` | decimal | Troco (v2.0) |
| `parcelas` | int | Número de parcelas (v2.0) |

### `dbo.finalizador_pdv` — Cadastro de Meios de Pagamento

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_finalizador` | int (PK) | JOIN para nome legível |
| `nome` / `descricao` | varchar | Ex: "Dinheiro", "Cartão Crédito" |

> O agent detecta automaticamente se a coluna se chama `nome` ou `descricao`.

### `dbo.turno` — Turnos/Caixas

| Coluna | Tipo | Uso no Agent |
|--------|------|-------------|
| `id_turno` | uniqueidentifier (PK) | Identificador do turno |
| `id_ponto_venda` | int (FK) | Filtro por loja |
| `id_usuario` | int (FK) | Operador que abriu o turno |
| `sequencial` | int | Número sequencial |
| `fechado` | bit | Se o caixa já foi fechado |
| `data_hora_inicio` | datetime | Abertura do caixa |
| `data_hora_termino` | datetime | Fechamento (NULL se aberto) |

### `dbo.ponto_venda` — Lojas

| Coluna | Tipo | Uso | 
|--------|------|-----|
| `id_ponto_venda` | int (PK) | ID da loja |
| `apelido` / `nome` / `descricao` | varchar | Nome legível |

### `dbo.usuario` — Usuários/Operadores

| Coluna | Tipo | Uso |
|--------|------|-----|
| `id_usuario` | int (PK) | FK de vendedores/operadores |
| `nome` | varchar | Nome legível |

### `dbo.produto` — Produtos

| Coluna | Tipo | Uso (v2.0) |
|--------|------|------------|
| `id_produto` | int (PK) | ID do produto |
| `nome` | varchar | Nome do produto |
| `codigo_barras` | varchar | Código de barras |

---

## Estrutura do JSON v2.0 (Payload)

```json
{
  "agent": {
    "version": "2.0.0",
    "machine": "DESKTOP-LOJA01",
    "sent_at": "2026-02-10T21:12:56"
  },
  "store": {
    "id_ponto_venda": 10,
    "nome": "Loja 1 - MC Komprão Centro TJ",
    "alias": "tijucas-01"
  },
  "window": {
    "from": "2026-02-10T21:02:56",
    "to": "2026-02-10T21:12:56",
    "minutes": 10
  },
  "turnos": [
    {
      "id_turno": "6A91E9F2-FF8C-4E40-BA90-8BF04B889A57",
      "sequencial": 42,
      "fechado": false,
      "data_hora_inicio": "2026-02-10T08:00:00",
      "data_hora_termino": null,
      "operador": {
        "id_usuario": 5,
        "nome": "Carlos Ferreira"
      },
      "totais_sistema": {
        "total": 1250.50,
        "qtd_vendas": 15,
        "por_pagamento": [
          { "id_finalizador": 1, "meio": "Dinheiro", "total": 450.00, "qtd_vendas": 6 },
          { "id_finalizador": 3, "meio": "Cartão Crédito", "total": 800.50, "qtd_vendas": 9 }
        ]
      },
      "fechamento_declarado": {
        "total": 1240.00,
        "por_pagamento": [
          { "id_finalizador": 1, "meio": "Dinheiro", "total": 440.00 },
          { "id_finalizador": 3, "meio": "Cartão Crédito", "total": 800.00 }
        ]
      },
      "falta_caixa": {
        "total": 10.50,
        "por_pagamento": [
          { "id_finalizador": 1, "meio": "Dinheiro", "total": 10.00 },
          { "id_finalizador": 3, "meio": "Cartão Crédito", "total": 0.50 }
        ]
      }
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
          "qtd": 2,
          "preco_unit": 39.95,
          "total": 79.90,
          "desconto": 0.00,
          "vendedor": { "id_usuario": 12, "nome": "Maria Silva" }
        },
        {
          "id_produto": 5678,
          "codigo_barras": "7895678901234",
          "nome": "Película Galaxy S24",
          "qtd": 1,
          "preco_unit": 10.00,
          "total": 10.00,
          "desconto": 0.00,
          "vendedor": { "id_usuario": 12, "nome": "Maria Silva" }
        }
      ],
      "pagamentos": [
        {
          "id_finalizador": 3,
          "meio": "Cartão Crédito",
          "valor": 89.90,
          "troco": 0.00,
          "parcelas": 2
        }
      ]
    }
  ],
  "resumo": {
    "by_vendor": [
      {
        "id_usuario": 12,
        "nome": "Maria Silva",
        "qtd_cupons": 2,
        "total_vendido": 250.50
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
  "ops": {
    "count": 3,
    "ids": [5001, 5002, 5003]
  },
  "integrity": {
    "sync_id": "a1b2c3d4e5f6...",
    "warnings": []
  }
}
```

### Referência de Campos

| Seção | Campo | Tipo | Descrição |
|-------|-------|------|-----------|
| **agent** | `version` | string | Versão do agente (`2.0.0`) |
| | `machine` | string | Hostname do computador |
| | `sent_at` | datetime | Timestamp do envio |
| **store** | `id_ponto_venda` | int | ID da loja no HiperPdv |
| | `nome` | string | Nome no banco |
| | `alias` | string | Apelido configurado no `.env` |
| **window** | `from` | datetime | Início da janela |
| | `to` | datetime | Fim da janela |
| | `minutes` | int | Largura da janela (config) |
| **turnos[]** | `id_turno` | GUID | ID do turno |
| | `sequencial` | int | Número sequencial |
| | `fechado` | bool | Se já fechou |
| | `operador` | object | `{id_usuario, nome}` |
| | `totais_sistema` | object | Totais calculados das vendas (op=1) |
| | `fechamento_declarado` | object | Valores declarados no fechamento (op=9) |
| | `falta_caixa` | object | Diferença sistema − declarado (op=4) |
| **vendas[]** | `id_operacao` | int | ID do cupom |
| | `data_hora` | datetime | Data/hora da venda |
| | `id_turno` | GUID | Turno associado |
| | `total` | decimal | Valor total da venda |
| | `itens[]` | array | Produtos vendidos |
| | `pagamentos[]` | array | Formas de pagamento |
| **vendas[].itens[]** | `id_produto` | int | ID do produto |
| | `codigo_barras` | string | EAN/código de barras |
| | `nome` | string | Nome do produto |
| | `qtd` | decimal | Quantidade |
| | `preco_unit` | decimal | Preço unitário |
| | `total` | decimal | Subtotal do item |
| | `desconto` | decimal | Desconto aplicado |
| | `vendedor` | object | `{id_usuario, nome}` |
| **vendas[].pagamentos[]** | `id_finalizador` | int | Tipo de pagamento |
| | `meio` | string | Nome ("Dinheiro", etc.) |
| | `valor` | decimal | Valor pago |
| | `troco` | decimal | Troco |
| | `parcelas` | int | Número de parcelas |
| **resumo** | `by_vendor[]` | array | Agregado por vendedor |
| | `by_payment[]` | array | Agregado por meio de pagamento |
| **ops** | `count` | int | Qtd de cupons na janela |
| | `ids` | int[] | IDs para deduplicação |
| **integrity** | `sync_id` | string | SHA256 determinístico |
| | `warnings` | string[] | Alertas de qualidade |

### Conferência: Turno vs Sistema

O JSON permite cruzar 3 valores por meio de pagamento:

| Dado | Fonte | Campo no JSON |
|------|-------|---------------|
| Total do sistema | Soma das vendas (op=1) | `turno.totais_sistema.por_pagamento[].total` |
| Declarado pelo operador | Fechamento (op=9) | `turno.fechamento_declarado.por_pagamento[].total` |
| Falta de caixa | Diferença (op=4) | `turno.falta_caixa.por_pagamento[].total` |

> **Regra:** `falta = total_sistema - fechamento_declarado`

---

## Queries SQL

### Queries de Consulta (12 métodos no `queries.py`)

| Método | Operação | Descrição |
|--------|----------|-----------|
| `get_store_info` | — | Info da loja (nome, apelido) |
| `get_current_turno` | — | Turno mais recente (TOP 1) |
| `get_turnos_in_window` | op=1 | Turnos com vendas na janela |
| `get_turno_closure_values` | **op=9** | Valores declarados no fechamento |
| `get_turno_shortage_values` | **op=4** | Falta de caixa |
| `get_operations_in_window` | op=1 | Operações válidas na janela |
| `get_sales_by_vendor` | op=1 | Vendas agrupadas por vendedor (CTE) |
| `get_payments_by_method` | op=1 | Pagamentos agrupados por meio (CTE) |
| `get_payments_by_method_for_turno` | op=1 | Pagamentos por meio por turno específico |
| `get_operation_ids` | op=1 | IDs para deduplicação |
| `get_sale_items` | op=1 | Itens individuais (produto, vendedor) |
| `get_sale_payments` | op=1 | Pagamentos individuais (parcelas, troco) |

### CTEs (Common Table Expressions)

Todas as queries de agregação usam CTEs para evitar multiplicação N×M:

```sql
-- Exemplo: vendas por vendedor
WITH ops AS (
    SELECT id_operacao FROM operacao_pdv
    WHERE operacao = 1 AND cancelado = 0
      AND data_hora_termino >= @dt_from
      AND data_hora_termino <  @dt_to
)
SELECT u.id_usuario, u.nome,
       COUNT(DISTINCT ops.id_operacao) AS qtd_cupons,
       SUM(ISNULL(it.valor_total_liquido, 0)) AS total_vendido
FROM ops
JOIN item_operacao_pdv it ON it.id_operacao = ops.id_operacao AND it.cancelado = 0
LEFT JOIN usuario u ON u.id_usuario = it.id_usuario_vendedor
GROUP BY u.id_usuario, u.nome
```

### Queries de Validação (PowerShell, sem sqlcmd)

```powershell
# Conectar ao SQL Server
$conn = New-Object System.Data.SqlClient.SqlConnection('Server=localhost\HIPER;Database=HiperPdv;User Id=pdv_sync;Password=PdvSync2026!;TrustServerCertificate=True;')
$conn.Open()
$cmd = $conn.CreateCommand()

# Listar lojas
$cmd.CommandText = 'SELECT id_ponto_venda, apelido FROM dbo.ponto_venda'
$r = $cmd.ExecuteReader(); while ($r.Read()) { "[$($r[0])] $($r[1])" }; $r.Close()

# Últimas 5 vendas
$cmd.CommandText = 'SELECT TOP 5 id_operacao, data_hora_termino FROM operacao_pdv WHERE operacao=1 AND cancelado=0 ORDER BY data_hora_termino DESC'
$r = $cmd.ExecuteReader(); while ($r.Read()) { "$($r[0]) | $($r[1])" }; $r.Close()

# Turno atual
$cmd.CommandText = 'SELECT TOP 1 id_turno, sequencial, fechado FROM turno ORDER BY data_hora_inicio DESC'
$r = $cmd.ExecuteReader(); while ($r.Read()) { "Turno $($r[1]) | Fechado: $($r[2])" }; $r.Close()

# Vendas de hoje por vendedor
$cmd.CommandText = "SELECT u.nome, COUNT(DISTINCT o.id_operacao) as cupons, SUM(ISNULL(it.valor_total_liquido,0)) as total FROM operacao_pdv o JOIN item_operacao_pdv it ON it.id_operacao=o.id_operacao AND it.cancelado=0 LEFT JOIN usuario u ON u.id_usuario=it.id_usuario_vendedor WHERE o.operacao=1 AND o.cancelado=0 AND CAST(o.data_hora_termino AS DATE)=CAST(GETDATE() AS DATE) GROUP BY u.nome"
$r = $cmd.ExecuteReader(); while ($r.Read()) { "$($r[0]) | $($r[1]) cupons | R$ $($r[2])" }; $r.Close()

$conn.Close()
```

---

## Comportamento Chave

### Sem vendas → Sem POST
Quando não há operações novas, o agente pula o POST. O ponteiro `last_sync_to` ainda avança.

### Outbox (Modo Offline)
Se o POST falhar (rede, timeout, API 5xx), o payload é salvo em `outbox/`. Na próxima execução, pendentes são reenviados primeiro.

### Idempotência
O `sync_id` é SHA256 determinístico de `store_id + from + to`. O servidor pode ignorar duplicatas.

### Retry com Backoff
HTTP POST usa **tenacity** com 3 tentativas e backoff exponencial (2s → 4s → max 30s).

### Task Scheduler (SYSTEM)
O agente roda como `NT AUTHORITY\SYSTEM` via Task Scheduler. Inicia no boot com delay de 30s. Em caso de falha, reinicia em 1 minuto (até 999x).

---

## Estrutura de Arquivos

```
pdv-sync-agent/
├── agent.py              # Entry point (--loop, --doctor, --version)
├── build.bat             # Compila .exe com PyInstaller
├── src/
│   ├── __init__.py       # __version__ = "2.0.0"
│   ├── settings.py       # Config (.env), ODBC detect, SQL encrypt
│   ├── db.py             # Conexão pyodbc, erros amigáveis
│   ├── queries.py        # 12 queries SQL (turnos, vendas, items, payments)
│   ├── payload.py        # 15 modelos Pydantic (JSON do webhook v2.0)
│   ├── runner.py         # Orquestração: window → query → build → send
│   ├── sender.py         # HTTP POST + outbox + retry (tenacity)
│   └── state.py          # state.json (last_sync_to incremental)
├── deploy/
│   ├── install.bat       # Launcher do instalador (pede Admin)
│   ├── install.ps1       # Instalador automático PowerShell v2.0
│   ├── uninstall.bat     # Remove binário e task (preserva dados)
│   ├── update.bat        # Atualiza com hash + rollback
│   ├── task.template.xml # Task Scheduler (boot, restart, SYSTEM)
│   ├── config.template.env # Template de .env
│   └── GUIA_INSTALACAO.md  # Guia passo a passo
└── config/
    └── config.example.env # Exemplo de configuração (dev)
```

---

## Instalação (Automática via PowerShell)

### OneClick (1 comando)

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; $url = 'https://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip'; $zip = "$env:TEMP\PDVSyncAgent.zip"; $dest = "$env:TEMP\PDVSyncAgent"; Invoke-WebRequest $url -OutFile $zip; Expand-Archive $zip $dest -Force; & "$dest\install.bat"
```

### O instalador (`install.ps1`) faz automaticamente:

| Etapa | Ação |
|-------|------|
| 1/8 | Verifica/instala ODBC Driver 17 (silencioso) |
| 2/8 | Detecta instância SQL Server |
| 3/8 | Cria user `pdv_sync` com `db_datareader` |
| 4/8 | Lista lojas do banco para seleção |
| 5/8 | Gera `.env` completo |
| 6/8 | Copia binários para `C:\Program Files\PDVSyncAgent` |
| 7/8 | Cria Task Scheduler (SYSTEM, boot, restart) |
| 8/8 | Valida com `--doctor` + roda task como SYSTEM |

### Pré-requisito: Mixed Mode no SQL Server

Se o SQL Server estiver em "Windows Auth Only", habilite antes:

```powershell
$sqlKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' |
    Where-Object { $_.Name -match 'MSSQL\d+\.' } | Select-Object -First 1
Set-ItemProperty -Path (Join-Path $sqlKey.PSPath 'MSSQLServer') -Name 'LoginMode' -Value 2
Restart-Service 'MSSQL$HIPER' -Force
```

---

## Comandos Úteis

```powershell
# Versão
& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --version

# Diagnóstico completo
& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --doctor --config "C:\ProgramData\PDVSyncAgent\.env"

# Status da tarefa
schtasks /query /tn PDVSyncAgent /fo LIST | Select-String 'Status'

# Ver logs (últimas 30 linhas)
Get-Content "C:\ProgramData\PDVSyncAgent\logs\agent.log" -Tail 30

# Envios com sucesso
Get-Content "C:\ProgramData\PDVSyncAgent\logs\agent.log" -Tail 200 | Select-String 'SUCCESS'

# Último sync
Get-Content "C:\ProgramData\PDVSyncAgent\data\state.json"

# Fila de envio pendente
Get-ChildItem "C:\ProgramData\PDVSyncAgent\data\outbox" | Measure-Object | Select-Object Count

# Parar / Iniciar
schtasks /end /tn PDVSyncAgent
schtasks /run /tn PDVSyncAgent

# Reparar instalação
powershell -ExecutionPolicy Bypass -File install.ps1 -Repair

# Atualizar versão
& "C:\Program Files\PDVSyncAgent\update.bat" https://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip
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
| `SQL_ENCRYPT` | `no` | Encrypt conexão |
| `SQL_TRUST_SERVER_CERT` | `yes` | Confiar certificado |
| `SQL_TRUSTED_CONNECTION` | `false` | `false` = SQL Auth (recomendado em produção) |
| `SQL_USERNAME` | `pdv_sync` | Usuário SQL |
| `SQL_PASSWORD` | `PdvSync2026!` | Senha SQL |
| `STORE_ID_PONTO_VENDA` | — | ID da loja no HiperPdv |
| `STORE_ALIAS` | — | Apelido legível |
| `API_ENDPOINT` | — | URL do webhook |
| `API_TOKEN` | — | Token Bearer |
| `SYNC_WINDOW_MINUTES` | `10` | Intervalo de sync (minutos) |
| `LOG_ROTATION` | `10 MB` | Rotação do log |
| `LOG_RETENTION` | `30 days` | Retenção dos logs |

---

## Caminhos no Sistema

| O quê | Caminho |
|-------|---------|
| Binário | `C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe` |
| Libs | `C:\Program Files\PDVSyncAgent\_internal\` |
| Config | `C:\ProgramData\PDVSyncAgent\.env` |
| Logs | `C:\ProgramData\PDVSyncAgent\logs\agent.log` |
| Doctor | `C:\ProgramData\PDVSyncAgent\logs\doctor.log` |
| State | `C:\ProgramData\PDVSyncAgent\data\state.json` |
| Outbox | `C:\ProgramData\PDVSyncAgent\data\outbox\` |
| Install log | `C:\ProgramData\PDVSyncAgent\logs\install.log` |
| Task XML | `C:\ProgramData\PDVSyncAgent\task.xml` |

---

## Lojas MaisCapinhas

| ID | Loja | Apelido sugerido |
|---|---|---|
| 2 | MC Gov Celso Ramos | `GOV-CELSO-01` |
| 3 | MC Tabuleiro | `TABULEIRO-01` |
| 4 | iTuntz | `ITUNTZ-01` |
| 5 | MC Outlet | `OUTLET-01` |
| 6 | MC Komprão BR Tijucas | `KOMPRAO-BR-01` |
| 7 | MC Mata Atlântica | `MATA-ATL-01` |
| 8 | MC Bombinhas | `BOMBINHAS-01` |
| 9 | MC Morretes | `MORRETES-01` |
| 10 | MC Komprão Centro TJ | `TIJUCAS-01` ✅ |
| 11 | MC P4 | `P4-01` |
| 12 | MC Camboriú Caledônia | `CAMBORIU-01` |
| 13 | MC Porto Belo | `PORTO-BELO-01` |

---

## Troubleshooting

| Problema | Causa | Solução |
|----------|-------|---------|
| Login failed for 'pdv_sync' | SQL Server em Windows Auth Only | Habilitar Mixed Mode (ver seção Instalação) |
| ODBC Driver not found | Driver não instalado | `install.ps1` instala automaticamente |
| Task não inicia | Exe travado por outro processo | `Stop-Process -Name pdv-sync-agent -Force` |
| .env pulado na instalação | Já existe de versão anterior | Usar `-Repair` para reescrever |
| Outbox crescendo | API offline ou erro de rede | Verificar conectividade e status da API |
| Vendedor NULL no JSON | Item sem `id_usuario_vendedor` | Warning no `integrity.warnings[]` |

---

## Build (Desenvolvimento)

```batch
REM 1. Criar venv
python -m venv .venv_build
.venv_build\Scripts\activate

REM 2. Instalar dependências
pip install -r requirements.txt pyinstaller

REM 3. Compilar
pyinstaller --onefile --name pdv-sync-agent --icon deploy\icon.ico agent.py

REM 4. Montar distribuição
copy deploy\install.bat dist\pdv-sync-agent\
copy deploy\install.ps1 dist\pdv-sync-agent\
mkdir dist\pdv-sync-agent\extra
copy msodbcsql.msi dist\pdv-sync-agent\extra\

REM 5. ZIP + SHA256
powershell Compress-Archive -Path dist\pdv-sync-agent\* -DestinationPath PDVSyncAgent_latest.zip -Force
powershell "$h=(Get-FileHash PDVSyncAgent_latest.zip SHA256).Hash; \"$h  PDVSyncAgent_latest.zip\" | Out-File PDVSyncAgent_latest.sha256"
```
