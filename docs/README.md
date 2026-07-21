# mz_economy

`mz_economy` e o ledger economico passivo do ecossistema `mz_core`.

Neste MVP 1 ele nao muda saldo de jogador, nao aplica preco dinamico, nao adapta payroll, org bank, fuel, clothing, tattoos ou bridge QBCore. Ele apenas cria a tabela de transacoes, valida payloads, registra linhas quando chamado e oferece comandos basicos de diagnostico.

Atualizacao 2026-06-23: MVPs posteriores ja adaptaram wrappers do `mz_core`, gastos atuais (`mz_fuel`, `mz_clothing`, `mz_tatto`) e fluxos de org bank/payroll. O `mz_economy` continua passivo; a verdade de saldo permanece nos recursos atuais. A validacao runtime de org bank/payroll esta documentada como pendente em `mz_core/docs/VALIDACAO_MVP3A_ORG_PAYROLL_RUNTIME.md`.

Atualizacao MVP 4A: o recurso tambem cria stats diarias passivas em `mz_economy_daily_player_stats`, recalculadas manualmente por comando staff. Nao ha scheduler, preco dinamico ou alteracao de saldo. A validacao runtime esta documentada como pendente em `mz_economy/docs/VALIDACAO_MVP4A_DAILY_STATS_RUNTIME.md`.

Atualizacao MVP 4B: com autorizacao explicita do usuario, foram implementados relatorios passivos de health, unknown sources, categorias, anomalias simples e recortes de transacoes. MVP 3A e MVP 4A seguem pendentes de runtime real; o 4B nao altera saldo e nao cria preco dinamico. Detalhes em `mz_economy/docs/MVP4B_UNKNOWN_REPORTS.md` e status em `mz_economy/docs/FECHAMENTO_ACELERADO_STATUS.md`.

## Dependencias

- `oxmysql`
- `mz_core`

Ordem sugerida no `server.cfg`:

```cfg
ensure oxmysql
ensure mz_core
ensure mz_economy
```

## Tabelas criadas

O recurso cria `mz_economy_transactions` no start.

Campos principais:

- `transaction_id`
- `citizenid`
- `license`
- `account`
- `amount`
- `balance_before`
- `balance_after`
- `direction`
- `category`
- `reason`
- `source_resource`
- `source_type`
- `counts_as_income`
- `counts_as_expense`
- `related_citizenid`
- `related_org_code`
- `external_ref`
- `metadata_json`
- `created_at`

Tambem cria `mz_economy_daily_player_stats` para stats derivadas por jogador/dia.

Campos principais:

- `stat_date`
- `citizenid`
- `license`
- `player_name`
- `playtime_minutes`
- `income_total`
- `expense_total`
- `transfer_total`
- `adjustment_total`
- `income_per_hour`
- `expense_per_hour`
- `legal_income`
- `illegal_income`
- `salary_income`
- `business_income`
- `reward_income`
- `vehicle_expense`
- `cosmetic_expense`
- `shop_expense`
- `salary_expense`
- `unknown_total`
- `transaction_count`
- `unknown_count`

## Export principal

```lua
local result = exports['mz_economy']:RecordTransaction({
  source = source,
  citizenid = nil,
  license = nil,

  account = 'wallet',
  amount = 1000,
  balance_before = nil,
  balance_after = nil,

  direction = 'in',
  category = 'legal_job',
  reason = 'test_payment',
  source_resource = nil,
  source_type = 'manual_test',

  counts_as_income = true,
  counts_as_expense = false,

  related_citizenid = nil,
  related_org_code = nil,
  external_ref = nil,
  metadata = {}
})

if not result.ok then
  print(('ledger failed: %s'):format(result.error))
end
```

Se `source` for enviado, o recurso tenta resolver `citizenid` e `license` via:

```lua
exports['mz_core']:ResolvePlayerIdentity(source)
```

Falha de identidade nao bloqueia o registro. O `mz_economy` nunca cria player.

## Contas aceitas

- `wallet`
- `bank`
- `dirty`
- `org`

Aliases:

- `cash` -> `wallet`
- `money` -> `wallet`
- `black_money` -> `dirty`

## Directions aceitas

- `in`
- `out`
- `transfer`
- `adjustment`

## Categorias recomendadas

- `legal_job`
- `illegal_job`
- `salary`
- `business_revenue`
- `shop_expense`
- `vehicle_expense`
- `cosmetic_expense`
- `org_transfer`
- `player_transfer`
- `admin_adjustment`
- `admin_org_adjustment`
- `system_bootstrap`
- `refund`
- `unknown`

Categoria vazia vira `unknown`.

## Regras de seguranca

- `amount` precisa ser maior que zero.
- `account` precisa ser valida.
- `direction` precisa ser valida.
- `source_resource` usa `metadata.source_resource`, depois `GetInvokingResource()`, depois `unknown`.
- `counts_as_income` e `counts_as_expense` sao normalizados para boolean.
- Por padrao, uma transacao nao pode ser renda e despesa ao mesmo tempo. Se ambos vierem true, os dois sao resetados para false e um warning e logado.
- Erro de insert retorna `ok = false` e nao derruba o recurso.
- Nenhuma funcao altera saldo.

## Comandos staff

Todos usam a ACE configurada em `Config.Economy.StaffAce`, por padrao `group.mz_owner`.

Os comandos administrativos da economia devem ser executados por membros do grupo `mz_owner`, seguindo o padrao real do `server.cfg` do projeto.

```cfg
add_ace group.mz_owner command allow
add_ace group.mz_owner command.quit deny
add_ace group.mz_owner group.mz_owner allow

add_principal identifier.fivem:SEU_ID_FIVEM_AQUI group.mz_owner
add_principal identifier.fivem:ID_DO_SOCIO_AQUI group.mz_owner
```

Console sempre pode executar.

### `/mzecon_report [YYYY-MM-DD]`

Mostra:

- data analisada
- total de transacoes
- total `in`
- total `out`
- total `transfer`
- total `adjustment`
- total marcado como income
- total marcado como expense
- total `unknown`
- top 5 categorias
- top 5 fontes

### `/mzecon_unknown [YYYY-MM-DD] [limit]`

Lista as ultimas transacoes `unknown` do dia.

Campos exibidos:

- id
- citizenid
- account
- amount
- direction
- source_resource
- reason
- created_at

### `/mzecon_health [YYYY-MM-DD]`

Mostra saude geral do ledger no dia:

- total de transacoes
- total `in` e `out`
- flags de income/expense
- transferencias e ajustes
- quantidade e percentual de `unknown`
- status `OK`, `ATENCAO` ou `CRITICO`
- top source e top category

### `/mzecon_unknown_sources [YYYY-MM-DD] [limit]`

Agrupa transacoes `unknown` por `source_resource`, exibindo volume, total, primeira/ultima ocorrencia e exemplos de account/direction/reason.

### `/mzecon_category_report [YYYY-MM-DD] [limit]`

Agrupa transacoes por `category` + `direction`, com quantidade, total, flags de income/expense e top source.

### `/mzecon_sources [YYYY-MM-DD]`

Agrupa por `source_resource`.

Campos exibidos:

- source_resource
- quantidade de transacoes
- total `in`
- total `out`
- total `unknown`

### `/mzecon_rebuild_day [YYYY-MM-DD]`

Recalcula manualmente `mz_economy_daily_player_stats` para o dia informado ou dia atual.

Nao altera saldo nem transacoes originais.

### `/mzecon_daily [YYYY-MM-DD]`

Mostra resumo do dia a partir das stats recalculadas:

- players analisados
- playtime total
- income/expense
- income por hora medio
- unknown total/count
- categorias principais
- top income/hora

### `/mzecon_player [source|citizenid] [YYYY-MM-DD]`

Mostra stats diarias de um jogador. Quando recebe source online, tenta resolver `citizenid` via `mz_core`.

### `/mzecon_top [YYYY-MM-DD] [income|expense|unknown]`

Mostra ranking simples do dia a partir da tabela diaria.

### `/mzecon_suspicious [YYYY-MM-DD] [limit]`

Mostra anomalias simples:

- transacoes grandes
- players com maior `unknown`
- players com maior `adjustment`
- income/hora acima do multiplicador configurado, quando daily stats existem
- categorias suspeitas marcadas como income
- transacoes com `source_resource` unknown

### `/mzecon_player_tx [source|citizenid] [YYYY-MM-DD] [limit]`

Lista transacoes recentes de um jogador no dia.

### `/mzecon_source_tx [source_resource] [YYYY-MM-DD] [limit]`

Lista transacoes recentes de uma fonte no dia.

### `/mzecon_test`

Disponivel somente com:

```lua
Config.Economy.Debug = true
```

Registra uma transacao fake de ajuste:

- account `wallet`
- amount `123`
- direction `adjustment`
- category `admin_adjustment`
- reason `mzecon_test`

## Proximos passos

Ficam fora deste MVP e devem vir em prompts separados:

- integrar wrappers do `mz_core`
- adaptar payroll
- adaptar org bank
- adaptar `mz_fuel`
- adaptar `mz_clothing`
- adaptar `mz_tatto`
- adaptar QBCore bridge
- validar runtime da agregacao de ganho/hora
- criar preview de precos
- criar preco dinamico
- criar email/app no telefone
