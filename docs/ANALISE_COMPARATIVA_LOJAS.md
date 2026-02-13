# Análise Comparativa Entre Lojas — Diagnóstico v4

> **Data:** 2026-02-13
> **Lojas analisadas:** FINANCEIRO (Loja 5) e LAPTOP-NTNPBKAU (Loja 8)

---

## 1. Identificação das Máquinas

| Campo | FINANCEIRO | LAPTOP-NTNPBKAU |
|---|---|---|
| **Hostname** | FINANCEIRO | LAPTOP-NTNPBKAU |
| **Loja operante** | Loja 5 - Komprão BR Tijucas | Loja 8 - Mata Atlântica |
| **CNPJ** | 29094289000641 | 29094289000722 |
| **id_ponto_venda (PDV)** | 7 | 9 |
| **id_filial (Gestão)** | 7 | 9 |

---

## 2. Resultados Universais (Confirmados em AMBAS)

### ✅ Turnos IDs são INDEPENDENTES
```
FINANCEIRO: PDV→Gestão: 0/30 | Gestão→PDV: 0/30
LAPTOP:     PDV→Gestão: 0/30 | Gestão→PDV: 0/30
```
> **CONCLUSÃO DEFINITIVA:** Turnos são gerados independentemente em cada banco. Mesmo operador, mesmo sequencial, timestamps ~1min de diferença, MAS UUIDs completamente diferentes.

### ✅ Coluna `origem` EXISTE no Gestão
- EmAMBAS lojas, `INFORMATION_SCHEMA` **não lista** a coluna `origem`
- Em AMBAS, `SELECT TOP 1 origem FROM operacao_pdv` **funciona**
- Padrão: `origem=1` = PDV/Caixa (espelho), `origem=2` = Loja (exclusivo)

### ✅ Vendas PDV = Vendas Gestão origem=1 (espelho EXATO)
| Loja | PDV vendas | Gestão orig=1 | Gestão orig=2 | Total Gestão |
|---|---|---|---|---|
| FINANCEIRO | **17.363** | **17.363** ✅ | 1.818 | 19.181 |
| LAPTOP | **6.393** | **6.393** ✅ | 117 | 6.510 |

> Vendas com `origem=1` são réplica EXATA do HiperPdv. As vendas `origem=2` **SÓ existem no Gestão**.

### ✅ Turnos das Vendas Loja existem APENAS no Gestão
```
FINANCEIRO: Turnos Loja no Gestão: 10/10 | No PDV: 0/10
LAPTOP:     Turnos Loja no Gestão: 10/10 | No PDV: 0/10
```
> Vendas `origem=2` referenciam turnos que existem no banco Gestão e **NÃO** no PDV.

### ✅ Usuários COMPARTILHADOS
- Mesmos `id_usuario`, `nome`, `login` em ambos bancos
- Incluem todas as 12 lojas + funcionários individuais

### ✅ Finalizadores IDÊNTICOS
- 10 meios de pagamento iguais em ambos bancos (IDs 1-7, 10-12)
- Nomes idênticos

### ✅ Colunas Críticas — Padrão CONSISTENTE
| Coluna | PDV | Gestão |
|---|---|---|
| `origem` | ❌ N | ✅ S |
| `id_filial` | ❌ N | ✅ S |
| `id_ponto_venda` | ✅ S | ❌ N |
| `ValorTroco` (operacao) | ❌ N | ✅ S |
| `id_turno` | ✅ S | ✅ S |
| `valor_troco` (finalizador) | ✅ S | ❌ N |

### ✅ Schema turno — Padrão CONSISTENTE
| Campo | PDV | Gestão |
|---|---|---|
| Filtro loja | `id_ponto_venda` (int) | `id_filial` (smallint) |
| User ref | `id_usuario` (int) | `id_usuario` (smallint) |

### ✅ Colisão de `id_operacao` CONFIRMADA
Mesmo `id_operacao` existe em ambos bancos com datas completamente diferentes:
```
FINANCEIRO: id 44028 → PDV: 2025-08-06 | Gestão: 2026-02-12
LAPTOP:     id 21078 → PDV: 2025-04-13 | Gestão: 2026-01-10
```
> O campo `canal` é OBRIGATÓRIO para deduplicação.

---

## 3. 🚨 DESCOBERTA CRÍTICA: `id_ponto_venda` NÃO É GLOBAL

Os IDs de `ponto_venda` são **específicos por instalação**:

| id | FINANCEIRO | LAPTOP |
|---|---|---|
| 2 | Loja 6 - Gov Celso Ramos (560) | Loja 6 - Gov Celso Ramos (560) ✅ |
| 3 | Loja 4 - iTuntz (159) | Loja 4 - iTuntz (159) ✅ |
| 4 | Loja 3 - Outlet (307) | Loja 3 - Outlet (307) ✅ |
| **5** | **Loja 2 - Morretes (218)** | **Loja 5 - Komprão BR (641)** ❌ |
| **6** | **Loja 1 - Komprão Centro (137)** | **Loja 7 - Bombinhas (480)** ❌ |
| **7** | **Loja 5 - Komprão BR (641)** ← ESTA | **Loja 2 - Morretes (218)** ❌ |
| **8** | **Loja 7 - Bombinhas (480)** | **Loja 1 - Komprão Centro (137)** ❌ |
| 9 | Loja 8 - Mata Atlântica (722) | Loja 8 - Mata Atlântica (722) ← ESTA ✅ |
| 10-13 | iguais | iguais ✅ |

> [!CAUTION]
> **IDs 5-8 estão EMBARALHADOS entre as duas máquinas!** O `id_ponto_venda` depende da ordem de cadastro na instalação local. O CNPJ é o ÚNICO identificador confiável cross-machine.

### Implicações
1. **Agente Python:** `store_id_ponto_venda` em `settings.py` é correto POR MÁQUINA, mas não serve como ID global
2. **PHP Backend:** O `store_pdv_id` vindo do webhook deve ser tratado como LOCAL — o CNPJ deve ser usado para resolução de loja
3. **Relatórios:** Não comparar `id_ponto_venda` entre lojas diferentes

---

## 4. Diferenças Entre Lojas

### Volume de Dados
| Métrica | FINANCEIRO | LAPTOP |
|---|---|---|
| **Turnos PDV** | 2.125 (2.119 fechados) | 905 (899 fechados) |
| **Turnos Gestão** | 2.155 (2.148 fechados) | 907 (899 fechados) |
| **Vendas PDV** | 17.363 | 6.393 |
| **Vendas Loja** | 1.818 (10.5%) | 117 (1.8%) |
| **7 dias PDV** | 141 | 122 |
| **7 dias Loja** | 2 | 2 |
| **Anomalias (turnos <5min)** | 123 | 49 |

### Operações por Tipo
| Tipo | FINANCEIRO PDV | FINANCEIRO Gestão | LAPTOP PDV | LAPTOP Gestão |
|---|---|---|---|---|
| Abertura (0) | — | 11 | — | — |
| Venda (1) | 17.363 | 19.181 | 6.393 | 6.510 |
| Sangria (3) | 225 | 230 | 134 | 134 |
| Falta (4) | 269 | 271 | 160 | 160 |
| Tipo 5 | — | — | 1 | 1 |
| Fechamento (9) | 2.121 | 2.152 | 905 | 905 |

> **Nota:** FINANCEIRO tem 11 Aberturas no Gestão (ausentes do PDV). LAPTOP tem 1 operação tipo "5" desconhecida.

### Filiais no Gestão
| Loja | Filiais |
|---|---|
| FINANCEIRO | Apenas filial 7 (2.155 turnos) |
| LAPTOP | filial 8 (1 turno, 0 fechados) + filial 9 (906 turnos) |

> LAPTOP tem rastro de outra filial (8) com 1 turno aberto e 1 venda Loja.

---

## 5. Comportamento dos Turnos — Comparação Temporal

### Gestão turnos ficam abertos MAIS TEMPO que PDV
```
FINANCEIRO Turno seq=2 12/02:
  PDV:    17:10:13 → 21:59:39 (4h49m)
  Gestão: 17:11:37 → 09:07:07 DIA SEGUINTE (15h55m!)

LAPTOP Turno seq=2 12/02:
  PDV:    16:56:24 → 20:58:11 (4h02m)
  Gestão: 16:57:32 → 20:59:32 (4h02m)
```

> [!IMPORTANT]
> O Gestão às vezes mantém turnos abertos até o dia seguinte (quando PDV fecha às 22h, Gestão fecha às 09h do outro dia). Isso pode causar janelas de coleta incorretas se baseadas no `data_hora_termino` do turno.

---

## 6. Conclusões e Próximos Passos

### PADRÃO CONFIRMADO (universal):
1. ✅ Turno IDs **completamente independentes** entre PDV e Gestão
2. ✅ `origem` **existe** em todas as lojas (mesmo que INFORMATION_SCHEMA não liste)
3. ✅ `origem=1` = espelho PDV | `origem=2` = vendas Loja (exclusivas)
4. ✅ Turnos de vendas Loja **só existem no Gestão**
5. ✅ Usuários e finalizadores **compartilhados**
6. ✅ `id_operacao` **colide** entre bancos — `canal` é obrigatório
7. ⚠️ `id_ponto_venda` **NÃO é global** — CNPJ é o identificador confiável

### Ações necessárias no Python Agent:
- [ ] Coletar turnos do Gestão (via `id_filial`) para vendas `origem=2`
- [ ] Filtrar vendas Loja com `origem=2` (não `origem=0`)
- [ ] Usar CNPJ como identificador global de loja
- [ ] Ajustar `ValorTroco` (campo do Gestão) vs `valor_troco` (finalizador do PDV)

### Ações necessárias no PHP Backend:
- [ ] Resolver loja por CNPJ em vez de `id_ponto_venda`
- [ ] Aceitar turnos com UUIDs do Gestão (diferentes do PDV)
- [ ] Sempre usar `canal` na deduplicação de `id_operacao`

### Script v4 está pronto para as demais 10 lojas
O diagnóstico pode ser executado em qualquer máquina sem modificação.
