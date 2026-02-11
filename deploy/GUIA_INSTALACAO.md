# PDV Sync Agent v2.0 — Guia de Instalação Remota

## Instalação Completa (1 comando)

Abra o **PowerShell como Administrador** na loja e cole:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; $url = 'https://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip'; $zip = "$env:TEMP\PDVSyncAgent.zip"; $dest = "$env:TEMP\PDVSyncAgent"; Invoke-WebRequest $url -OutFile $zip; Expand-Archive $zip $dest -Force; & "$dest\install.bat"
```

> Isso baixa, extrai e executa o instalador automaticamente.

---

## Instalação Passo a Passo

Se preferir fazer por etapas:

### Passo 1 — Habilitar Mixed Mode no SQL Server

```powershell
$sqlKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' |
    Where-Object { $_.Name -match 'MSSQL\d+\.' } | Select-Object -First 1
$regPath = Join-Path $sqlKey.PSPath 'MSSQLServer'
Set-ItemProperty -Path $regPath -Name 'LoginMode' -Value 2
Restart-Service 'MSSQL$HIPER' -Force
Start-Sleep -Seconds 5
Write-Host 'Mixed Mode habilitado!' -ForegroundColor Green
```

### Passo 2 — Baixar e extrair

```powershell
$url = 'https://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip'
$zip = 'C:\PDVSyncAgent.zip'
$dest = 'C:\PDVSyncAgent_install'

Invoke-WebRequest $url -OutFile $zip
Expand-Archive $zip $dest -Force
Write-Host 'Download OK!' -ForegroundColor Green
```

### Passo 3 — Instalar

```powershell
cd C:\PDVSyncAgent_install
.\install.bat
```

O instalador vai perguntar:
1. **ID da loja** — número da lista que aparece na tela
2. **Apelido** — ex: `TIJUCAS-01`, `BOMBINHAS-01`
3. **Token da API** — pode dar ENTER para placeholder

### Passo 4 — Verificar

```powershell
# Task rodando?
schtasks /query /tn PDVSyncAgent /fo LIST | Select-String 'Status'

# Últimas linhas do log
Get-Content C:\ProgramData\PDVSyncAgent\logs\agent.log -Tail 10

# Diagnóstico completo
& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --doctor --config "C:\ProgramData\PDVSyncAgent\.env"
```

---

## Reparar Instalação Existente

```powershell
cd C:\PDVSyncAgent_install
powershell -ExecutionPolicy Bypass -NoProfile -File install.ps1 -Repair
```

---

## Atualizar Agente (loja já instalada)

```powershell
& "C:\Program Files\PDVSyncAgent\update.bat" https://erp.maiscapinhas.com.br/download/PDVSyncAgent_latest.zip
```

---

## Desinstalar

```powershell
& "C:\Program Files\PDVSyncAgent\uninstall.bat"
```

> Os dados e logs em `C:\ProgramData\PDVSyncAgent` são preservados.

---

## Comandos Úteis

| Ação | Comando |
|---|---|
| Ver status | `schtasks /query /tn PDVSyncAgent /v` |
| Parar agente | `schtasks /end /tn PDVSyncAgent` |
| Iniciar agente | `schtasks /run /tn PDVSyncAgent` |
| Ver logs | `notepad C:\ProgramData\PDVSyncAgent\logs\agent.log` |
| Ver config | `notepad C:\ProgramData\PDVSyncAgent\.env` |
| Doctor | `& "C:\Program Files\PDVSyncAgent\pdv-sync-agent.exe" --doctor --config "C:\ProgramData\PDVSyncAgent\.env"` |
| Último sync | `Get-Content C:\ProgramData\PDVSyncAgent\data\state.json` |
| Fila de envio | `Get-ChildItem C:\ProgramData\PDVSyncAgent\data\outbox \| Measure-Object` |

---

## Lista de Lojas (referência)

| ID | Loja |
|---|---|
| 2 | MC Gov Celso Ramos |
| 3 | MC Tabuleiro |
| 4 | iTuntz |
| 5 | MC Outlet |
| 6 | MC Komprão BR Tijucas |
| 7 | MC Mata Atlântica |
| 8 | MC Bombinhas |
| 9 | MC Morretes |
| 10 | MC Komprão Centro TJ |
| 11 | MC P4 |
| 12 | MC Camboriú Caledônia |
| 13 | MC Porto Belo |

---

## Troubleshooting

### "Login failed for user 'pdv_sync'"
SQL Server está em Windows Auth Only. Execute o Passo 1 (Mixed Mode).

### "ODBC Driver not found"
O instalador instala automaticamente. Se falhar, verifique `extra\msodbcsql.msi` no ZIP.

### ".env já existe (pulando)"
Use `-Repair` para reescrever: `powershell -ExecutionPolicy Bypass -File install.ps1 -Repair`

### Agente não inicia após boot
Verifique se a task existe: `schtasks /query /tn PDVSyncAgent`
Se não existir, reinstale com `install.bat`.
