# MZ_ECONOMY MVP 4A - Daily stats passivas

## Objetivo

Criar agregacao diaria passiva para relatatorios economicos usando:

- `mz_economy_transactions`
- `mz_player_sessions`

Este MVP nao altera saldo, nao cria preco dinamico, nao roda scheduler automatico e nao muda payroll, org bank, fuel, clothing, tattoos, jobs, phone/email ou bridge QB.

## Tabela criada

### `mz_economy_daily_player_stats`

Tabela derivada e idempotente por jogador/dia.

Chave unica:

- `(stat_date, citizenid)`

Campos principais:

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

`mz_economy_reports` ficou fora deste MVP, porque o snapshot persistido nao e necessario para os comandos manuais iniciais.

## Como o rebuild funciona

O comando `/mzecon_rebuild_day [YYYY-MM-DD]`:

1. apaga as stats do dia em `mz_economy_daily_player_stats`;
2. recalcula a partir de `mz_economy_transactions` e `mz_player_sessions`;
3. insere uma linha por `citizenid` com transacao ou playtime no dia;
4. nao altera `mz_economy_transactions`;
5. nao altera `mz_player_sessions`;
6. nao altera saldos.

Rodar duas vezes no mesmo dia nao duplica linhas, porque a tabela e apagada e recriada para a data. O `DELETE` e o `INSERT` rodam dentro de uma transacao do `oxmysql`; se a insercao falhar, o rebuild retorna erro em vez de confirmar um dia vazio.

## Playtime

Fonte primaria:

- `mz_player_sessions`

Regras:

- usa `joined_at` como inicio;
- usa `dropped_at`, `last_seen_at` ou `NOW()` para sessoes ativas quando `Config.Economy.Stats.IncludeOpenSessions = true`;
- corta a sessao na janela do dia;
- divide sessoes que atravessam meia-noite pela intersecao com o dia recalculado;
- ignora duracoes negativas;
- sessoes abaixo de 1 minuto viram 0 minuto;
- nao cria heartbeat.

## Income e expense

`income_total` soma `amount` quando:

- `counts_as_income = 1`

`expense_total` soma `amount` quando:

- `counts_as_expense = 1`

Categorias detalhadas:

- `legal_income`: `legal_job`, `sale_to_npc`, `mission`
- `illegal_income`: `illegal_job`, `illegal_sale`, `heist`
- `salary_income`: `salary`
- `business_income`: `business_revenue`
- `reward_income`: `reward`, `event_reward`
- `vehicle_expense`: `vehicle_expense`
- `cosmetic_expense`: `cosmetic_expense`
- `shop_expense`: `shop_expense`
- `salary_expense`: `salary_expense`

Nao contam como income por padrao:

- `admin_adjustment`
- `admin_org_adjustment`
- `system_bootstrap`
- `org_transfer`
- `player_transfer`
- `unknown`

## Por hora

```txt
hours = playtime_minutes / 60
income_per_hour = income_total / hours
expense_per_hour = expense_total / hours
```

Se `playtime_minutes = 0`, os valores por hora ficam `0`.

## Comandos criados

### `/mzecon_rebuild_day [YYYY-MM-DD]`

Recalcula as stats do dia informado ou do dia atual.

### `/mzecon_daily [YYYY-MM-DD]`

Mostra resumo agregado da tabela diaria:

- players analisados
- playtime total
- income/expense
- transfer/adjustment
- income/hora medio
- expense/hora medio
- legal/illegal/salary/business/reward
- vehicle/cosmetic/shop/salary expense
- unknown total/count
- top income por hora

### `/mzecon_player [source|citizenid] [YYYY-MM-DD]`

Mostra resumo diario de um jogador.

Se receber source online, tenta resolver via `exports['mz_core']:ResolvePlayerIdentity(source)`.

### `/mzecon_top [YYYY-MM-DD] [income|expense|unknown]`

Mostra ranking simples do dia.

Tambem aceita forma curta:

```txt
/mzecon_top income
/mzecon_top expense
/mzecon_top unknown
```

## Permissao

Os comandos usam `Config.Economy.StaffAce`, por padrao:

```lua
Config.Economy.StaffAce = 'group.mz_owner'
```

Console `source = 0` continua permitido.

## Configuracao

```lua
Config.Economy.Stats = {
  MinMinutesOnlineToCount = 60,
  MaxTopRows = 10,
  IncludeOpenSessions = true
}
```

`MinMinutesOnlineToCount` e usado para medias por hora no comando diario.

## Como testar

Status runtime em 2026-06-23: PENDENTE.

Roteiro detalhado em `mz_economy/docs/VALIDACAO_MVP4A_DAILY_STATS_RUNTIME.md`.

1. Iniciar:

```cfg
ensure oxmysql
ensure mz_core
ensure mz_economy
```

2. Gerar algumas transacoes, por exemplo:

```txt
mz_money_add 1 wallet 1000 teste_stats
```

3. Gerar alguma despesa, como fuel, se disponivel.

4. Rodar:

```txt
/mzecon_rebuild_day
/mzecon_daily
/mzecon_player 1
/mzecon_top
```

5. Rodar `/mzecon_rebuild_day` novamente e confirmar que nao duplica linhas.

## Limitacoes

- Runtime FiveM/DB ainda precisa validar a SQL em ambiente real.
- `mz_economy_reports` nao foi criado neste MVP.
- Nao ha scheduler automatico.
- Nao ha mediana; o comando diario mostra media para players com playtime minimo configurado.
- Transacoes sem `citizenid` nao entram em `daily_player_stats`; continuam visiveis nos comandos gerais do ledger.

## Proximo passo

MVP 4B pode melhorar os relatorios e a investigacao de fontes `unknown`.

MVP 5 pode criar preview de preco, ainda sem aplicar automaticamente.
