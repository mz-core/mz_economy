MZAccountService = MZAccountService or {}

local AccountLocks = {}
local LOCK_TIMEOUT_MS = 10000
local MAX_SAFE_INTEGER = 9007199254740991
local FINANCIAL_LEDGER_METADATA_MAX_BYTES = 32768

local FINANCIAL_LEDGER_CHANNELS = {
  atm = true,
  branch = true,
  system = true,
  resource = true,
  admin = true,
  payroll = true,
  org = true
}

local MONEY_ACCOUNT_ALIASES = {
  cash = 'wallet',
  money = 'wallet',
  wallet = 'wallet',
  bank = 'bank',
  dirty = 'dirty',
  black_money = 'dirty'
}

local function trim(value)
  local text = tostring(value or '')
  text = text:gsub('^%s+', '')
  text = text:gsub('%s+$', '')
  return text
end

local function normalizeMoneyType(moneyType)
  local account = trim(moneyType):lower()
  return MONEY_ACCOUNT_ALIASES[account] or account
end

function MZAccountService.NormalizeMoneyAccount(moneyType)
  local account = normalizeMoneyType(moneyType)
  if account ~= 'wallet' and account ~= 'bank' and account ~= 'dirty' then
    return nil, 'invalid_money_type'
  end

  return account
end

local function boolValue(value)
  if value == true or value == 1 then return true end
  local normalized = trim(value):lower()
  return normalized == 'true' or normalized == '1' or normalized == 'yes' or normalized == 'sim'
end

local function cloneTable(value)
  if type(value) ~= 'table' then return value end

  local out = {}
  for key, item in pairs(value) do
    out[key] = cloneTable(item)
  end
  return out
end

local function generateTransactionRef(prefix)
  return ('%s-%s-%s-%06d'):format(
    tostring(prefix or 'mzacc'),
    tostring(os.time()),
    tostring(type(GetGameTimer) == 'function' and GetGameTimer() or 0),
    math.random(0, 999999)
  )
end

local function normalizeLockKeys(keys)
  local seen = {}
  local out = {}

  for _, value in ipairs(keys or {}) do
    local key = tostring(value or '')
    if key ~= '' and not seen[key] then
      seen[key] = true
      out[#out + 1] = key
    end
  end

  table.sort(out)
  return out
end

local function acquireAccountLocks(keys)
  keys = normalizeLockKeys(keys)
  local startedAt = type(GetGameTimer) == 'function' and GetGameTimer() or 0

  while true do
    local available = true
    for _, key in ipairs(keys) do
      if AccountLocks[key] then
        available = false
        break
      end
    end

    if available then
      for _, key in ipairs(keys) do
        AccountLocks[key] = true
      end
      return true, keys
    end

    local now = type(GetGameTimer) == 'function' and GetGameTimer() or startedAt
    if now - startedAt >= LOCK_TIMEOUT_MS then
      return false, 'account_busy'
    end

    Wait(0)
  end
end

local function releaseAccountLocks(keys)
  for _, key in ipairs(keys or {}) do
    AccountLocks[key] = nil
  end
end

local function withAccountLocks(keys, handler)
  local acquired, lockKeysOrErr = acquireAccountLocks(keys)
  if not acquired then
    return false, lockKeysOrErr
  end

  local results = table.pack(pcall(handler))
  releaseAccountLocks(lockKeysOrErr)

  if results[1] ~= true then
    print(('[mz_economy][accounts] locked operation failed: %s'):format(tostring(results[2])))
    return false, 'database_error'
  end

  return table.unpack(results, 2, results.n)
end

local function getInvokingResourceSafe()
  if type(GetInvokingResource) ~= 'function' then return nil end

  local ok, resource = pcall(GetInvokingResource)
  if ok and trim(resource) ~= '' then
    return trim(resource)
  end

  return nil
end

local function debugLedger(message)
  if Config and Config.Economy and Config.Economy.Debug == true then
    print(('[mz_economy][accounts][ledger] %s'):format(tostring(message)))
  end
end

local function normalizeLedgerOptions(options, defaults)
  defaults = type(defaults) == 'table' and defaults or {}

  local rawMetadata = options and options.__rawMetadata or nil
  if options ~= nil and type(options) ~= 'table' then
    rawMetadata = options
    options = {}
  end

  options = type(options) == 'table' and cloneTable(options) or {}

  local data = {}
  if type(options.data) == 'table' then
    data = cloneTable(options.data)
  elseif type(options.meta) == 'table' then
    data = cloneTable(options.meta)
  elseif rawMetadata ~= nil then
    data.raw_metadata = tostring(rawMetadata)
    data.raw_metadata_type = type(rawMetadata)
    debugLedger('metadata nao-tabela normalizada')
  end

  local category = trim(options.category)
  if category == '' then
    category = trim(defaults.category)
  end
  if category == '' then category = 'unknown' end

  local reason = trim(options.reason)
  if reason == '' then
    reason = trim(defaults.reason)
  end
  if reason == '' then reason = 'legacy_call' end

  local sourceResource = trim(options.source_resource or options.sourceResource or options.__invokingResource)
  if sourceResource == '' then
    sourceResource = getInvokingResourceSafe() or ''
  end
  if sourceResource == '' then
    sourceResource = trim(defaults.sourceResource)
  end
  if sourceResource == '' then sourceResource = 'mz_economy' end

  local sourceType = trim(options.source_type or options.sourceType)
  if sourceType == '' then
    sourceType = trim(defaults.sourceType)
  end
  if sourceType == '' then sourceType = 'economy_mutation' end

  local relatedOrgCode = trim(options.related_org_code or options.relatedOrgCode)
  if relatedOrgCode == '' and sourceType == 'org_account' then
    relatedOrgCode = trim(options.sourceRef or options.source_ref)
  end

  local externalRef = trim(options.external_ref or options.externalRef or options.sourceRef or options.source_ref)

  return {
    reason = reason,
    category = category,
    source_resource = sourceResource,
    source_type = sourceType,
    counts_as_income = boolValue(options.counts_as_income or options.countsAsIncome),
    counts_as_expense = boolValue(options.counts_as_expense or options.countsAsExpense),
    related_citizenid = trim(options.related_citizenid or options.relatedCitizenid or options.relatedCitizenId),
    related_org_code = relatedOrgCode,
    external_ref = externalRef,
    data = data,
    original = options
  }
end

local function normalizeServiceOptions(options)
  if type(options) == 'table' then
    return cloneTable(options)
  end

  if options == nil then
    return {}
  end

  return {
    __rawMetadata = options,
    data = {
      raw_metadata = tostring(options),
      raw_metadata_type = type(options)
    }
  }
end

local function buildIdempotencyContext(options, actorCitizenId, operation)
  options = type(options) == 'table' and options or {}
  local key = trim(options.idempotency_key or options.idempotencyKey)
  if key == '' then return nil end
  if #key < 16 or #key > 64 or not key:match('^[%w_-]+$') then
    return false, 'invalid_idempotency_key'
  end

  local sourceResource = trim(options.__invokingResource)
  if sourceResource == '' or sourceResource == 'unknown' or #sourceResource > 100 then
    return false, 'invalid_idempotency_scope'
  end

  return {
    sourceResource = sourceResource,
    actorCitizenId = tostring(actorCitizenId),
    key = key,
    operation = tostring(operation)
  }
end

local function recoverIdempotentResult(idempotency, fingerprint)
  if type(idempotency) ~= 'table' then return nil, nil, false end
  local row = MZAccountRepository.getIdempotentOperation(
    idempotency.sourceResource,
    idempotency.actorCitizenId,
    idempotency.key
  )
  if not row then return nil, nil, false end
  if tostring(row.operation or '') ~= idempotency.operation then
    return nil, 'idempotency_conflict', true
  end
  if fingerprint and tostring(row.request_fingerprint or '') ~= tostring(fingerprint) then
    return nil, 'idempotency_conflict', true
  end

  local decodedOk, stored = pcall(json.decode, tostring(row.result_json or ''))
  if not decodedOk or type(stored) ~= 'table' then
    return nil, 'database_error', true
  end
  stored.ok = stored.ok == true
  stored.transactionRef = tostring(row.correlation_id or stored.transactionRef or '')
  stored.correlationId = stored.transactionRef
  stored.replayed = true
  return stored, nil, true
end

local function encodeIdempotentResult(idempotency, fingerprint, correlationId, result)
  idempotency.fingerprint = tostring(fingerprint)
  idempotency.correlationId = tostring(correlationId)
  idempotency.resultJson = json.encode(result)
  return idempotency
end

-- Consulta autenticada e read-only do resultado persistido. O escopo do
-- resource vem de GetInvokingResource no export, nunca do payload chamador.
function MZAccountService.getOperationResult(source, idempotencyKey, operation, options)
  source = tonumber(source)
  if not source or source <= 0 then return { ok = false, error = 'invalid_source' } end
  local player = MZEconomyCore.getPlayer(source)
  if not player then return { ok = false, error = 'player_not_loaded' } end

  idempotencyKey = trim(idempotencyKey)
  operation = trim(operation)
  if #idempotencyKey < 16 or #idempotencyKey > 64
      or not idempotencyKey:match('^[%w_-]+$') then
    return { ok = false, error = 'invalid_idempotency_key' }
  end
  if operation == '' or #operation > 64 or not operation:match('^[%w_%-]+$') then
    return { ok = false, error = 'invalid_operation' }
  end

  options = type(options) == 'table' and options or {}
  local sourceResource = trim(options.__invokingResource)
  if sourceResource == '' or sourceResource == 'unknown' or #sourceResource > 100 then
    return { ok = false, error = 'invalid_idempotency_scope' }
  end

  local row = MZAccountRepository.getIdempotentOperation(
    sourceResource, tostring(player.citizenid), idempotencyKey
  )
  if not row then
    if MZMoneyItemsService and type(MZMoneyItemsService.getPendingOperationResult) == 'function' then
      local sagaResult = MZMoneyItemsService.getPendingOperationResult(
        tostring(player.citizenid), sourceResource, idempotencyKey, operation
      )
      if sagaResult then return sagaResult end
    end
    return { ok = false, error = 'operation_not_found' }
  end
  if tostring(row.operation or '') ~= operation then
    return { ok = false, error = 'idempotency_conflict' }
  end

  local decodedOk, stored = pcall(json.decode, tostring(row.result_json or ''))
  if not decodedOk or type(stored) ~= 'table' then
    return { ok = false, error = 'database_error' }
  end
  return {
    ok = true,
    found = true,
    operation = operation,
    correlationId = tostring(row.correlation_id or ''),
    result = stored
  }
end

local function boundedLedgerText(value, maxLength, field, allowEmpty)
  local text = trim(value)
  if text == '' and allowEmpty ~= true then
    return nil, ('ledger_invalid_%s'):format(field)
  end
  if #text > maxLength then
    return nil, ('ledger_invalid_%s'):format(field)
  end
  return text
end

local function resolveLedgerContext(options, idempotency, ledgerMetadata)
  options = type(options) == 'table' and options or {}
  ledgerMetadata = type(ledgerMetadata) == 'table' and ledgerMetadata or {}

  local sourceResource = trim(
    type(idempotency) == 'table' and idempotency.sourceResource
      or options.__invokingResource
  )
  if sourceResource == '' then sourceResource = 'mz_economy' end
  if #sourceResource > 100 then return nil, 'ledger_invalid_source_resource' end

  local rawChannel = ''
  if type(options.data) == 'table' then rawChannel = trim(options.data.channel):lower() end
  if rawChannel == '' then
    local sourceTypeChannel = trim(ledgerMetadata.source_type):lower()
    if FINANCIAL_LEDGER_CHANNELS[sourceTypeChannel] == true then
      rawChannel = sourceTypeChannel
    elseif sourceResource == 'mz_economy' then
      rawChannel = 'system'
    else
      rawChannel = 'resource'
    end
  end
  if FINANCIAL_LEDGER_CHANNELS[rawChannel] ~= true then
    return nil, 'ledger_invalid_source_channel'
  end

  return {
    sourceResource = sourceResource,
    sourceChannel = rawChannel
  }
end

local function buildLedgerBatch(args)
  args = type(args) == 'table' and args or {}

  local correlationId, correlationErr = boundedLedgerText(
    args.correlationId, 128, 'correlation_id'
  )
  if not correlationId then return false, correlationErr end

  local eventType, eventErr = boundedLedgerText(args.eventType, 64, 'event_type')
  if not eventType then return false, eventErr end

  local reason, reasonErr = boundedLedgerText(args.reason, 128, 'reason')
  if not reason then return false, reasonErr end

  local account, accountErr = boundedLedgerText(args.account, 32, 'account')
  if not account then return false, accountErr end

  local amount = tonumber(args.amount)
  local fee = tonumber(args.fee) or 0
  if not amount or amount % 1 ~= 0 or amount <= 0 or amount > MAX_SAFE_INTEGER then
    return false, 'ledger_invalid_amount'
  end
  if fee % 1 ~= 0 or fee < 0 or fee > MAX_SAFE_INTEGER then
    return false, 'ledger_invalid_fee'
  end

  local sourceCitizenId
  if args.allowMissingSourceCitizenId == true and trim(args.sourceCitizenId) == '' then
    sourceCitizenId = nil
  else
    local sourceErr
    sourceCitizenId, sourceErr = boundedLedgerText(
      args.sourceCitizenId, 64, 'source_citizenid'
    )
    if not sourceCitizenId then return false, sourceErr end
  end

  local targetCitizenId = trim(args.targetCitizenId)
  if #targetCitizenId > 64 then return false, 'ledger_invalid_target_citizenid' end
  if targetCitizenId == '' then targetCitizenId = nil end

  local ledgerMetadata = type(args.ledgerMetadata) == 'table' and args.ledgerMetadata or {}
  local context, contextErr = resolveLedgerContext(args.options, args.idempotency, ledgerMetadata)
  if not context then return false, contextErr end

  if type(args.entries) ~= 'table' or #args.entries < 1 or #args.entries > 8 then
    return false, 'ledger_invalid_entries'
  end

  local envelope = {
    version = 1,
    operation = eventType,
    correlationId = correlationId,
    entries = args.entries,
    context = {
      sourceResource = context.sourceResource,
      sourceChannel = context.sourceChannel,
      sourceType = trim(ledgerMetadata.source_type),
      category = trim(ledgerMetadata.category)
    }
  }

  local encodedOk, metadataJson = pcall(json.encode, envelope)
  if not encodedOk or type(metadataJson) ~= 'string' or metadataJson == '' then
    return false, 'ledger_metadata_encode_failed'
  end
  if #metadataJson > FINANCIAL_LEDGER_METADATA_MAX_BYTES then
    return false, 'ledger_metadata_too_large'
  end

  local idempotencyKey = type(args.idempotency) == 'table'
    and trim(args.idempotency.key)
    or ''
  if idempotencyKey == '' then idempotencyKey = nil end

  return {
    correlationId = correlationId,
    idempotencyKey = idempotencyKey,
    eventType = eventType,
    sourceCitizenId = sourceCitizenId,
    targetCitizenId = targetCitizenId,
    account = account,
    amount = math.floor(amount),
    fee = math.floor(fee),
    reason = reason,
    sourceResource = context.sourceResource,
    sourceChannel = context.sourceChannel,
    sourceType = trim(ledgerMetadata.source_type),
    metadataJson = metadataJson,
    entries = args.entries
  }
end

local function ledgerEntry(leg, citizenid, account, direction, amount, beforeAmount, afterAmount, metadata)
  metadata = type(metadata) == 'table' and metadata or {}
  local relatedCitizenId = trim(metadata.related_citizenid)
  if relatedCitizenId == '' then relatedCitizenId = nil end

  return {
    leg = leg,
    citizenid = citizenid ~= nil and tostring(citizenid) or '',
    account = tostring(account),
    direction = tostring(direction),
    amount = math.floor(tonumber(amount) or 0),
    balanceBefore = math.floor(tonumber(beforeAmount) or 0),
    balanceAfter = math.floor(tonumber(afterAmount) or 0),
    category = tostring(metadata.category or 'unknown'),
    reason = tostring(metadata.reason or 'legacy_call'),
    relatedCitizenid = relatedCitizenId,
    relatedOrgCode = trim(metadata.related_org_code) ~= '' and trim(metadata.related_org_code) or nil,
    externalRef = trim(metadata.external_ref) ~= '' and trim(metadata.external_ref) or nil,
    countsAsIncome = metadata.counts_as_income == true,
    countsAsExpense = metadata.counts_as_expense == true
  }
end

-- Contratos internos usados pelos produtores financeiros do mz_economy.
-- Nao sao exports, eventos de rede ou callbacks NUI.
function MZAccountService.BuildFinancialLedgerBatchInternal(args)
  return buildLedgerBatch(args)
end

function MZAccountService.BuildFinancialLedgerEntryInternal(...)
  return ledgerEntry(...)
end

function MZAccountService.NormalizeFinancialLedgerOptionsInternal(options, defaults)
  return normalizeLedgerOptions(options, defaults)
end

function MZAccountService.GenerateFinancialTransactionRefInternal(prefix)
  return generateTransactionRef(prefix)
end

function MZAccountService.WithFinancialLocksInternal(keys, handler)
  return withAccountLocks(keys, handler)
end

local function normalizeAccountActor(source)
  if source == nil then
    return {
      type = 'system',
      id = 'system'
    }
  end

  if tonumber(source) == 0 then
    return {
      type = 'console',
      id = 'console'
    }
  end

  local player = MZEconomyCore.getPlayer(source)
  if player and player.citizenid then
    return {
      type = 'player',
      id = tostring(player.citizenid),
      source = source
    }
  end

  return {
    type = 'source',
    id = tostring(source)
  }
end

local function logMoneyChange(action, player, moneyType, beforeAmount, afterAmount, delta, options)
  if not MZEconomyCore or not player then
    return
  end

  options = options or {}

  MZEconomyCore.createDetailed('accounts', action, {
    actor = options.actor or normalizeAccountActor(options.actorSource),
    target = {
      type = 'player_account',
      id = tostring(player.citizenid)
    },
    context = {
      citizenid = tostring(player.citizenid),
      money_type = moneyType
    },
    before = {
      amount = math.floor(tonumber(beforeAmount) or 0)
    },
    after = {
      amount = math.floor(tonumber(afterAmount) or 0)
    },
    meta = {
      delta = math.floor(tonumber(delta) or 0),
      reason = options.reason,
      source_type = options.sourceType,
      source_ref = options.sourceRef,
      extra = options.meta or {}
    }
  })
end

function MZAccountService.getMoney(source)
  if not MZMoneyItemsService then return nil, 'inventory_unavailable' end
  return MZMoneyItemsService.getMoney(source)
end

local function persistSingleMoneyChange(source, moneyType, nextAmount, options, direction, ledgerAmount, operation)
  local player = MZEconomyCore.getPlayer(source)
  if not player then return false, 'player_not_loaded' end

  operation = tostring(operation or 'set_money')
  local idempotency, idempotencyErr = buildIdempotencyContext(options, player.citizenid, operation)
  if idempotency == false then return false, idempotencyErr end

  local requestedAmount = operation == 'set_money'
    and math.floor(tonumber(nextAmount) or 0)
    or math.floor(tonumber(ledgerAmount) or 0)
  local requestFingerprint = ('account=%s;amount=%d'):format(moneyType, requestedAmount)
  local correlationId = generateTransactionRef(('mzacc-%s'):format(operation:gsub('_money$', '')))

  local ok, detailOrErr = withAccountLocks({ player.citizenid }, function()
    player = MZEconomyCore.getPlayer(source)
    if not player then return false, 'player_not_loaded' end

    if idempotency then
      local stored, storedErr, found = recoverIdempotentResult(idempotency, requestFingerprint)
      if found then
        if not stored then return false, storedErr end
        return true, { replayedResult = stored }
      end
    end

    local currentAmount = math.floor(tonumber((player.money or {})[moneyType]) or 0)
    local resolvedAmount
    if type(nextAmount) == 'function' then
      resolvedAmount = nextAmount(currentAmount)
    else
      resolvedAmount = nextAmount
    end
    if resolvedAmount == nil then return false, 'not_enough_money' end

    resolvedAmount = math.floor(tonumber(resolvedAmount) or -1)
    if resolvedAmount < 0 or resolvedAmount > MAX_SAFE_INTEGER then return false, 'invalid_amount' end

    local delta = resolvedAmount - currentAmount
    local resolvedDirection = direction or 'adjustment'
    local resolvedLedgerAmount = math.abs(delta)
    local ledgerMetadata = normalizeLedgerOptions(options, {
      category = resolvedDirection == 'adjustment' and 'admin_adjustment' or 'unknown',
      reason = operation,
      sourceType = 'economy_mutation',
      sourceResource = 'mz_economy'
    })
    local ledgerBatch
    if delta ~= 0 then
      local ledgerErr
      ledgerBatch, ledgerErr = buildLedgerBatch({
        correlationId = correlationId,
        idempotency = idempotency,
        eventType = operation,
        sourceCitizenId = player.citizenid,
        account = moneyType,
        amount = resolvedLedgerAmount,
        fee = 0,
        reason = ledgerMetadata.reason,
        ledgerMetadata = ledgerMetadata,
        options = options,
        entries = {
          ledgerEntry(
            1,
            player.citizenid,
            moneyType,
            resolvedDirection,
            resolvedLedgerAmount,
            currentAmount,
            resolvedAmount,
            ledgerMetadata
          )
        }
      })
      if ledgerBatch == false then return false, ledgerErr end
    end

    local persisted
    if idempotency then
      local storedResult = {
        ok = true,
        transactionRef = correlationId,
        correlationId = correlationId,
        replayed = false
      }
      persisted = MZAccountRepository.updatePlayerMoneyIdempotent(
        player.citizenid,
        moneyType,
        resolvedAmount,
        encodeIdempotentResult(idempotency, requestFingerprint, correlationId, storedResult),
        ledgerBatch
      )
    elseif type(ledgerBatch) == 'table' then
      persisted = MZAccountRepository.updatePlayerMoneyWithLedger(
        player.citizenid,
        moneyType,
        resolvedAmount,
        ledgerBatch
      )
    else
      persisted = true
    end

    if not persisted then
      if idempotency then
        local stored, storedErr, found = recoverIdempotentResult(idempotency, requestFingerprint)
        if found and stored then return true, { replayedResult = stored } end
        if found then return false, storedErr end
      end
      return false, 'database_error'
    end

    player.money = player.money or {}
    player.money[moneyType] = resolvedAmount
    return true, {
      player = player,
      before = currentAmount,
      after = resolvedAmount,
      direction = resolvedDirection,
      ledgerAmount = resolvedLedgerAmount,
      ledgerPersisted = type(ledgerBatch) == 'table'
    }
  end)

  if not ok then return false, detailOrErr end

  local detail = detailOrErr
  if detail.replayedResult then return true end
  local delta = detail.after - detail.before
  logMoneyChange(operation, detail.player, moneyType, detail.before, detail.after, delta, options)

  return true
end

function MZAccountService.setMoney(source, moneyType, amount, options)
  local normalizedMoneyType, moneyTypeErr = MZAccountService.NormalizeMoneyAccount(moneyType)
  if not normalizedMoneyType then return false, moneyTypeErr end
  if type(amount) ~= 'number' or amount ~= amount or amount == math.huge
      or amount == -math.huge or amount % 1 ~= 0 or amount < 0 or amount > MAX_SAFE_INTEGER then
    return false, 'invalid_amount'
  end

  if normalizedMoneyType ~= 'bank' then
    return false, 'physical_set_money_unsupported'
  end

  options = normalizeServiceOptions(options)
  local direction = options.__ledgerFromWrapper == true and options.__ledgerDirection or 'adjustment'
  local ledgerAmount = options.__ledgerFromWrapper == true and options.__ledgerAmount or nil
  return persistSingleMoneyChange(
    source, normalizedMoneyType, math.floor(amount), options, direction, ledgerAmount, 'set_money'
  )
end

function MZAccountService.addMoney(source, moneyType, amount, options)
  local normalizedMoneyType, moneyTypeErr = MZAccountService.NormalizeMoneyAccount(moneyType)
  if not normalizedMoneyType then return false, moneyTypeErr end
  if type(amount) ~= 'number' or amount ~= amount or amount == math.huge
      or amount == -math.huge or amount % 1 ~= 0 or amount <= 0 or amount > MAX_SAFE_INTEGER then
    return false, 'invalid_amount'
  end

  local value = math.floor(amount)
  options = normalizeServiceOptions(options)
  options.reason = options.reason or 'add_money'

  if normalizedMoneyType ~= 'bank' then
    if not MZMoneyItemsService then return false, 'inventory_unavailable' end
    return MZMoneyItemsService.mutate(
      source, normalizedMoneyType, value, options, 'add_money'
    )
  end

  return persistSingleMoneyChange(source, normalizedMoneyType, function(current)
    return current + value
  end, options, 'in', value, 'add_money')
end

function MZAccountService.removeMoney(source, moneyType, amount, options)
  local normalizedMoneyType, moneyTypeErr = MZAccountService.NormalizeMoneyAccount(moneyType)
  if not normalizedMoneyType then return false, moneyTypeErr end
  if type(amount) ~= 'number' or amount ~= amount or amount == math.huge
      or amount == -math.huge or amount % 1 ~= 0 or amount <= 0 or amount > MAX_SAFE_INTEGER then
    return false, 'invalid_amount'
  end

  local value = math.floor(amount)
  options = normalizeServiceOptions(options)
  options.reason = options.reason or 'remove_money'

  if normalizedMoneyType ~= 'bank' then
    if not MZMoneyItemsService then return false, 'inventory_unavailable' end
    return MZMoneyItemsService.mutate(
      source, normalizedMoneyType, value, options, 'remove_money'
    )
  end

  return persistSingleMoneyChange(source, normalizedMoneyType, function(current)
    if current < value then return nil end
    return current - value
  end, options, 'out', value, 'remove_money')
end

function MZAccountService.transferMoneyBetweenAccounts(source, fromAccount, toAccount, amount, options)
  local player = MZEconomyCore.getPlayer(source)
  if not player then return { ok = false, error = 'player_not_loaded' } end

  local fromNormalized, fromErr = MZAccountService.NormalizeMoneyAccount(fromAccount)
  if not fromNormalized then return { ok = false, error = fromErr } end
  local toNormalized, toErr = MZAccountService.NormalizeMoneyAccount(toAccount)
  if not toNormalized then return { ok = false, error = toErr } end
  if fromNormalized == toNormalized then return { ok = false, error = 'same_account' } end

  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 or amount > MAX_SAFE_INTEGER then
    return { ok = false, error = 'invalid_amount' }
  end

  options = normalizeServiceOptions(options)
  if not MZMoneyItemsService then return { ok = false, error = 'inventory_unavailable' } end
  return MZMoneyItemsService.transfer(source, fromNormalized, toNormalized, amount, options)
end
function MZAccountService.transferBankBetweenPlayers(source, target, amount, options)
  local sender = MZEconomyCore.getPlayer(source)
  if not sender then return { ok = false, error = 'player_not_loaded' } end

  options = normalizeServiceOptions(options)
  local idempotency, idempotencyErr = buildIdempotencyContext(options, sender.citizenid, 'bank_transfer')
  if idempotency == false then return { ok = false, error = idempotencyErr } end

  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 or amount > MAX_SAFE_INTEGER then return { ok = false, error = 'invalid_amount' } end
  local fee = math.floor(tonumber(options.fee) or 0)
  if fee < 0 or fee > MAX_SAFE_INTEGER or amount > MAX_SAFE_INTEGER - fee then
    return { ok = false, error = 'invalid_fee' }
  end
  local totalCost = amount + fee
  local requestFingerprint = ('target=%s;amount=%d;fee=%d'):format(tostring(target or ''), amount, fee)

  if idempotency then
    local stored, storedErr, found = recoverIdempotentResult(idempotency, requestFingerprint)
    if found then return stored or { ok = false, error = storedErr } end
  end

  local targetSource = tonumber(target)
  local recipient
  if targetSource and targetSource > 0 then
    recipient = MZEconomyCore.getPlayer(targetSource)
  else
    recipient = MZEconomyCore.getPlayerByCitizenId(tostring(target or ''))
    targetSource = recipient and recipient.source or nil
  end

  if not recipient or not targetSource then return { ok = false, error = 'recipient_offline' } end
  if tostring(sender.citizenid) == tostring(recipient.citizenid) then
    return { ok = false, error = 'self_transfer' }
  end

  options.external_ref = trim(options.external_ref or options.externalRef)
  if options.external_ref == '' then
    options.external_ref = generateTransactionRef('mzacc-transfer')
  end
  options.related_citizenid = tostring(recipient.citizenid)
  options.data = type(options.data) == 'table' and options.data or {}
  options.data.fee = fee
  options.data.transfer_amount = amount
  local ok, detailOrErr = withAccountLocks({ sender.citizenid, recipient.citizenid }, function()
    sender = MZEconomyCore.getPlayer(source)
    recipient = MZEconomyCore.getPlayer(targetSource)
    if not sender or not recipient then return false, 'recipient_offline' end

    if idempotency then
      local stored, storedErr, found = recoverIdempotentResult(idempotency, requestFingerprint)
      if found then
        if not stored then return false, storedErr end
        return true, { replayedResult = stored }
      end
    end

    local senderBefore = math.floor(tonumber((sender.money or {}).bank) or 0)
    local recipientBefore = math.floor(tonumber((recipient.money or {}).bank) or 0)
    if senderBefore < totalCost then return false, 'not_enough_money' end
    if recipientBefore < 0 or recipientBefore > MAX_SAFE_INTEGER - amount then
      return false, 'amount_overflow'
    end

    local senderAfter = senderBefore - totalCost
    local recipientAfter = recipientBefore + amount
    local senderLedgerMetadata = normalizeLedgerOptions(options, {
      category = 'unknown',
      reason = 'bank_transfer',
      sourceType = 'economy_mutation',
      sourceResource = 'mz_economy'
    })
    local recipientLedgerOptions = cloneTable(options)
    recipientLedgerOptions.related_citizenid = tostring(sender.citizenid)
    recipientLedgerOptions.reason = options.recipient_reason or options.reason
    local recipientLedgerMetadata = normalizeLedgerOptions(recipientLedgerOptions, {
      category = senderLedgerMetadata.category,
      reason = 'bank_transfer_received',
      sourceType = senderLedgerMetadata.source_type,
      sourceResource = senderLedgerMetadata.source_resource
    })
    local ledgerBatch, ledgerErr = buildLedgerBatch({
      correlationId = options.external_ref,
      idempotency = idempotency,
      eventType = 'bank_transfer',
      sourceCitizenId = sender.citizenid,
      targetCitizenId = recipient.citizenid,
      account = 'bank',
      amount = amount,
      fee = fee,
      reason = senderLedgerMetadata.reason,
      ledgerMetadata = senderLedgerMetadata,
      options = options,
      entries = {
        ledgerEntry(
          1, sender.citizenid, 'bank', 'out', totalCost,
          senderBefore, senderAfter, senderLedgerMetadata
        ),
        ledgerEntry(
          2, recipient.citizenid, 'bank', 'in', amount,
          recipientBefore, recipientAfter, recipientLedgerMetadata
        )
      }
    })
    if ledgerBatch == false then return false, ledgerErr end

    local financialResult = {
      ok = true,
      balances = {
        sender = senderAfter,
        recipient = recipientAfter
      },
      targetSource = targetSource,
      targetCitizenId = tostring(recipient.citizenid),
      transactionRef = options.external_ref,
      correlationId = options.external_ref,
      fee = fee,
      replayed = false
    }

    local persisted
    if idempotency then
      local storedResult = {
        ok = true,
        targetCitizenId = tostring(recipient.citizenid),
        transactionRef = options.external_ref,
        correlationId = options.external_ref,
        fee = fee,
        replayed = false
      }
      persisted = MZAccountRepository.transferBankBetweenPlayersIdempotent(
        sender.citizenid,
        senderAfter,
        recipient.citizenid,
        recipientAfter,
        encodeIdempotentResult(idempotency, requestFingerprint, options.external_ref, storedResult),
        ledgerBatch
      )
    else
      persisted = MZAccountRepository.transferBankBetweenPlayers(
        sender.citizenid,
        senderAfter,
        recipient.citizenid,
        recipientAfter,
        ledgerBatch
      )
    end
    if not persisted then
      if idempotency then
        local stored, storedErr, found = recoverIdempotentResult(idempotency, requestFingerprint)
        if found and stored then return true, { replayedResult = stored } end
        if found then return false, storedErr end
      end
      return false, 'database_error'
    end

    sender.money.bank = senderAfter
    recipient.money.bank = recipientAfter
    return true, {
      sender = sender,
      recipient = recipient,
      senderBefore = senderBefore,
      senderAfter = senderAfter,
      recipientBefore = recipientBefore,
      recipientAfter = recipientAfter,
      ledgerPersisted = type(ledgerBatch) == 'table',
      financialResult = financialResult
    }
  end)

  if not ok then return { ok = false, error = detailOrErr } end

  local detail = detailOrErr
  if detail.replayedResult then return detail.replayedResult end
  logMoneyChange('transfer_bank_out', detail.sender, 'bank', detail.senderBefore, detail.senderAfter, -totalCost, options)
  local recipientOptions = cloneTable(options)
  recipientOptions.related_citizenid = tostring(detail.sender.citizenid)
  recipientOptions.reason = options.recipient_reason or options.reason
  logMoneyChange('transfer_bank_in', detail.recipient, 'bank', detail.recipientBefore, detail.recipientAfter, amount, recipientOptions)
  return detail.financialResult
end
