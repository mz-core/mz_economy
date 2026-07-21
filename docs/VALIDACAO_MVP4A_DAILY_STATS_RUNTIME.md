# Validacao runtime - MZ_ECONOMY MVP 4A Daily Stats

Data: 2026-06-23

## Ambiente

- Workspace local: `D:/git-hub/repo_oficial`
- Recursos revisados: `mz_economy`, `mz_core`
- Runtime FiveM/DB: nao executado nesta sessao
- Status desta validacao: PENDENTE

Esta validacao registra a revisao local, uma correcao defensiva pequena e o roteiro para validar em servidor real.

## Arquivos revisados

- `mz_economy/shared/config.lua`
- `mz_economy/server/prepare.lua`
- `mz_economy/server/repository.lua`
- `mz_economy/server/service.lua`
- `mz_economy/server/commands.lua`
- `mz_economy/server/main.lua`
- `mz_economy/docs/MVP4A_DAILY_STATS.md`
- `mz_core/docs/MZ_ECONOMY_MVP4A_DAILY_STATS.md`
- `mz_core/docs/CHECKLIST_IMPLANTACAO_ECONOMIA.md`

## Comandos locais executados

```txt
luac -p mz_economy/shared/config.lua mz_economy/server/prepare.lua mz_economy/server/repository.lua mz_economy/server/service.lua mz_economy/server/commands.lua mz_economy/server/main.lua
rg -n "mz_economy_prices|mz_economy_runs|price_preview|apply_prices|dynamic|preco|price|UPDATE\\s+mz_player_accounts|INSERT\\s+INTO\\s+mz_player_accounts|AddMoney|RemoveMoney|SetMoney|mz_fuel|mz_clothing|mz_tatto|Player\\.Functions|qb_bridge|phone|email" mz_economy/shared/config.lua mz_economy/server/prepare.lua mz_economy/server/repository.lua mz_economy/server/service.lua mz_economy/server/commands.lua mz_economy/server/main.lua
rg -n "mz_economy_daily_player_stats|mzecon_rebuild_day|mzecon_daily|mzecon_player|mzecon_top|StaffAce|group\\.mz_owner" mz_economy/shared/config.lua mz_economy/server/prepare.lua mz_economy/server/repository.lua mz_economy/server/service.lua mz_economy/server/commands.lua mz_economy/server/main.lua
```

Resultado local:

- `luac -p` passou.
- Busca de escopo proibido nos Lua do MVP 4A nao encontrou preco dinamico, `mz_economy_prices`, `mz_economy_runs`, alteracao em `mz_player_accounts`, chamadas novas `AddMoney/RemoveMoney/SetMoney`, phone/email, bridge QB ou alteracoes em recursos de gameplay.
- Busca positiva confirmou tabela, comandos e permissao `group.mz_owner`.

## Resultado do startup/prepare

Runtime: nao executado.

Evidencia local esperada:

- `prepare.lua` cria `mz_economy_daily_player_stats` com `CREATE TABLE IF NOT EXISTS`.
- `main.lua` continua chamando `MZEconomyPrepare.run()`.
- comandos antigos e novos estao registrados em `commands.lua`.

Roteiro runtime pendente:

1. `restart mz_economy`.
2. Confirmar console sem erro.
3. Confirmar tabela no banco.
4. Rodar `/mzecon_report`, `/mzecon_sources`, `/mzecon_unknown`.
5. Rodar `/mzecon_rebuild_day`, `/mzecon_daily`, `/mzecon_player`, `/mzecon_top`.

## Resultado do rebuild

Runtime: nao executado.

Evidencia local esperada:

- `/mzecon_rebuild_day [YYYY-MM-DD]` chama `MZEconomyService.RebuildDailyStats`.
- O service valida data e exige `MZEconomyState.ready`.
- O repository agrega `mz_economy_transactions` e `mz_player_sessions`.
- O rebuild nao altera saldo e nao altera transacoes originais.

## Resultado de idempotencia

Runtime: nao executado.

Correcao defensiva aplicada:

- O rebuild agora usa `MySQL.transaction.await` para executar o `DELETE` do dia e o `INSERT` recalculado juntos.
- Se a transacao falhar, retorna `daily_stats_rebuild_failed`.
- Depois de sucesso, conta as linhas persistidas do dia para retornar `rebuiltRows`.

Roteiro runtime pendente:

1. Rodar `/mzecon_rebuild_day`.
2. Rodar novamente.
3. Confirmar uma linha por `(stat_date, citizenid)`.
4. Confirmar numeros coerentes.

## Resultado do daily

Runtime: nao executado.

Evidencia local esperada:

- `/mzecon_daily` mostra players, playtime, income, expense, transfer, adjustment, unknown e medias por hora.
- Se nao houver stats, orienta rodar `/mzecon_rebuild_day`.
- `admin_adjustment` e `org_transfer` nao entram em `income_total` por regra de flag/categoria.

## Resultado do player

Runtime: nao executado.

Evidencia local esperada:

- `/mzecon_player [source|citizenid] [date]` aceita source online ou citizenid.
- Source online tenta resolver via `exports['mz_core']:ResolvePlayerIdentity(source)`.
- Sem stats, responde `daily_stats_not_found` com orientacao de rebuild.

## Resultado do top

Runtime: nao executado.

Evidencia local esperada:

- `/mzecon_top` usa modo `income` por padrao.
- `/mzecon_top YYYY-MM-DD expense` ordena por despesa.
- `/mzecon_top YYYY-MM-DD unknown` ordena por unknown.
- Tambem aceita forma curta `/mzecon_top income|expense|unknown`.

## Resultado de classificacao

Runtime: nao executado.

Evidencia local esperada:

- `income_total` soma somente `counts_as_income = 1`.
- `expense_total` soma somente `counts_as_expense = 1`.
- `adjustment_total` soma `admin_adjustment`, `admin_org_adjustment` e `system_bootstrap`.
- `transfer_total` soma `direction = transfer` ou `category = org_transfer`.
- `unknown_total` soma `unknown`, nulo ou vazio.
- `salary` entra em `salary_income` quando existir em runtime.
- `salary_expense` entra em `salary_expense` quando houver `citizenid`; linhas puramente org/system continuam fora de daily player stats e visiveis nos relatorios gerais.

## Resultado de permissao

Runtime: nao executado.

Evidencia local esperada:

- Console `source = 0` e permitido.
- Players dependem de `Config.Economy.StaffAce`, padrao `group.mz_owner`.

## Resultado de restart

Runtime: nao executado.

Evidencia local esperada:

- A tabela e persistente.
- O prepare usa `CREATE TABLE IF NOT EXISTS`.
- Stats recalculadas devem continuar no banco apos restart.

## Bugs encontrados e corrigidos

### Rebuild com delete/insert fora de transacao

Risco:

- Se o `DELETE` do dia passasse e o `INSERT` falhasse, o dia ficaria sem stats ate novo rebuild.

Correcao:

- `MZEconomyRepository.rebuildDailyPlayerStats` passou a usar `MySQL.transaction.await`.
- O service passou a propagar `daily_stats_rebuild_failed`.
- O retorno de sucesso usa contagem real de linhas do dia.

## Arquivos alterados nesta validacao

- `mz_economy/server/repository.lua`
- `mz_economy/server/service.lua`
- `mz_economy/docs/MVP4A_DAILY_STATS.md`
- `mz_economy/docs/VALIDACAO_MVP4A_DAILY_STATS_RUNTIME.md`
- `mz_core/docs/MZ_ECONOMY_MVP4A_DAILY_STATS.md`

## Conclusao

PENDENTE.

Motivo: a revisao local passou e uma correcao defensiva foi aplicada, mas os testes runtime FiveM/DB ainda nao foram executados.

## Proximos passos

Executar o roteiro em servidor real:

```cfg
ensure oxmysql
ensure mz_core
ensure mz_economy
ensure mz_fuel
```

Se todos os cenarios passarem, atualizar esta conclusao para `APROVADO` e seguir para MVP 4B: relatorios melhores e investigacao de `unknown`.
