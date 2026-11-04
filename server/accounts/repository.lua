MZAccountRepository = MZAccountRepository or {}

local ALLOWED_PLAYER_ACCOUNTS = { bank = true }

local function appendIdempotency(statements, idempotency)
  if type(idempotency) ~= 'table' then return end
  statements[#statements + 1] = {
    query = [[
      INSERT INTO mz_account_idempotency (
        source_resource, actor_citizenid, idempotency_key, operation,
        request_fingerprint, correlation_id, result_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
    ]],
    parameters = {
      idempotency.sourceResource, idempotency.actorCitizenId, idempotency.key,
      idempotency.operation, idempotency.fingerprint, idempotency.correlationId,
      idempotency.resultJson
    }
  }
end

local function appendLedger(statements, ledgerBatch)
  if type(ledgerBatch) ~= 'table' then return end
  for index, entry in ipairs(ledgerBatch.entries or {}) do
    local leg = math.floor(tonumber(entry.leg) or index)
    local prefix = tostring(ledgerBatch.correlationId or ''):sub(1, 118)
    statements[#statements + 1] = {
      query = [[
        INSERT INTO mz_economy_transactions (
          transaction_id, citizenid, license, account, amount, balance_before, balance_after,
          direction, category, reason, source_resource, source_type, counts_as_income,
          counts_as_expense, related_citizenid, related_org_code, external_ref, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]],
      parameters = {
        ('%s:%d'):format(prefix, leg),
        tostring(entry.citizenid or '') ~= '' and tostring(entry.citizenid) or nil,
        entry.license,
        entry.account,
        math.floor(tonumber(entry.amount) or 0),
        math.floor(tonumber(entry.balanceBefore) or 0),
        math.floor(tonumber(entry.balanceAfter) or 0),
        entry.direction,
        entry.category,
        entry.reason,
        ledgerBatch.sourceResource,
        ledgerBatch.sourceType,
        entry.countsAsIncome == true and 1 or 0,
        entry.countsAsExpense == true and 1 or 0,
        entry.relatedCitizenid,
        entry.relatedOrgCode,
        entry.externalRef,
        ledgerBatch.metadataJson
      }
    }
  end
end

local function runTransaction(statements, ledgerBatch)
  appendLedger(statements, ledgerBatch)
  return MySQL.transaction.await(statements) == true
end

function MZAccountRepository.getPlayerAccount(citizenid)
  return MySQL.single.await('SELECT * FROM mz_player_accounts WHERE citizenid = ? LIMIT 1', { citizenid })
end

function MZAccountRepository.getIdempotentOperation(sourceResource, actorCitizenId, idempotencyKey)
  return MySQL.single.await([[
    SELECT operation, request_fingerprint, correlation_id, result_json, created_at
    FROM mz_account_idempotency
    WHERE source_resource = ? AND actor_citizenid = ? AND idempotency_key = ?
    LIMIT 1
  ]], { sourceResource, actorCitizenId, idempotencyKey })
end

function MZAccountRepository.getMoneyItemSaga(sourceResource, actorCitizenId, operationKey)
  return MySQL.single.await([[
    SELECT * FROM mz_money_item_sagas
    WHERE source_resource = ? AND actor_citizenid = ? AND operation_key = ?
    LIMIT 1
  ]], { sourceResource, actorCitizenId, operationKey })
end

function MZAccountRepository.createMoneyItemSaga(data)
  if type(data) ~= 'table' then return nil end
  MySQL.insert.await([[
    INSERT IGNORE INTO mz_money_item_sagas (
      source_resource, actor_citizenid, operation_key, operation,
      request_fingerprint, account, from_account, to_account, item_name,
      amount, status, correlation_id, metadata_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
  ]], {
    data.sourceResource, data.actorCitizenId, data.operationKey, data.operation,
    data.fingerprint, data.account, data.fromAccount, data.toAccount, data.itemName,
    data.amount, data.correlationId, data.metadataJson
  })
  return MZAccountRepository.getMoneyItemSaga(
    data.sourceResource, data.actorCitizenId, data.operationKey
  )
end

function MZAccountRepository.listRecoverableMoneyItemSagas(limit)
  limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 50)))
  return MySQL.query.await(([=[
    SELECT * FROM mz_money_item_sagas
    WHERE status IN ('pending', 'economy_applied', 'inventory_applied', 'compensating')
    ORDER BY id ASC
    LIMIT %d
  ]=]):format(limit)) or {}
end

function MZAccountRepository.transitionMoneyItemSaga(
  sagaId, expectedStatus, nextStatus, inventoryResultJson, errorCode
)
  local affected = MySQL.update.await([[
    UPDATE mz_money_item_sagas
    SET status = ?, inventory_result_json = COALESCE(?, inventory_result_json), error_code = ?
    WHERE id = ? AND status = ?
  ]], { nextStatus, inventoryResultJson, errorCode, sagaId, expectedStatus })
  return tonumber(affected) == 1
end

function MZAccountRepository.applyMoneyItemSagaBankStep(data, ledgerBatch)
  if type(data) ~= 'table' then return false end
  return runTransaction({
    {
      query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ? AND bank = ?',
      parameters = { data.bankAfter, data.citizenid, data.bankBefore }
    },
    {
      query = [[
        UPDATE mz_money_item_sagas
        SET status = ?, bank_before = ?, bank_after = ?, error_code = NULL
        WHERE id = ? AND status = ?
      ]],
      parameters = {
        data.nextStatus, data.bankBefore, data.bankAfter, data.sagaId, data.expectedStatus
      }
    }
  }, ledgerBatch)
end

function MZAccountRepository.finalizeMoneyItemSaga(data, idempotency, ledgerBatch)
  if type(data) ~= 'table' then return false end
  local statements = {}
  if data.bankAfter ~= nil then
    statements[#statements + 1] = {
      query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ? AND bank = ?',
      parameters = { data.bankAfter, data.citizenid, data.bankBefore }
    }
  end
  appendIdempotency(statements, idempotency)
  statements[#statements + 1] = {
    query = [[
      UPDATE mz_money_item_sagas
      SET status = ?, result_json = ?, error_code = ?,
          bank_before = COALESCE(?, bank_before), bank_after = COALESCE(?, bank_after)
      WHERE id = ? AND status = ?
    ]],
    parameters = {
      data.nextStatus, data.resultJson, data.errorCode,
      data.recordBankBefore, data.recordBankAfter,
      data.sagaId, data.expectedStatus
    }
  }
  return runTransaction(statements, ledgerBatch)
end

function MZAccountRepository.updatePlayerMoneyWithLedger(citizenid, moneyType, amount, ledgerBatch)
  if not ALLOWED_PLAYER_ACCOUNTS[moneyType] then return false end
  return runTransaction({ {
    query = ('UPDATE mz_player_accounts SET %s = ? WHERE citizenid = ?'):format(moneyType),
    parameters = { amount, citizenid }
  } }, ledgerBatch)
end

function MZAccountRepository.updatePlayerMoneyIdempotent(
  citizenid, moneyType, amount, idempotency, ledgerBatch
)
  if not ALLOWED_PLAYER_ACCOUNTS[moneyType] or type(idempotency) ~= 'table' then return false end
  local statements = {}
  appendIdempotency(statements, idempotency)
  statements[#statements + 1] = {
    query = ('UPDATE mz_player_accounts SET %s = ? WHERE citizenid = ?'):format(moneyType),
    parameters = { amount, citizenid }
  }
  return runTransaction(statements, ledgerBatch)
end

function MZAccountRepository.getOrgAccountOperation(sourceResource, operationKey)
  return MySQL.single.await([[
    SELECT * FROM mz_org_account_operations
    WHERE source_resource = ? AND operation_key = ? LIMIT 1
  ]], { sourceResource, operationKey })
end

function MZAccountRepository.getOrgAccountOperationByReceipt(receiptId)
  return MySQL.single.await('SELECT * FROM mz_org_account_operations WHERE receipt_id = ? LIMIT 1', { receiptId })
end

function MZAccountRepository.getOrgAccountReversal(operationId)
  return MySQL.single.await([[
    SELECT * FROM mz_org_account_operations
    WHERE reversal_of_operation_id = ? LIMIT 1
  ]], { operationId })
end

function MZAccountRepository.createOrgAccountOperation(data)
  if type(data) ~= 'table' then return nil end
  return MySQL.insert.await([[
    INSERT INTO mz_org_account_operations (
      source_resource, operation_key, operation_type, purpose,
      org_id, org_code, actor_citizenid, amount, related_ref,
      request_fingerprint, status, error_code, reversal_of_operation_id, metadata_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], {
    data.sourceResource, data.operationKey, data.operationType, data.purpose,
    data.orgId, data.orgCode, data.actorCitizenId, data.amount, data.relatedRef,
    data.fingerprint, data.status or 'pending', data.errorCode,
    data.reversalOfOperationId, data.metadataJson
  })
end

function MZAccountRepository.rejectOrgAccountOperation(operationId, errorCode)
  local affected = MySQL.update.await([[
    UPDATE mz_org_account_operations SET status = 'rejected', error_code = ?
    WHERE id = ? AND status = 'pending'
  ]], { errorCode, operationId })
  return tonumber(affected) == 1
end

function MZAccountRepository.applyOrgAccountOperation(data, ledgerBatch)
  if type(data) ~= 'table' then return false end
  local statements = { {
    query = [[
      UPDATE mz_org_accounts org_account
      INNER JOIN mz_org_account_operations account_operation
        ON account_operation.org_id = org_account.org_id
      SET org_account.balance = ?, account_operation.status = 'applied',
          account_operation.error_code = NULL, account_operation.balance_before = ?,
          account_operation.balance_after = ?, account_operation.receipt_id = ?,
          account_operation.correlation_id = ?
      WHERE account_operation.id = ? AND account_operation.status = 'pending'
        AND org_account.balance = ?
    ]],
    parameters = {
      data.balanceAfter, data.balanceBefore, data.balanceAfter, data.receiptId,
      data.correlationId, data.operationId, data.balanceBefore
    }
  } }
  return runTransaction(statements, ledgerBatch)
end

function MZAccountRepository.transferPlayerBankAndOrg(
  citizenid, playerBankAmount, orgId, orgBalanceAmount, ledgerBatch, idempotency
)
  local statements = {}
  appendIdempotency(statements, idempotency)
  statements[#statements + 1] = {
    query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ?',
    parameters = { playerBankAmount, citizenid }
  }
  statements[#statements + 1] = {
    query = 'UPDATE mz_org_accounts SET balance = ? WHERE org_id = ?',
    parameters = { orgBalanceAmount, orgId }
  }
  return runTransaction(statements, ledgerBatch)
end

function MZAccountRepository.transferBankBetweenPlayers(
  senderCitizenId, senderAmount, targetCitizenId, targetAmount, ledgerBatch
)
  return runTransaction({
    { query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ?', parameters = { senderAmount, senderCitizenId } },
    { query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ?', parameters = { targetAmount, targetCitizenId } }
  }, ledgerBatch)
end

function MZAccountRepository.transferBankBetweenPlayersIdempotent(
  senderCitizenId, senderAmount, targetCitizenId, targetAmount, idempotency, ledgerBatch
)
  local statements = {}
  appendIdempotency(statements, idempotency)
  statements[#statements + 1] = {
    query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ?',
    parameters = { senderAmount, senderCitizenId }
  }
  statements[#statements + 1] = {
    query = 'UPDATE mz_player_accounts SET bank = ? WHERE citizenid = ?',
    parameters = { targetAmount, targetCitizenId }
  }
  return runTransaction(statements, ledgerBatch)
end
