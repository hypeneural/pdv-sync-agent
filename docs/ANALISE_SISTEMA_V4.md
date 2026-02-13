# Análise Detalhada: PDV Sync Agent v4.0

## 1. Visão Geral da Arquitetura (v4.0)

O **PDV Sync Agent v4.0** evoluiu para uma arquitetura "Dual-Database", capaz de extrair e unificar dados de duas fontes distintas presentes no servidor local, garantindo uma visão completa das operações de venda e gestão.

### Fluxo de Dados
1.  **Extract (Extração):**
    *   **Fonte 1:** Banco `HiperPdv` (SQL Server) — Dados de caixa, vendas locais, turnos do frente de caixa.
    *   **Fonte 2 (NOVO):** Banco `Hiper` (SQL Server - Gestão) — Dados de retaguarda, vendas fiscais, notas emitidas pelo ERP e turnos de gestão.
2.  **Transform (Transformação):**
    *   Normalização dos dados de ambas as fontes.
    *   Unificação de modelos (`TurnoDetail`, `SaleDetail`) independente da origem (`HIPER_CAIXA` vs `HIPER_LOJA`).
    *   Deduplicação baseada em IDs de operação + origem.
3.  **Load (Carga):**
    *   Envio via HTTP POST (JSON) para a API Central.
    *   Buffering local (Outbox) em caso de falha.

---

## 2. Stack Tecnológico

*   **Linguagem:** Python 3.10+
*   **Distribuição:** Executável Autocontido (`.exe`) gerado via **PyInstaller**.
*   **Automação:** Windows Task Scheduler (Execução como `NT AUTHORITY\SYSTEM`).
*   **Interface com Banco:** `pyodbc` + ODBC Driver 17 for SQL Server.
*   **Validação de Dados:** Pydantic v2 (Schemas rigorosos para Payload v4).
*   **Resiliência HTTP:** `tenacity` (Retry com Backoff Exponencial) + `requests`.
*   **Scripts de Apoio:** PowerShell Core (Instalação, Update, Diagnóstico).

---

## 3. Versionamento (v4.0)

O sistema utiliza versionamento semântico (`MAJOR.MINOR.PATCH`).
*   **v4.0:** Introdução do suporte multi-banco (`HiperPdv` + `Hiper`).
*   **Payload Schema:** O JSON enviado contém `schema_version`, permitindo que o backend suporte múltiplas versões de agentes simultaneamente.

> **Mecanismo de Update:** O script `update_v4.ps1` implementa um "Smart Update" que detecta a versão instalada, migra automaticamente o arquivo `.env` (adicionando chaves como `SQL_DATABASE_GESTAO`), faz backup completo e rollback automático em caso de falha na inicialização do novo binário.

---

## 4. Comportamento do Sistema e Redundância

### A. Se o computador for desligado
*   **Parada:** O agente para imediatamente. O estado da última sincronização (`last_sync_to`) é persistido atomicamente em `data/state.json`. Nada é perdido.
*   **Retomada (Boot):**
    *   O agente inicia automaticamente 30 segundos após o boot do Windows (Configurado no Task Scheduler).
    *   Ele lê o `last_sync_to`.
    *   Calcula a janela de tempo desde a parada até o momento atual (`now`).
    *   **Catch-up:** Processa e envia todos os dados acumulados durante o tempo desligado em janelas sequenciais (ou única, dependendo da configuração), garantindo que **nenhuma venda seja perdida**.

### B. Se a Internet cair (Offline Mode)
O sistema possui redundância local robusta baseada em **Outbox Pattern**:
1.  O agente tenta enviar o payload para a API.
2.  Se ocorrer erro de rede (DNS, Timeout, Sem Conexão) ou Erro 5xx do Servidor:
    *   O payload (JSON) é salvo em disco na pasta `data/outbox/`.
    *   O nome do arquivo inclui timestamp para ordenação.
3.  O agente marca o ciclo como "concluído localmente" e avança o ponteiro de tempo (para não travar a extração de novos dados).
4.  **Recuperação:** No próximo ciclo (a cada 10 min), o passo 1 é sempre "Processar Outbox". Ele tenta re-enviar os arquivos pendentes antes de processar dados novos.

### C. Redundância e Integridade
*   **Outbox (Disco):** Garante persistência se a API estiver fora.
*   **Dead Letter Queue:** Se um payload falhar 50 vezes ou receber erro 4xx (inválido), ele é movido para `data/dead_letter` para análise manual, evitando loops infinitos.
*   **Idempotência:** Todo payload gera um `sync_id` (Hash SHA256 de `store_id + window_from + window_to`). Se o agente enviar duplicado (ex: erro de rede no ACK), a API central sabe descartar a duplicata sem duplicar vendas.
*   **Dual-Verification:** Snapshot de turnos e vendas cruza totias do sistema (`op=1`) com valores declarados pelo operador (`op=9`), evidenciando quebras de caixa automaticamente.

---

## 5. Estrutura de Diretórios e Arquivos

*   `C:\Program Files\PDVSyncAgent\`
    *   `pdv-sync-agent.exe` (Binário principal)
    *   `_internal\` (Bibliotecas Python extraídas)
*   `C:\ProgramData\PDVSyncAgent\` (Dados Voláteis e Config)
     *   `.env` (Configurações, Senhas, IDs)
     *   `logs\` (Logs rotacionados diariamente)
     *   `data\state.json` (Ponteiro de sincronização e estado do turno)
     *   `data\outbox\` (Fila de espera para envio offline)
     *   `data\dead_letter\` (Mensagens com erro permanente)
