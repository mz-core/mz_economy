MZMoneyItemsService = MZMoneyItemsService or {}

local MAX_SAFE_INTEGER = 9007199254740991
local TERMINAL_STATUS = { completed = true, compensated = true, rejected = true, failed_manual = true }
local PHYSICAL_ITEMS = { wallet = 'money', dirty = 'dirty_money' }
local PERMANENT_INVENTORY_ERRORS = {
  invalid_money_request = true,
  invalid_money_amount = true,
  money_amount_overflow = true,
  operation_key_conflict = true,
  resource_not_authorized = true
}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function decode(value, fallback)
  local ok, result = pcall(json.decode, tostring(value or ''))
  return ok and type(result) == 'table' and result or (fallback or {})
end

local function encode(value)
  local ok, result = pcall(json.encode, value)
  return ok and type(result) == 'string' and result or nil
end

local function settings()
  return Config and Config.Economy and Config.Economy.PhysicalMoney or {}
end

local function enabled()
  return settings().Enabled == true
end

local function inventoryReady()
  local resourceName = trim(settings().InventoryResource)
  if resourceName == '' then resourceName = 'mz_inventory' end
  return resourceName == 'mz_inventory'
    and type(GetResourceState) == 'function'
    and GetResourceState(resourceName) == 'started'
end

local function inventoryCall(name, ...)
  if not enabled() then return false, 'physical_money_disabled' end
  if not inventoryReady() then return false, 'inventory_unavailable' end
  local args = table.pack(...)
  local called, ok, result = pcall(function()
    if name == 'get' then
      return exports['mz_inventory']:GetMoneyItemAmount(args[1], args[2], 'main')
    elseif name == 'get_recovery' then
      return exports['mz_inventory']:GetMoneyItemAmount(args[1], args[2], 'money_recovery')
    elseif name == 'credit' then
      return exports['mz_inventory']:CreditMoneyItem(args[1], args[2], args[3], args[4])
    elseif name == 'debit' then
      return exports['mz_inventory']:DebitMoneyItem(args[1], args[2], args[3], args[4])
    elseif name == 'claim' then
      return exports['mz_inventory']:ClaimMoneyRecovery(args[1], args[2], args[3], args[4])
    elseif name == 'receipt' then
      return exports['mz_inventory']:GetMoneyItemReceipt(args[1])
    end
    error('unsupported inventory money operation')
  end)
  if not called then return false, 'inventory_unavailable' end
  return ok == true, result
end

local function inventoryOperationKey(row, suffix)
  return ('mzmi:%s:%s'):format(tostring(row.id), tostring(suffix or 'apply'))
end

local function inventoryFingerprint(row, action)
  return ('mzmi:%s:%s:%s:%s'):format(
    tostring(row.id), tostring(action), tostring(row.item_name), tostring(row.amount)
  )
end

local function metadataFromOptions(options, defaults)
  options = type(options) == 'table' and options or {}
  defaults = type(defaults) == 'table' and defaults or {}
  local metadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(options, defaults)
  return {
    reason = metadata.reason,
    category = metadata.category,
    source_type = metadata.source_type,
    related_citizenid = metadata.related_citizenid,
    related_org_code = metadata.related_org_code,
    external_ref = metadata.external_ref,
    counts_as_income = metadata.counts_as_income,
    counts_as_expense = metadata.counts_as_expense,
    data = metadata.data
  }
end

local function optionsFromRow(row)
  local metadata = decode(row.metadata_json, {})
  return {
    __invokingResource = tostring(row.source_resource),
    reason = metadata.reason,
    category = metadata.category,
    source_type = metadata.source_type,
    related_citizenid = metadata.related_citizenid,
    related_org_code = metadata.related_org_code,
    external_ref = metadata.external_ref,
    counts_as_income = metadata.counts_as_income,
    counts_as_expense = metadata.counts_as_expense,
    data = metadata.data
  }, metadata
end

local function makeIdempotency(row, result)
  return {
    sourceResource = tostring(row.source_resource),
    actorCitizenId = tostring(row.actor_citizenid),
    key = tostring(row.operation_key),
    operation = tostring(row.operation),
    fingerprint = tostring(row.request_fingerprint),
    correlationId = tostring(row.correlation_id),
    resultJson = assert(encode(result), 'idempotency_result_encode_failed')
  }
end

local function resultFromTerminalRow(row)
  local result = decode(row.result_json, {})
  result.ok = result.ok == true
  result.error = result.ok and nil or (result.error or row.error_code or 'operation_failed')
  result.transactionRef = tostring(row.correlation_id or result.transactionRef or '')
  result.correlationId = result.transactionRef
  result.replayed = true
  return result
end

local function refreshSaga(row)
  return MZAccountRepository.getMoneyItemSaga(
    tostring(row.source_resource), tostring(row.actor_citizenid), tostring(row.operation_key)
  )
end

local function syncBankCache(citizenid, amount)
  if not MZEconomyCore or type(MZEconomyCore.getPlayerByCitizenId) ~= 'function' then return end
  local player = MZEconomyCore.getPlayerByCitizenId(citizenid)
  if player then
    player.money = player.money or {}
    player.money.bank = math.floor(tonumber(amount) or 0)
  end
end

local function ledgerBatch(row, eventType, account, amount, entries)
  local options, metadata = optionsFromRow(row)
  return MZAccountService.BuildFinancialLedgerBatchInternal({
    correlationId = tostring(row.correlation_id),
    idempotency = {
      sourceResource = tostring(row.source_resource),
      actorCitizenId = tostring(row.actor_citizenid),
      key = tostring(row.operation_key),
      operation = tostring(row.operation)
    },
    eventType = eventType,
    sourceCitizenId = tostring(row.actor_citizenid),
    account = account,
    amount = amount,
    fee = 0,
    reason = metadata.reason or eventType,
    ledgerMetadata = metadata,
    options = options,
    entries = entries
  })
end

local function ledgerEntry(row, leg, account, direction, amount, beforeAmount, afterAmount)
  local _, metadata = optionsFromRow(row)
  return MZAccountService.BuildFinancialLedgerEntryInternal(
    leg, tostring(row.actor_citizenid), account, direction, amount,
    beforeAmount, afterAmount, metadata
  )
end

local function rejectSaga(row, errorCode)
  local result = {
    ok = false,
    error = errorCode,
    transactionRef = tostring(row.correlation_id),
    correlationId = tostring(row.correlation_id),
    replayed = false
  }
  local persisted = MZAccountRepository.finalizeMoneyItemSaga({
    sagaId = row.id,
    expectedStatus = tostring(row.status),
    nextStatus = 'rejected',
    resultJson = assert(encode(result), 'saga_result_encode_failed'),
    errorCode = errorCode
  }, makeIdempotency(row, result), nil)
  if not persisted then return { ok = false, error = 'database_error' } end
  return result
end

local function recordTransient(row, errorCode)
  MZAccountRepository.transitionMoneyItemSaga(
    row.id, tostring(row.status), tostring(row.status), nil, errorCode
  )
  return { ok = false, error = 'operation_recovering', state = tostring(row.status) }
end

local function applyInventory(row, action, nextStatus)
  local ok, resultOrErr = inventoryCall(
    action,
    tostring(row.actor_citizenid),
    tostring(row.item_name),
    math.floor(tonumber(row.amount) or 0),
    {
      operationKey = inventoryOperationKey(row, 'apply'),
      fingerprint = inventoryFingerprint(row, action)
    }
  )
  if not ok and resultOrErr == 'database_error' then
    local receiptOk, receipt = inventoryCall('receipt', inventoryOperationKey(row, 'apply'))
    if receiptOk and type(receipt) == 'table'
      and tostring(receipt.fingerprint) == inventoryFingerprint(row, action)
      and tostring(receipt.citizenid) == tostring(row.actor_citizenid)
      and tostring(receipt.item) == tostring(row.item_name)
      and tostring(receipt.operation) == action
      and tonumber(receipt.amount) == tonumber(row.amount) then
      ok, resultOrErr = true, receipt
    end
  end
  if not ok then return false, resultOrErr end
  local resultJson = encode(resultOrErr)
  if not resultJson then return false, 'database_error' end
  local transitioned = MZAccountRepository.transitionMoneyItemSaga(
    row.id, tostring(row.status), nextStatus, resultJson, nil
  )
  if not transitioned then
    local current = refreshSaga(row)
    if current and tostring(current.status) == nextStatus then return true, current end
    return false, 'database_error'
  end
  return true, refreshSaga(row)
end

local function physicalBalances(citizenid)
  if not enabled() then return nil, 'physical_money_disabled' end
  local moneyOk, wallet = inventoryCall('get', citizenid, 'money')
  if not moneyOk then return nil, wallet end
  local dirtyOk, dirty = inventoryCall('get', citizenid, 'dirty_money')
  if not dirtyOk then return nil, dirty end
  return {
    wallet = math.floor(tonumber(wallet) or 0),
    dirty = math.floor(tonumber(dirty) or 0)
  }
end

function MZMoneyItemsService.getMoney(source)
  local player = MZEconomyCore.getPlayer(source)
  if not player then return nil, 'player_not_loaded' end
  local physical, physicalErr = physicalBalances(player.citizenid)
  if not physical then return nil, physicalErr end
  return {
    wallet = physical.wallet,
    bank = math.floor(tonumber((player.money or {}).bank) or 0),
    dirty = physical.dirty
  }
end

function MZMoneyItemsService.getPendingRecovery(source)
  if not enabled() then return nil, 'physical_money_disabled' end
  local player = MZEconomyCore.getPlayer(source)
  if not player then return nil, 'player_not_loaded' end

  local pending = { money = 0, dirty_money = 0, total = 0 }
  for _, itemName in ipairs({ 'money', 'dirty_money' }) do
    local ok, amountOrErr = inventoryCall('get_recovery', player.citizenid, itemName)
    if not ok then return nil, amountOrErr end
    local amount = math.floor(tonumber(amountOrErr) or 0)
    pending[itemName] = amount
    pending.total = pending.total + amount
  end
  return pending
end

local function claimRecoveryItem(citizenid, itemName, amount)
  local operationKey = MZAccountService.GenerateFinancialTransactionRefInternal('mzmi-claim')
  local fingerprint = 'claim:' .. operationKey
  local options = { operationKey = operationKey, fingerprint = fingerprint }
  local ok, resultOrErr = inventoryCall('claim', citizenid, itemName, amount, options)

  if not ok and resultOrErr == 'database_error' then
    local receiptOk, receipt = inventoryCall('receipt', operationKey)
    if receiptOk and type(receipt) == 'table'
      and tostring(receipt.fingerprint) == fingerprint
      and tostring(receipt.citizenid) == citizenid
      and tostring(receipt.item) == itemName
      and tostring(receipt.operation) == 'claim'
      and tonumber(receipt.amount) == amount then
      ok, resultOrErr = true, receipt
    end
  end

  if not ok then return false, resultOrErr end
  if type(resultOrErr) ~= 'table'
    or tostring(resultOrErr.citizenid) ~= citizenid
    or tostring(resultOrErr.item) ~= itemName
    or tostring(resultOrErr.operation) ~= 'claim'
    or tonumber(resultOrErr.amount) ~= amount then
    return false, 'inventory_receipt_invalid'
  end
  return true, resultOrErr
end

function MZMoneyItemsService.claimRecovery(source)
  if not enabled() then return false, { error = 'physical_money_disabled' } end
  local player = MZEconomyCore.getPlayer(source)
  if not player then return false, { error = 'player_not_loaded' } end

  local locked, resultOrErr = MZAccountService.WithFinancialLocksInternal(
    { player.citizenid },
    function()
      local pending, pendingErr = MZMoneyItemsService.getPendingRecovery(source)
      if not pending then return true, { ok = false, error = pendingErr } end

      local result = {
        ok = true,
        claimed = { money = 0, dirty_money = 0 },
        total = 0,
        remaining = pending
      }
      for _, itemName in ipairs({ 'money', 'dirty_money' }) do
        local amount = math.floor(tonumber(pending[itemName]) or 0)
        if amount > 0 then
          local claimed, claimOrErr = claimRecoveryItem(player.citizenid, itemName, amount)
          if not claimed then
            result.ok = false
            result.error = claimOrErr or 'money_recovery_failed'
            local remaining = MZMoneyItemsService.getPendingRecovery(source)
            result.remaining = remaining or result.remaining
            return true, result
          end
          result.claimed[itemName] = amount
          result.total = result.total + amount
        end
      end
      result.remaining = MZMoneyItemsService.getPendingRecovery(source) or {
        money = 0, dirty_money = 0, total = 0
      }
      return true, result
    end
  )
  if not locked then return false, { error = resultOrErr or 'account_busy' } end
  return resultOrErr.ok == true, resultOrErr
end

local function completePhysicalMutation(row)
  local inventoryResult = decode(row.inventory_result_json, {})
  local amount = math.floor(tonumber(row.amount) or 0)
  local account = tostring(row.account)
  local afterAmount = math.floor(tonumber(inventoryResult.mainBalance) or 0)
  local isCredit = tostring(row.operation) == 'add_money' or tostring(row.operation) == 'starter_money'
  local mainCredit = isCredit and inventoryResult.recoveryPending ~= true
  local beforeAmount = isCredit and (mainCredit and afterAmount - amount or afterAmount)
    or afterAmount + amount
  local direction = isCredit and 'in' or 'out'
  local entry = ledgerEntry(row, 1, account, direction, amount, beforeAmount, afterAmount)
  local batch, batchErr = ledgerBatch(row, tostring(row.operation), account, amount, { entry })
  if batch == false then return { ok = false, error = batchErr } end
  local result = {
    ok = true,
    transactionRef = tostring(row.correlation_id),
    correlationId = tostring(row.correlation_id),
    replayed = false,
    recoveryPending = inventoryResult.recoveryPending == true,
    balance = afterAmount
  }
  local persisted = MZAccountRepository.finalizeMoneyItemSaga({
    sagaId = row.id,
    expectedStatus = 'inventory_applied',
    nextStatus = 'completed',
    resultJson = assert(encode(result), 'saga_result_encode_failed')
  }, makeIdempotency(row, result), batch)
  if not persisted then return { ok = false, error = 'operation_recovering', state = 'inventory_applied' } end
  return result
end

local function applyWithdrawBank(row)
  local account = MZAccountRepository.getPlayerAccount(tostring(row.actor_citizenid))
  if not account then return { ok = false, error = 'database_error' } end
  local beforeAmount = math.floor(tonumber(account.bank) or 0)
  local amount = math.floor(tonumber(row.amount) or 0)
  if beforeAmount < amount then return rejectSaga(row, 'not_enough_money') end
  local afterAmount = beforeAmount - amount
  local entry = ledgerEntry(row, 1, 'bank', 'out', amount, beforeAmount, afterAmount)
  local batch, batchErr = ledgerBatch(row, 'transfer_between_accounts', 'bank', amount, { entry })
  if batch == false then return { ok = false, error = batchErr } end
  local persisted = MZAccountRepository.applyMoneyItemSagaBankStep({
    sagaId = row.id,
    citizenid = tostring(row.actor_citizenid),
    expectedStatus = 'pending',
    nextStatus = 'economy_applied',
    bankBefore = beforeAmount,
    bankAfter = afterAmount
  }, batch)
  if not persisted then return { ok = false, error = 'database_error' } end
  syncBankCache(tostring(row.actor_citizenid), afterAmount)
  return { ok = false, error = 'operation_recovering', state = 'economy_applied' }
end

local function compensateWithdraw(row, originalError)
  local account = MZAccountRepository.getPlayerAccount(tostring(row.actor_citizenid))
  local currentBank = account and math.floor(tonumber(account.bank) or -1) or -1
  local amount = math.floor(tonumber(row.amount) or 0)
  if currentBank < 0 or amount <= 0 or currentBank > MAX_SAFE_INTEGER - amount then
    return { ok = false, error = 'operation_recovering', state = 'compensating' }
  end
  local compensatedBank = currentBank + amount
  local result = {
    ok = false,
    error = originalError or row.error_code or 'inventory_credit_rejected',
    compensated = true,
    transactionRef = tostring(row.correlation_id),
    correlationId = tostring(row.correlation_id),
    replayed = false
  }
  local entry = ledgerEntry(row, 3, 'bank', 'in', amount, currentBank, compensatedBank)
  local batch, batchErr = ledgerBatch(row, 'transfer_between_accounts_compensation', 'bank', amount, { entry })
  if batch == false then return { ok = false, error = batchErr } end
  local persisted = MZAccountRepository.finalizeMoneyItemSaga({
    sagaId = row.id,
    citizenid = tostring(row.actor_citizenid),
    expectedStatus = 'compensating',
    nextStatus = 'compensated',
    bankBefore = currentBank,
    bankAfter = compensatedBank,
    resultJson = assert(encode(result), 'saga_result_encode_failed'),
    errorCode = result.error
  }, makeIdempotency(row, result), batch)
  if not persisted then return { ok = false, error = 'operation_recovering', state = 'compensating' } end
  syncBankCache(tostring(row.actor_citizenid), compensatedBank)
  return result
end

local function completeWithdraw(row)
  local inventoryResult = decode(row.inventory_result_json, {})
  local amount = math.floor(tonumber(row.amount) or 0)
  local afterAmount = math.floor(tonumber(inventoryResult.mainBalance) or 0)
  local beforeAmount = inventoryResult.recoveryPending == true and afterAmount or afterAmount - amount
  local entry = ledgerEntry(row, 2, 'wallet', 'in', amount, beforeAmount, afterAmount)
  local batch, batchErr = ledgerBatch(row, 'transfer_between_accounts', 'multi', amount, { entry })
  if batch == false then return { ok = false, error = batchErr } end
  local result = {
    ok = true,
    transactionRef = tostring(row.correlation_id),
    correlationId = tostring(row.correlation_id),
    replayed = false,
    recoveryPending = inventoryResult.recoveryPending == true,
    balances = { bank = tonumber(row.bank_after), wallet = afterAmount }
  }
  local persisted = MZAccountRepository.finalizeMoneyItemSaga({
    sagaId = row.id,
    expectedStatus = 'inventory_applied',
    nextStatus = 'completed',
    resultJson = assert(encode(result), 'saga_result_encode_failed')
  }, makeIdempotency(row, result), batch)
  if not persisted then return { ok = false, error = 'operation_recovering', state = 'inventory_applied' } end
  return result
end

local function completeDeposit(row)
  local inventoryResult = decode(row.inventory_result_json, {})
  local account = MZAccountRepository.getPlayerAccount(tostring(row.actor_citizenid))
  if not account then return { ok = false, error = 'operation_recovering', state = 'inventory_applied' } end
  local amount = math.floor(tonumber(row.amount) or 0)
  local bankBefore = math.floor(tonumber(account.bank) or 0)
  if bankBefore > MAX_SAFE_INTEGER - amount then
    return { ok = false, error = 'operation_recovering', state = 'inventory_applied' }
  end
  local bankAfter = bankBefore + amount
  local walletAfter = math.floor(tonumber(inventoryResult.mainBalance) or 0)
  local entries = {
    ledgerEntry(row, 1, 'wallet', 'out', amount, walletAfter + amount, walletAfter),
    ledgerEntry(row, 2, 'bank', 'in', amount, bankBefore, bankAfter)
  }
  local batch, batchErr = ledgerBatch(row, 'transfer_between_accounts', 'multi', amount, entries)
  if batch == false then return { ok = false, error = batchErr } end
  local result = {
    ok = true,
    transactionRef = tostring(row.correlation_id),
    correlationId = tostring(row.correlation_id),
    replayed = false,
    balances = { bank = bankAfter, wallet = walletAfter }
  }
  local persisted = MZAccountRepository.finalizeMoneyItemSaga({
    sagaId = row.id,
    citizenid = tostring(row.actor_citizenid),
    expectedStatus = 'inventory_applied',
    nextStatus = 'completed',
    bankBefore = bankBefore,
    bankAfter = bankAfter,
    recordBankBefore = bankBefore,
    recordBankAfter = bankAfter,
    resultJson = assert(encode(result), 'saga_result_encode_failed')
  }, makeIdempotency(row, result), batch)
  if not persisted then return { ok = false, error = 'operation_recovering', state = 'inventory_applied' } end
  syncBankCache(tostring(row.actor_citizenid), bankAfter)
  return result
end

local function resumeUnlocked(row)
  row = refreshSaga(row) or row
  if TERMINAL_STATUS[tostring(row.status)] then return resultFromTerminalRow(row) end

  local operation = tostring(row.operation)
  if operation == 'add_money' or operation == 'remove_money' or operation == 'starter_money' then
    if tostring(row.status) == 'pending' then
      local action = operation == 'remove_money' and 'debit' or 'credit'
      local applied, resultOrErr = applyInventory(row, action, 'inventory_applied')
      if not applied then
        local mapped = (resultOrErr == 'not_enough_items' or resultOrErr == 'not_enough_amount')
          and 'not_enough_money' or resultOrErr
        if mapped == 'not_enough_money' or PERMANENT_INVENTORY_ERRORS[mapped] then
          return rejectSaga(row, mapped)
        end
        return recordTransient(row, mapped)
      end
      row = resultOrErr
    end
    if tostring(row.status) == 'inventory_applied' then return completePhysicalMutation(row) end
  elseif operation == 'transfer_between_accounts' then
    local fromAccount = tostring(row.from_account)
    if fromAccount == 'bank' then
      if tostring(row.status) == 'pending' then
        local result = applyWithdrawBank(row)
        if result.error ~= 'operation_recovering' then return result end
        row = refreshSaga(row)
      end
      if tostring(row.status) == 'economy_applied' then
        local applied, resultOrErr = applyInventory(row, 'credit', 'inventory_applied')
        if not applied then
          if PERMANENT_INVENTORY_ERRORS[resultOrErr] then
            local transitioned = MZAccountRepository.transitionMoneyItemSaga(
              row.id, 'economy_applied', 'compensating', nil, resultOrErr
            )
            if not transitioned then return recordTransient(row, resultOrErr) end
            row = refreshSaga(row)
          else
            return recordTransient(row, resultOrErr)
          end
        else
          row = resultOrErr
        end
      end
      if tostring(row.status) == 'inventory_applied' then return completeWithdraw(row) end
      if tostring(row.status) == 'compensating' then return compensateWithdraw(row) end
    else
      if tostring(row.status) == 'pending' then
        local applied, resultOrErr = applyInventory(row, 'debit', 'inventory_applied')
        if not applied then
          local mapped = (resultOrErr == 'not_enough_items' or resultOrErr == 'not_enough_amount')
            and 'not_enough_money' or resultOrErr
          if mapped == 'not_enough_money' or PERMANENT_INVENTORY_ERRORS[mapped] then
            return rejectSaga(row, mapped)
          end
          return recordTransient(row, mapped)
        end
        row = resultOrErr
      end
      if tostring(row.status) == 'inventory_applied' then return completeDeposit(row) end
    end
  end

  return { ok = false, error = 'operation_recovering', state = tostring(row.status) }
end

local function resume(row)
  local ok, resultOrErr = MZAccountService.WithFinancialLocksInternal(
    { tostring(row.actor_citizenid) },
    function() return true, resumeUnlocked(row) end
  )
  if not ok then return { ok = false, error = resultOrErr or 'account_busy' } end
  return resultOrErr
end

local function createOrLoadSaga(args)
  local metadataJson = encode(args.metadata)
  if not metadataJson then return nil, 'invalid_metadata' end
  local callOk, row = pcall(MZAccountRepository.createMoneyItemSaga, {
      sourceResource = args.sourceResource,
      actorCitizenId = args.citizenid,
      operationKey = args.operationKey,
      operation = args.operation,
      fingerprint = args.fingerprint,
      account = args.account,
      fromAccount = args.fromAccount,
      toAccount = args.toAccount,
      itemName = args.itemName,
      amount = args.amount,
      correlationId = args.correlationId,
      metadataJson = metadataJson
    })
  if not callOk then return nil, 'database_error' end
  if not row then return nil, 'database_error' end
  if tostring(row.operation) ~= args.operation
    or tostring(row.request_fingerprint) ~= args.fingerprint then
    return nil, 'idempotency_conflict'
  end
  return row
end

local function validateOperationOptions(options)
  options = type(options) == 'table' and options or {}
  local operationKey = trim(options.idempotency_key or options.idempotencyKey)
  if operationKey == '' then return nil, nil, 'idempotency_key_required' end
  if #operationKey < 16 or #operationKey > 64 or not operationKey:match('^[%w_-]+$') then
    return nil, nil, 'invalid_idempotency_key'
  end
  local sourceResource = trim(options.__invokingResource)
  if sourceResource == '' or sourceResource == 'unknown' or #sourceResource > 100 then
    return nil, nil, 'invalid_idempotency_scope'
  end
  return operationKey, sourceResource
end

function MZMoneyItemsService.mutate(source, account, amount, options, operation)
  if not enabled() then return false, 'physical_money_disabled' end
  local player = MZEconomyCore.getPlayer(source)
  if not player then return false, 'player_not_loaded' end
  local itemName = PHYSICAL_ITEMS[account]
  if not itemName then return false, 'invalid_money_type' end
  local operationKey, sourceResource, optionErr = validateOperationOptions(options)
  if not operationKey then return false, optionErr end
  local fingerprint = ('account=%s;amount=%d'):format(account, amount)
  local metadata = metadataFromOptions(options, {
    reason = operation,
    category = 'unknown',
    sourceType = 'economy_mutation',
    sourceResource = sourceResource
  })
  local row, rowErr = createOrLoadSaga({
    sourceResource = sourceResource,
    citizenid = tostring(player.citizenid),
    operationKey = operationKey,
    operation = operation,
    fingerprint = fingerprint,
    account = account,
    itemName = itemName,
    amount = amount,
    correlationId = trim(options.external_ref or options.externalRef) ~= ''
      and trim(options.external_ref or options.externalRef)
      or MZAccountService.GenerateFinancialTransactionRefInternal('mzmi-' .. operation),
    metadata = metadata
  })
  if not row then return false, rowErr end
  local result = resume(row)
  return result.ok == true, result.ok == true and nil or result.error
end

function MZMoneyItemsService.transfer(source, fromAccount, toAccount, amount, options)
  if not enabled() then return { ok = false, error = 'physical_money_disabled' } end
  if (fromAccount ~= 'bank' and fromAccount ~= 'wallet')
    or (toAccount ~= 'bank' and toAccount ~= 'wallet')
    or fromAccount == toAccount then
    return { ok = false, error = 'unsupported_account_transfer' }
  end
  local player = MZEconomyCore.getPlayer(source)
  if not player then return { ok = false, error = 'player_not_loaded' } end
  local operationKey, sourceResource, optionErr = validateOperationOptions(options)
  if not operationKey then return { ok = false, error = optionErr } end
  local fingerprint = ('from=%s;to=%s;amount=%d'):format(fromAccount, toAccount, amount)
  local metadata = metadataFromOptions(options, {
    reason = 'transfer_between_accounts',
    category = 'unknown',
    sourceType = 'economy_mutation',
    sourceResource = sourceResource
  })
  local row, rowErr = createOrLoadSaga({
    sourceResource = sourceResource,
    citizenid = tostring(player.citizenid),
    operationKey = operationKey,
    operation = 'transfer_between_accounts',
    fingerprint = fingerprint,
    account = 'wallet',
    fromAccount = fromAccount,
    toAccount = toAccount,
    itemName = 'money',
    amount = amount,
    correlationId = trim(options.external_ref or options.externalRef) ~= ''
      and trim(options.external_ref or options.externalRef)
      or MZAccountService.GenerateFinancialTransactionRefInternal('mzmi-transfer'),
    metadata = metadata
  })
  if not row then return { ok = false, error = rowErr } end
  return resume(row)
end

function MZMoneyItemsService.ensureStarterMoney(citizenid)
  if not enabled() then return false, 'physical_money_disabled' end
  citizenid = trim(citizenid)
  if citizenid == '' then return false, 'invalid_citizenid' end
  local configured = Config and Config.Economy and Config.Economy.StarterMoney or {}
  local amount = math.floor(tonumber(configured.money) or 0)
  if amount <= 0 then return true end
  local operationKey = 'starter_money_v1'
  local row, rowErr = createOrLoadSaga({
    sourceResource = 'mz_economy',
    citizenid = citizenid,
    operationKey = operationKey,
    operation = 'starter_money',
    fingerprint = ('account=wallet;amount=%d'):format(amount),
    account = 'wallet',
    itemName = 'money',
    amount = amount,
    correlationId = MZAccountService.GenerateFinancialTransactionRefInternal('mzmi-starter'),
    metadata = metadataFromOptions({
      __invokingResource = 'mz_economy',
      reason = 'starter_money',
      category = 'starter',
      source_type = 'system'
    }, {})
  })
  if not row then return false, rowErr end
  local result = resume(row)
  return result.ok == true, result.error
end

function MZMoneyItemsService.getPendingOperationResult(citizenid, sourceResource, operationKey, operation)
  local row = MZAccountRepository.getMoneyItemSaga(sourceResource, citizenid, operationKey)
  if not row then return nil end
  if tostring(row.operation) ~= tostring(operation) then
    return { ok = false, error = 'idempotency_conflict' }
  end
  if TERMINAL_STATUS[tostring(row.status)] then
    return {
      ok = true,
      found = true,
      operation = tostring(row.operation),
      correlationId = tostring(row.correlation_id),
      result = resultFromTerminalRow(row)
    }
  end
  return {
    ok = false,
    error = 'operation_recovering',
    state = tostring(row.status),
    correlationId = tostring(row.correlation_id)
  }
end

CreateThread(function()
  while not (MZEconomyState and MZEconomyState.ready == true) do Wait(250) end
  while true do
    if enabled() and inventoryReady() then
      local ok, rows = pcall(MZAccountRepository.listRecoverableMoneyItemSagas, 50)
      if ok then
        for _, row in ipairs(rows or {}) do
          local resumedOk, err = pcall(resume, row)
          if not resumedOk then
            print(('[mz_economy][money_items] recovery failed saga=%s error=%s'):format(
              tostring(row.id), tostring(err)
            ))
          end
        end
      end
    end
    Wait(math.max(1000, math.floor(tonumber(settings().RecoveryIntervalMs) or 15000)))
  end
end)
