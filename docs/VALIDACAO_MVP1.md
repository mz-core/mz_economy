# Validacao MVP 1 - mz_economy

Data da validacao: 2026-06-23

Escopo: validar o MVP 1 passivo do `mz_economy`, focado em observabilidade e ledger. Esta validacao nao inclui preco dinamico, ganho/hora, wrappers do `mz_core`, payroll, org bank, fuel, clothing, tattoos, bridge QB ou email/celular.

## Status geral

O recurso continua passivo. Nao altera saldo de jogador, nao chama `AddMoney`, `RemoveMoney` ou `SetMoney`, nao acessa `mz_player_accounts` e nao altera arquivos do `mz_core`.

Validacao executada neste ambiente:

- Revisao estatica de manifest, SQL, repository, service e comandos.
- Busca textual por chamadas proibidas e tabelas fora do escopo.
- Conferencia de campos essenciais da tabela.
- Conferencia de permissao ACE nos comandos.
- Conferencia do export `RecordTransaction`.
- Correcao de bugs defensivos no `mz_economy`.

Validacao pendente:

- Runtime real em servidor FiveM com `oxmysql` e banco ativo.
- Confirmacao fisica da criacao da tabela no banco.
- Execucao real dos comandos in-game/console.
- Chamada real do export a partir de outro recurso.

## O que foi testado

| Item | Resultado esperado | Resultado obtido |
| --- | --- | --- |
| `fxmanifest.lua` | `cerulean`, `gta5`, `lua54`, scripts em ordem e dependencias `oxmysql`/`mz_core` | OK em revisao estatica |
| Ordem dos scripts | config, prepare, repository, service, commands, main | OK |
| Tabela `mz_economy_transactions` | `CREATE TABLE IF NOT EXISTS` com campos essenciais | OK em revisao estatica |
| Indices | indices por citizenid/data, categoria/data, source/data, flags/data, org/data e data | OK |
| Export `RecordTransaction` | acessivel por `exports['mz_economy']:RecordTransaction(data)` | OK em codigo |
| Alteracao de saldo | nenhuma chamada a saldo/player accounts | OK em busca textual |
| Validacao de amount | exige numero maior que zero | OK |
| Normalizacao de account | aceita `wallet`, `bank`, `dirty`, `org` e aliases | OK |
| Normalizacao de direction | aceita `in`, `out`, `transfer`, `adjustment` | OK |
| Category default | vazia vira `unknown` | OK |
| Flags income/expense | default false; se ambas true, reseta para false/false por padrao | OK |
| `source_resource` | usa payload/metadata, depois `GetInvokingResource()`, depois default | OK |
| Metadata | aceita tabela, nil e valores nao-tabela sem quebrar | OK apos correcao |
| Identidade via `mz_core` | tenta `ResolvePlayerIdentity(source)` e nao bloqueia se falhar | OK em codigo |
| Comandos ACE | comandos chamam `ensureAllowed` | OK |
| `/mzecon_test` | exige ACE e `Config.Economy.Debug = true` | OK |

## Campos essenciais da tabela

Todos os campos pedidos existem em `server/prepare.lua`:

- `id`
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

## Bugs encontrados

### Export/comandos antes do prepare

Risco encontrado: uma chamada muito cedo ao service poderia tentar consultar/inserir antes do prepare marcar o recurso como pronto.

Correcao feita:

- Adicionada guarda `economy_not_ready` em:
  - `RecordTransaction`
  - `GetDailySummary`
  - `GetUnknownTransactions`
  - `GetSourceSummary`
- `MZEconomyState.ready` agora e marcado como `true` somente apos prepare OK.

### Metadata nao-tabela

Risco encontrado: `metadata` string/numero/boolean era descartado como `{}`. Isso nao quebrava, mas perdia informacao enviada por chamador.

Correcao feita:

- Criada normalizacao que preserva valores nao-tabela como:
  - `raw_metadata`
  - `raw_metadata_type`
- `nil` continua virando `{}`.
- Tabela continua sendo salva como JSON.

## Correcoes feitas

Arquivos alterados nesta validacao:

- `mz_economy/server/prepare.lua`
- `mz_economy/server/service.lua`
- `mz_economy/docs/VALIDACAO_MVP1.md`

Correcoes:

- Estado `MZEconomyState.ready`.
- Retorno defensivo `economy_not_ready`.
- Metadata segura para tabela, string, numero, boolean ou nil.

## Plano de teste em runtime

Adicionar ao `server.cfg`:

```cfg
ensure oxmysql
ensure mz_core
ensure mz_economy

add_ace group.mz_owner command allow
add_ace group.mz_owner command.quit deny
add_ace group.mz_owner group.mz_owner allow

add_principal identifier.fivem:SEU_ID_FIVEM_AQUI group.mz_owner
add_principal identifier.fivem:ID_DO_SOCIO_AQUI group.mz_owner
```

Para testar o comando fake:

```lua
Config.Economy.Debug = true
```

Passos:

1. Iniciar o servidor.
2. Confirmar no console a mensagem `[mz_economy] passive ledger ready`.
3. Confirmar no banco que `mz_economy_transactions` foi criada.
4. Rodar `/mzecon_report` sem dados.
5. Rodar `/mzecon_test`.
6. Rodar `/mzecon_report` novamente.
7. Rodar `/mzecon_unknown`.
8. Rodar `/mzecon_sources`.
9. Reiniciar apenas `mz_economy`.
10. Rodar `/mzecon_report` novamente e confirmar que a tabela nao duplicou e o recurso continua funcional.

## Resultado esperado no runtime

### Sem dados

`/mzecon_report` deve retornar:

- total de transacoes `0`
- totais `in/out/transfer/adjustment` em `0`
- income e expense em `0`
- unknown em `0`
- top categorias/fontes como `nenhuma`

### Apos `/mzecon_test`

Deve existir uma linha em `mz_economy_transactions` com:

- `account = wallet`
- `amount = 123`
- `direction = adjustment`
- `category = admin_adjustment`
- `reason = mzecon_test`
- `source_resource = mz_economy`
- `source_type = manual_test`
- `counts_as_income = 0`
- `counts_as_expense = 0`

`/mzecon_report` deve mostrar pelo menos:

- total de transacoes `1`
- adjustment `123`
- income `0`
- expense `0`

`/mzecon_unknown` pode nao listar a transacao de teste, porque ela usa `admin_adjustment`, nao `unknown`.

`/mzecon_sources` deve listar `mz_economy`.

## Teste de export sugerido

De outro recurso server-side, chamar:

```lua
local result = exports['mz_economy']:RecordTransaction({
  account = 'cash',
  amount = 50,
  direction = 'in',
  category = '',
  reason = 'manual_runtime_validation',
  source_resource = 'runtime_test',
  source_type = 'validation',
  counts_as_income = false,
  counts_as_expense = false,
  metadata = 'metadata_string_test'
})

print(json.encode(result))
```

Resultado esperado:

- `ok = true`
- `account` salvo como `wallet`
- `category` salvo como `unknown`
- `metadata_json` contendo `raw_metadata` e `raw_metadata_type`

## Teste de permissao ACE

1. Com player sem ACE, rodar `/mzecon_report`.
2. Resultado esperado: mensagem `Sem permissao.` e nenhum dado economico exibido.
3. Com o player no grupo `group.mz_owner`, rodar novamente.
4. Resultado esperado: relatorio exibido.

## Pendencias para MVP 2

- Integrar wrappers metadata-aware no `mz_core`.
- Registrar ledger em `AddMoney`, `RemoveMoney` e `SetMoney` mantendo compatibilidade.
- Adaptar payroll.
- Adaptar org bank.
- Adaptar `mz_fuel`.
- Adaptar `mz_clothing`.
- Adaptar `mz_tatto`.
- Adaptar bridge QB.
- Criar testes reais de regressao em runtime.

## Confirmacao de escopo

Confirmado: o `mz_economy` MVP 1 permanece uma camada passiva de observabilidade/ledger. Ele nao altera saldos, nao cria preco dinamico, nao calcula ganho/hora e nao modifica `mz_core`.
