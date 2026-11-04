# mz_economy

`mz_economy` e o owner e writer canonico de todo estado financeiro da MZ Framework desde o checkpoint `POST_ECONOMY_SINGLE_WRITER_CUTOVER`.

## Ownership

O resource possui:

- conta financeira digital de Character (`bank`);
- coordenacao financeira de `wallet` (`money`) e `dirty` (`dirty_money`), cuja custodia pertence ao `mz_inventory`;
- contas financeiras de Organization;
- mutacoes, transferencias e execucao financeira de payroll;
- idempotencia e receipts financeiros;
- ledger, extratos, daily stats e relatorios.

`citizenid` e a identidade persistente de Character usada nas contas financeiras. `source` e apenas um locator de runtime e nunca e chave persistente.

Identity Account e Financial Account sao conceitos diferentes:

- `mz_core` possui `mz_accounts`, identifiers, Character e session;
- `mz_economy` possui `mz_player_accounts`, com apenas o saldo digital `bank`;
- `mz_inventory` possui as quantidades fisicas `money` e `dirty_money` por `citizenid`;
- a projecao runtime `player.money` no Economy mantem somente `bank`; `GetMoney` consulta o inventario principal para compor `wallet` e `dirty`.

## Dependencias e direcao

```text
mz_org / mz_bank / gameplay consumers
                  |
                  v
             mz_economy
              /       \
             v         v
          mz_core   mz_inventory
       identity/audit  custody
```

`mz_core` nao depende de `mz_economy` para Identity, Character, Session ou lifecycle. O Economy reage a `mz_core:server:playerLoaded`, resolve a identidade canonica e garante a conta financeira uma unica vez com `INSERT ... ON DUPLICATE KEY`.

`mz_inventory` tambem nao depende de `mz_economy`. A dependencia e de mao unica: o Economy chama apenas os exports monetarios protegidos do Inventory. Nao existe SQL compartilhado entre os resources.

## Schema baseline

O `server/prepare.lua` cria diretamente, sem migration de compatibilidade:

- `mz_player_accounts`;
- `mz_account_idempotency`;
- `mz_money_item_sagas`;
- `mz_org_accounts`;
- `mz_org_account_operations`;
- `mz_economy_transactions`;
- `mz_economy_daily_player_stats`.

`mz_org_account_operations` permanece porque representa receipt, fingerprint, status e reversal de comercio organizacional. `mz_org_account_transactions` foi removida porque duplicava o ledger canonico. A financial outbox e seus receipts foram removidos porque nao existia consumer independente apos a consolidacao de saldo e ledger no mesmo owner.

`mz_player_accounts` nasce somente com `bank`; nao existem colunas numericas `wallet` ou `dirty`. O baseline e exclusivo para fresh install: nao ha ALTER, conversao ou fallback para schema antigo.
Uma base de desenvolvimento criada antes deste baseline deve ser recriada manualmente antes da homologacao; o resource nao remove nem converte colunas existentes.

## Atomicidade

Mutacoes exclusivamente digitais usam uma unica `MySQL.transaction.await` para os elementos aplicaveis:

```text
balance update(s)
+ canonical ledger leg(s)
+ idempotency/result
```

Transferencias bancarias entre Characters, fluxos Character/Organization e payroll persistem todas as pernas digitais na mesma transacao. O cache runtime so e atualizado depois do commit.

Operacoes fisicas atravessam dois owners SQL e usam a saga persistente minima `mz_money_item_sagas`. Cada passo tem operation key e fingerprint; o Inventory grava item e receipt na mesma transacao; o Economy grava estado, ledger e resultado idempotente. Estados nao terminais sao retomados periodicamente apos restart. Saques debitam o banco antes do credito fisico e compensam somente rejeicoes confirmadas; falhas ambiguas permanecem recuperaveis. Depositos debitam apenas o inventario principal e creditam o banco depois da confirmacao do receipt.

## API financeira server-side

Reads:

- `GetMoney`;
- `NormalizeMoneyAccount`;
- `GetOperationResult`;
- `GetAccountStatement` e relatorios existentes;
- contratos tipados de conta Organization, acessiveis pelo owner `mz_org`.

Mutations:

- `SetMoney`;
- `AddMoney`;
- `RemoveMoney`;
- `TransferMoneyBetweenAccounts`;
- `TransferBankBetweenPlayers`;
- `PayOrganizationSalaries`, exclusivo para `mz_org`;
- deposit, withdraw, spend e refund Organization, exclusivos para o bridge autorizado de `mz_org`.

Semantica dos contratos de Character:

- `GetMoney`: compoe `wallet=money` principal, `dirty=dirty_money` principal e `bank` digital; falha explicitamente se o Inventory estiver indisponivel;
- `AddMoney` / `RemoveMoney`: `bank` permanece digital; `wallet` e `dirty` exigem idempotencia e usam os exports protegidos do Inventory;
- `SetMoney`: permitido para `bank` e explicitamente recusado para contas fisicas;
- `TransferMoneyBetweenAccounts`: permite somente `bank <-> wallet`; nao converte dinheiro sujo;
- `TransferBankBetweenPlayers`: permanece integralmente digital.

O escopo de idempotencia usa `GetInvokingResource()` no servidor. Payload client nao escolhe `source_resource`, saldo, resultado ou autorizacao.

## Organization e payroll

`mz_org` continua owner de Organization, membership, grade, salary configuration, duty, permissions e eligibility. Ele autoriza a Organization e envia somente o descriptor e os dados de elegibilidade necessarios. `mz_economy` debita/credita contas, persiste idempotencia/receipt e ledger; ele nao consulta tabelas canonicas de Organization.

## Starter e recovery

No primeiro lifecycle do Character, o Economy cria `bank` com o valor configurado e credita `money` diretamente por uma chave fixa escopada ao `citizenid`. Reconexao e restart apenas reproduzem o resultado persistido. Creditos fisicos sem espaco utilizam `money_recovery` do Inventory; o Economy nao cria uma segunda carteira pendente.

Ao carregar o personagem, valores nesse container geram uma notificacao. O proprio jogador pode usar
`/recuperardinheiro`; o Economy resolve o `citizenid` da sessao, solicita um claim server-only e idempotente ao
Inventory e mantem qualquer valor restante protegido quando ainda nao existe espaco.

## Validacao

Os testes novos e QA canonicos ficam em `mz_testkit`. A suite `run-mz-economy-money-items-wave2.ps1` cobre starter, composicao de saldo, receipts, retries, estados da saga, compensacao, recovery, dirty money e ausencia de fallback legado. Harnesses historicos ainda presentes no resource nao sao a fonte canonica de QA. Nenhum desses harnesses substitui runtime FiveM/OneSync/MySQL.

Documentos MVP antigos em `docs/` preservam evidencia historica do periodo em que o resource era apenas ledger passivo; nao descrevem o boundary atual.
