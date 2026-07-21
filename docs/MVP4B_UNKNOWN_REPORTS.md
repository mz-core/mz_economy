# MVP 4B - Unknown reports e diagnosticos passivos

Data: 2026-06-23

## Escopo

O MVP 4B adiciona relatorios staff para investigar `unknown`, fontes, categorias e anomalias simples do ledger.

Este MVP e somente passivo:

- nao altera saldo;
- nao cria preco dinamico;
- nao cria `mz_economy_prices`;
- nao cria `mz_economy_runs`;
- nao aplica scheduler;
- nao altera payroll, org bank, fuel, clothing ou tattoos;
- nao altera bridge QB;
- nao corrige transacoes `unknown` automaticamente.

## Config

`mz_economy/shared/config.lua`:

```lua
Reports = {
  MaxRows = 10,
  UnknownWarningPercent = 5,
  UnknownCriticalPercent = 15,
  SuspiciousIncomeMultiplier = 3.0,
  MinMinutesForSuspicious = 60,
  LargeTransactionAmount = 100000
}
```

Permissao:

```lua
StaffAce = 'group.mz_owner'
```

Console (`source = 0`) sempre pode executar.

## Comandos

### `/mzecon_health [YYYY-MM-DD]`

Mostra saude geral do dia:

- total de transacoes;
- total `in` e `out`;
- total marcado como income/expense;
- transferencias e ajustes;
- quantidade e percentual de `unknown`;
- status `OK`, `ATENCAO` ou `CRITICO`;
- top source e top category;
- quantidade de players com stats diarias calculadas.

### `/mzecon_unknown_sources [YYYY-MM-DD] [limit]`

Agrupa transacoes `unknown` por `source_resource`.

Campos:

- source;
- quantidade de transacoes;
- total movimentado;
- primeira e ultima ocorrencia;
- accounts, directions e reasons encontrados.

### `/mzecon_category_report [YYYY-MM-DD] [limit]`

Agrupa por `category` + `direction`.

Campos:

- category;
- direction;
- quantidade;
- total;
- flags de income/expense;
- top source.

### `/mzecon_suspicious [YYYY-MM-DD] [limit]`

Relatorio simples de anomalias:

- transacoes acima de `LargeTransactionAmount`;
- players com maior volume `unknown`;
- players com maior volume de `adjustment`;
- players com `income_per_hour` acima do multiplicador da media, quando daily stats existem;
- categorias suspeitas marcadas como income;
- transacoes com `source_resource` unknown.

Se `mz_economy_daily_player_stats` ainda nao foi recalculada para o dia, o recorte de `income_per_hour` e pulado com aviso.

### `/mzecon_player_tx [source|citizenid] [YYYY-MM-DD] [limit]`

Lista as ultimas transacoes de um jogador no dia.

Quando recebe source online, resolve `citizenid` via `mz_core`.

### `/mzecon_source_tx [source_resource] [YYYY-MM-DD] [limit]`

Lista as ultimas transacoes de uma fonte especifica no dia.

## Ordem sugerida de uso

1. `/mzecon_health 2026-06-23`
2. `/mzecon_unknown_sources 2026-06-23 10`
3. `/mzecon_category_report 2026-06-23 10`
4. `/mzecon_suspicious 2026-06-23 10`
5. `/mzecon_player_tx [source|citizenid] 2026-06-23 10`
6. `/mzecon_source_tx [source_resource] 2026-06-23 10`

## Dependencia com MVP 4A

O 4B funciona sem daily stats para os relatorios de ledger.

O bloco de `income_per_hour` dentro de `/mzecon_suspicious` depende de:

```cfg
/mzecon_rebuild_day [YYYY-MM-DD]
```

Se o rebuild ainda nao foi executado, os demais blocos continuam funcionando.

## Validacao runtime pendente

Os comandos foram validados estaticamente. A validacao real ainda precisa ser feita em servidor FiveM com DB:

- rodar os comandos acima em console;
- rodar os comandos com player staff no grupo `group.mz_owner`;
- confirmar bloqueio para player sem ACE;
- confirmar comportamento antes e depois de `/mzecon_rebuild_day`.
