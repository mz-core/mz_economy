MZOrgAccountService = MZOrgAccountService or {}

local MAX_SAFE_INTEGER = 9007199254740991

local function asBool(value)
  if value == true then return true end
  if value == false or value == nil then return false end
  if type(value) == 'number' then return value == 1 end
  if type(value) == 'string' then
    value = value:lower()
    return value == '1' or value == 'true'
  end
  return false
end

local buildOrgAccountActor
local normalizeOrgCode

local function normalizeOrganization(value)
  if type(value) ~= 'table' then return nil end
  local id = tonumber(value.id or value.orgId or value.org_id)
  local code = normalizeOrgCode(value.code or value.orgCode or value.org_code)
  if not id or id <= 0 or not code then return nil end
  return {
    id = math.floor(id),
    code = code,
    active = asBool(value.active),
    has_shared_account = asBool(value.has_shared_account or value.hasSharedAccount)
  }
end

normalizeOrgCode = function(value)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' then return nil end
  return value
end

local function normalizeReason(value)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' then return nil end
  if #value > 255 then value = value:sub(1, 255) end
  return value
end

local function bankActionAllowed(source)
  local ok, result = MZEconomyCore.canPerformAction(source, 'bank.use')
  return ok == true and type(result) == 'table' and result.allowed == true
end

local ledgerSequence = 0

local function nextLedgerRef(prefix, orgCode)
  ledgerSequence = ledgerSequence + 1
  local stamp = type(GetGameTimer) == 'function' and GetGameTimer() or os.time()
  return ('%s:%s:%s:%s'):format(
    tostring(prefix or 'org_account'),
    tostring(orgCode or 'unknown'),
    tostring(stamp),
    tostring(ledgerSequence)
  )
end

local function getPlayerDisplayName(player, source)
  if player and player.charinfo then
    local first = tostring(player.charinfo.firstname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local last = tostring(player.charinfo.lastname or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local fullName = (first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')
    if fullName ~= '' then return fullName end
  end

  if source and tonumber(source) and tonumber(source) > 0 then
    local ok, name = pcall(GetPlayerName, source)
    if ok and name and name ~= '' then return name end
  end

  return nil
end

local function logOrgAccountBlocked(action, orgCode, actorSource, reason, meta)
  if not MZEconomyCore then return end

  local actorPlayer = actorSource and MZEconomyCore.getPlayer(actorSource) or nil
  MZEconomyCore.createDetailed('org_accounts', action, {
    actor = actorPlayer and MZEconomyCore.makeActor('player', actorPlayer.citizenid, {
      source = actorSource,
      name = getPlayerDisplayName(actorPlayer, actorSource)
    }) or buildOrgAccountActor(actorSource),
    target = {
      type = 'org_account',
      id = tostring(orgCode or 'unknown')
    },
    context = {
      org_code = orgCode
    },
    meta = {
      reason = reason,
      extra = meta or {}
    }
  })
end

function buildOrgAccountActor(actor)
  if actor == nil then
    return {
      type = 'system',
      id = 'system'
    }
  end

  if tonumber(actor) == 0 then
    return {
      type = 'console',
      id = 'console'
    }
  end

  if type(actor) == 'number' then
    local player = MZEconomyCore.getPlayer(actor)
    if player and player.citizenid then
      return {
        type = 'player',
        id = tostring(player.citizenid),
        source = actor
      }
    end

    return {
      type = 'source',
      id = tostring(actor)
    }
  end

  return {
    type = 'system',
    id = tostring(actor)
  }
end

local function logOrgAccountAction(action, org, actor, beforeBalance, afterBalance, meta)
  if not MZEconomyCore or not org then
    return
  end

  MZEconomyCore.createDetailed('org_accounts', action, {
    actor = buildOrgAccountActor(actor),
    target = {
      type = 'org_account',
      id = tostring(org.code)
    },
    context = {
      org_id = tonumber(org.id) or org.id,
      org_code = tostring(org.code),
      has_shared_account = asBool(org.has_shared_account)
    },
    before = {
      balance = math.floor(tonumber(beforeBalance) or 0)
    },
    after = {
      balance = math.floor(tonumber(afterBalance) or 0)
    },
    meta = meta or {}
  })
end

local function persistOrgPlayerTransfer(source, org, amount, operation, userReason)
  local player = MZEconomyCore.getPlayer(source)
  if not player or not player.citizenid then return false, 'player_not_loaded' end

  return MZAccountService.WithFinancialLocksInternal({
    tostring(player.citizenid),
    ('org:%s'):format(org.id)
  }, function()
    player = MZEconomyCore.getPlayer(source)
    if not player or not player.citizenid then return false, 'player_not_loaded' end

    local row = MySQL.single.await('SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id })
    if not row then return false, 'org_account_missing' end

    local playerBefore = math.floor(tonumber((player.money or {}).bank) or 0)
    local orgBefore = math.floor(tonumber(row.balance) or 0)
    local playerAfter, orgAfter
    if operation == 'deposit' then
      if playerBefore < amount then return false, 'insufficient_player_funds' end
      if orgBefore > MAX_SAFE_INTEGER - amount then return false, 'amount_overflow' end
      playerAfter = playerBefore - amount
      orgAfter = orgBefore + amount
    else
      if orgBefore < amount then return false, 'insufficient_org_funds' end
      if playerBefore > MAX_SAFE_INTEGER - amount then return false, 'amount_overflow' end
      playerAfter = playerBefore + amount
      orgAfter = orgBefore - amount
    end

    local externalRef = nextLedgerRef('org_transfer', org.code)
    local common = {
      category = 'org_transfer',
      source_resource = 'mz_economy',
      source_type = 'org_account',
      sourceType = 'org_account',
      related_org_code = tostring(org.code),
      external_ref = externalRef,
      counts_as_income = false,
      counts_as_expense = false,
      data = { channel = 'org', operation = operation, user_reason = userReason }
    }
    local playerOptions = {}
    for key, value in pairs(common) do playerOptions[key] = value end
    playerOptions.reason = operation == 'deposit' and 'org_deposit' or 'org_withdraw'
    local playerMetadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(playerOptions, {})

    local orgOptions = {}
    for key, value in pairs(common) do orgOptions[key] = value end
    orgOptions.reason = playerOptions.reason
    orgOptions.related_citizenid = tostring(player.citizenid)
    local orgMetadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(orgOptions, {})

    local entries
    if operation == 'deposit' then
      entries = {
        MZAccountService.BuildFinancialLedgerEntryInternal(
          1, player.citizenid, 'bank', 'out', amount, playerBefore, playerAfter, playerMetadata
        ),
        MZAccountService.BuildFinancialLedgerEntryInternal(
          2, nil, 'org', 'in', amount, orgBefore, orgAfter, orgMetadata
        )
      }
    else
      entries = {
        MZAccountService.BuildFinancialLedgerEntryInternal(
          1, nil, 'org', 'out', amount, orgBefore, orgAfter, orgMetadata
        ),
        MZAccountService.BuildFinancialLedgerEntryInternal(
          2, player.citizenid, 'bank', 'in', amount, playerBefore, playerAfter, playerMetadata
        )
      }
    end

    local ledgerBatch, ledgerErr = MZAccountService.BuildFinancialLedgerBatchInternal({
      correlationId = MZAccountService.GenerateFinancialTransactionRefInternal('mzacc-org-transfer'),
      eventType = 'org_transfer',
      sourceCitizenId = player.citizenid,
      account = 'multi',
      amount = amount,
      fee = 0,
      reason = playerMetadata.reason,
      ledgerMetadata = playerMetadata,
      options = playerOptions,
      entries = entries
    })
    if ledgerBatch == false then return false, ledgerErr end

    if not MZAccountRepository.transferPlayerBankAndOrg(
      player.citizenid, playerAfter, org.id, orgAfter, ledgerBatch
    ) then
      return false, 'database_error'
    end

    player.money = player.money or {}
    player.money.bank = playerAfter
    return true, {
      player = player,
      playerBefore = playerBefore,
      playerAfter = playerAfter,
      orgBefore = orgBefore,
      orgAfter = orgAfter,
      externalRef = externalRef,
      playerMetadata = playerMetadata,
      orgMetadata = orgMetadata,
      ledgerPersisted = type(ledgerBatch) == 'table'
    }
  end)
end

function MZOrgAccountService.getBalance(organization)
  local org = normalizeOrganization(organization)
  if not org then
    return false, 'org_not_found'
  end

  if not asBool(org.has_shared_account) then
    return false, 'org_has_no_shared_account'
  end

  local row = MySQL.single.await('SELECT * FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id })
  if not row then
    MySQL.insert.await([[
      INSERT INTO mz_org_accounts (org_id, balance)
      VALUES (?, 0)
      ON DUPLICATE KEY UPDATE org_id = org_id
    ]], { org.id })

    row = MySQL.single.await('SELECT * FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id })
  end

  return true, tonumber(row.balance) or 0, org
end

function MZOrgAccountService.getAccountReadOnly(source, organization)
  source = tonumber(source)

  if not source or source <= 0 then
    return false, 'invalid_source'
  end

  local org = normalizeOrganization(organization)
  if not org then
    return false, 'org_not_found'
  end

  if not asBool(org.active) then
    return false, 'org_archived'
  end

  if not asBool(org.has_shared_account) then
    return false, 'org_has_no_shared_account'
  end

  local row = MySQL.single.await('SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id })

  return true, {
    orgCode = tostring(org.code),
    balance = row and (tonumber(row.balance) or 0) or 0,
    currency = 'R$',
    canView = true
  }
end

function MZOrgAccountService.deposit(source, organization, amount, reason)
  source = tonumber(source)
  local org = normalizeOrganization(organization)
  local orgCode = org and org.code or nil
  amount = math.floor(tonumber(amount) or 0)
  reason = normalizeReason(reason)

  if not source or source <= 0 then return false, 'invalid_source' end
  if not orgCode then return false, 'invalid_org' end
  if amount <= 0 then return false, 'invalid_amount' end
  if not bankActionAllowed(source) then return false, 'player_state_blocked' end

  local actorPlayer = MZEconomyCore.getPlayer(source)
  if not actorPlayer or not actorPlayer.citizenid then
    logOrgAccountBlocked('org.account.deposit.blocked', orgCode, source, 'player_not_loaded', { amount = amount })
    return false, 'player_not_loaded'
  end

  local okBalance, balanceOrErr = MZOrgAccountService.getBalance(org)
  if not okBalance then
    logOrgAccountBlocked('org.account.deposit.blocked', orgCode, source, balanceOrErr, { amount = amount })
    return false, balanceOrErr == 'org_not_found' and 'invalid_org' or balanceOrErr
  end
  if not asBool(org.active) then
    logOrgAccountBlocked('org.account.deposit.blocked', orgCode, source, 'org_archived', { amount = amount })
    return false, 'org_archived'
  end

  local persisted, detailOrErr = persistOrgPlayerTransfer(source, org, amount, 'deposit', reason)
  if not persisted then
    logOrgAccountBlocked('org.account.deposit.blocked', orgCode, source, detailOrErr, { amount = amount })
    return false, detailOrErr
  end
  local detail = detailOrErr
  logOrgAccountAction('org.account.deposit', org, source, detail.orgBefore, detail.orgAfter, {
    amount = amount,
    reason = reason,
    transaction_id = detail.externalRef
  })

  return true, {
    orgCode = tostring(org.code),
    balance = detail.orgAfter,
    currency = 'R$',
    transactionId = detail.externalRef
  }
end

function MZOrgAccountService.withdraw(source, organization, amount, reason)
  source = tonumber(source)
  local org = normalizeOrganization(organization)
  local orgCode = org and org.code or nil
  amount = math.floor(tonumber(amount) or 0)
  reason = normalizeReason(reason)

  if not source or source <= 0 then return false, 'invalid_source' end
  if not orgCode then return false, 'invalid_org' end
  if amount <= 0 then return false, 'invalid_amount' end
  if not bankActionAllowed(source) then return false, 'player_state_blocked' end

  local actorPlayer = MZEconomyCore.getPlayer(source)
  if not actorPlayer or not actorPlayer.citizenid then
    logOrgAccountBlocked('org.account.withdraw.blocked', orgCode, source, 'player_not_loaded', { amount = amount })
    return false, 'player_not_loaded'
  end

  local okBalance, balanceOrErr = MZOrgAccountService.getBalance(org)
  if not okBalance then
    logOrgAccountBlocked('org.account.withdraw.blocked', orgCode, source, balanceOrErr, { amount = amount })
    return false, balanceOrErr == 'org_not_found' and 'invalid_org' or balanceOrErr
  end
  if not asBool(org.active) then
    logOrgAccountBlocked('org.account.withdraw.blocked', orgCode, source, 'org_archived', { amount = amount })
    return false, 'org_archived'
  end

  local persisted, detailOrErr = persistOrgPlayerTransfer(source, org, amount, 'withdraw', reason)
  if not persisted then
    logOrgAccountBlocked('org.account.withdraw.blocked', orgCode, source, detailOrErr, { amount = amount })
    return false, detailOrErr
  end
  local detail = detailOrErr
  logOrgAccountAction('org.account.withdraw', org, source, detail.orgBefore, detail.orgAfter, {
    amount = amount,
    reason = reason,
    transaction_id = detail.externalRef
  })

  return true, {
    orgCode = tostring(org.code),
    balance = detail.orgAfter,
    currency = 'R$',
    transactionId = detail.externalRef
  }
end

function MZOrgAccountService.listTransactions(source, organization, filters)
  source = tonumber(source)
  local org = normalizeOrganization(organization)
  local orgCode = org and org.code or nil
  filters = type(filters) == 'table' and filters or {}

  if not source or source <= 0 then return false, 'invalid_source' end
  if not orgCode then return false, 'invalid_org' end

  if not org then return false, 'invalid_org' end
  if not asBool(org.active) then return false, 'org_archived' end

  local limit = math.floor(tonumber(filters.limit) or 50)
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local offset = math.floor(tonumber(filters.offset) or 0)
  if offset < 0 then offset = 0 end
  if offset > 10000 then offset = 10000 end

  local txType = normalizeReason(filters.type)
  if txType and txType ~= 'deposit' and txType ~= 'withdraw' then
    txType = nil
  end

  local rows
  if txType then
    rows = MySQL.query.await([[
      SELECT id, related_org_code AS org_code,
        CASE WHEN reason = 'org_deposit' THEN 'deposit' ELSE 'withdraw' END AS type,
        amount, balance_before, balance_after, related_citizenid AS actor_citizenid,
        reason, created_at
      FROM mz_economy_transactions
      WHERE related_org_code = ? AND account = 'org'
        AND reason = ?
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    ]], { orgCode, txType == 'deposit' and 'org_deposit' or 'org_withdraw', limit, offset }) or {}
  else
    rows = MySQL.query.await([[
      SELECT id, related_org_code AS org_code,
        CASE WHEN reason = 'org_deposit' THEN 'deposit' ELSE 'withdraw' END AS type,
        amount, balance_before, balance_after, related_citizenid AS actor_citizenid,
        reason, created_at
      FROM mz_economy_transactions
      WHERE related_org_code = ? AND account = 'org'
        AND reason IN ('org_deposit', 'org_withdraw')
      ORDER BY id DESC
      LIMIT ? OFFSET ?
    ]], { orgCode, limit, offset }) or {}
  end

  local out = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = {
      id = tonumber(row.id) or row.id,
      orgCode = row.org_code,
      type = row.type,
      amount = tonumber(row.amount) or 0,
      balanceBefore = tonumber(row.balance_before) or 0,
      balanceAfter = tonumber(row.balance_after) or 0,
      actorCitizenId = row.actor_citizenid,
      reason = row.reason,
      createdAt = row.created_at
    }
  end

  return true, out
end

local ORG_COMMERCE_VERSION = 1
local ORG_COMMERCE_PURPOSES = {
  facility_purchase = {
    capability = 'facility.purchase',
    category = 'org_facility_purchase',
    reason = 'facility_purchase',
    refundCategory = 'org_facility_refund',
    refundReason = 'facility_purchase_refund',
    resources = { mz_org_activities = true }
  },
  furniture_purchase = {
    capability = 'facility.furniture.buy',
    category = 'org_furniture_purchase',
    reason = 'furniture_purchase',
    refundCategory = 'org_furniture_refund',
    refundReason = 'furniture_purchase_refund',
    resources = { mz_furniture = true }
  }
}

local function normalizeBoundedToken(value, minLength, maxLength)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  local token = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if #token < minLength or #token > maxLength then return nil end
  if not token:match('^[%w%._:%-]+$') then return nil end
  return token
end

local function normalizeSourceResource(value)
  if type(value) ~= 'string' then return nil end
  value = value:gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' or #value > 100 then return nil end
  return value
end

local function encodeCommerceMetadata(data)
  local ok, encoded = pcall(MZEconomyCore.jsonEncode, data)
  if not ok or type(encoded) ~= 'string' or encoded == '' or #encoded > 8192 then
    return nil
  end
  return encoded
end

local function commerceFingerprint(operationType, sourceResource, org, actorCitizenId, amount, purpose, relatedRef, reversalId)
  return table.concat({
    tostring(ORG_COMMERCE_VERSION), tostring(operationType), tostring(sourceResource),
    tostring(org.id), tostring(org.code), tostring(actorCitizenId), tostring(amount),
    tostring(purpose), tostring(relatedRef), tostring(reversalId or '')
  }, '|')
end

local function normalizeCommerceReceipt(row, replayed)
  return {
    schemaVersion = ORG_COMMERCE_VERSION,
    receiptId = row.receipt_id,
    correlationId = row.correlation_id,
    operationId = tonumber(row.id) or row.id,
    operationKey = row.operation_key,
    operationType = row.operation_type,
    purpose = row.purpose,
    orgCode = row.org_code,
    amount = tonumber(row.amount) or 0,
    balanceBefore = tonumber(row.balance_before) or 0,
    balanceAfter = tonumber(row.balance_after) or 0,
    relatedRef = row.related_ref,
    reversalOfOperationId = tonumber(row.reversal_of_operation_id) or row.reversal_of_operation_id,
    replayed = replayed == true
  }
end

local function recoverCommerceOperation(row, operationType, purpose, fingerprint)
  if not row then return nil, nil, false end
  if tostring(row.operation_type or '') ~= tostring(operationType)
      or tostring(row.purpose or '') ~= tostring(purpose)
      or tostring(row.request_fingerprint or '') ~= tostring(fingerprint) then
    return nil, 'idempotency_conflict', true
  end

  if tostring(row.status) == 'applied' then
    return normalizeCommerceReceipt(row, true), nil, true
  end
  if tostring(row.status) == 'rejected' then
    return nil, tostring(row.error_code or 'operation_rejected'), true
  end
  if tostring(row.status) ~= 'pending' then
    return nil, 'operation_state_invalid', true
  end
  return row, nil, false
end

local function buildCommerceFinancialData(operation, org, actorCitizenId, sourceResource, beforeBalance, afterBalance, receiptId)
  local spend = operation.operationType == 'spend'
  local purpose = tostring(operation.purpose or '')
  local basePurpose = spend and purpose or purpose:gsub('_refund$', '')
  local policy = ORG_COMMERCE_PURPOSES[basePurpose]
  if not policy or policy.resources[sourceResource] ~= true then
    return false, 'commerce_purpose_forbidden'
  end
  local category = spend and policy.category or policy.refundCategory
  local reason = spend and policy.reason or policy.refundReason
  local ledgerOptions = {
    __invokingResource = sourceResource,
    category = category,
    reason = reason,
    source_type = 'org_account_commerce',
    related_org_code = tostring(org.code),
    external_ref = receiptId,
    counts_as_income = false,
    counts_as_expense = spend,
    data = {
      channel = 'org',
      operation_key = operation.operationKey,
      related_ref = operation.relatedRef,
      purpose = operation.purpose
    }
  }
  local metadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(ledgerOptions, {})
  local ledgerBatch, ledgerErr = MZAccountService.BuildFinancialLedgerBatchInternal({
    correlationId = operation.correlationId,
    eventType = spend and 'org_account_spend' or 'org_account_refund',
    sourceCitizenId = actorCitizenId,
    account = 'org',
    amount = operation.amount,
    fee = 0,
    reason = reason,
    ledgerMetadata = metadata,
    options = ledgerOptions,
    entries = {
      MZAccountService.BuildFinancialLedgerEntryInternal(
        1, nil, 'org', spend and 'out' or 'in', operation.amount,
        beforeBalance, afterBalance, metadata
      )
    }
  })
  if ledgerBatch == false then return false, ledgerErr end
  return {
    ledgerBatch = ledgerBatch,
    metadata = metadata,
    reason = reason,
    category = category,
    direction = spend and 'out' or 'in'
  }
end

local function applyPendingCommerceOperation(row, org, player, source, sourceResource)
  local account = MySQL.single.await(
    'SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id }
  )
  if not account then return false, 'org_account_missing' end

  local amount = math.floor(tonumber(row.amount) or 0)
  local beforeBalance = math.floor(tonumber(account.balance) or 0)
  local spend = tostring(row.operation_type) == 'spend'
  local afterBalance
  if spend then
    if beforeBalance < amount then
      MZAccountRepository.rejectOrgAccountOperation(row.id, 'insufficient_org_funds')
      return false, 'insufficient_org_funds'
    end
    afterBalance = beforeBalance - amount
  else
    if beforeBalance > MAX_SAFE_INTEGER - amount then
      MZAccountRepository.rejectOrgAccountOperation(row.id, 'amount_overflow')
      return false, 'amount_overflow'
    end
    afterBalance = beforeBalance + amount
  end

  local receiptId = MZAccountService.GenerateFinancialTransactionRefInternal(
    spend and 'mzorg-spend' or 'mzorg-refund'
  )
  local correlationId = MZAccountService.GenerateFinancialTransactionRefInternal('mzacc-org-commerce')
  local financial, financialErr = buildCommerceFinancialData({
    operationType = tostring(row.operation_type),
    operationKey = tostring(row.operation_key),
    relatedRef = tostring(row.related_ref),
    purpose = tostring(row.purpose),
    amount = amount,
    correlationId = correlationId
  }, org, tostring(player.citizenid), sourceResource, beforeBalance, afterBalance, receiptId)
  if financial == false then return false, financialErr end

  local persisted = MZAccountRepository.applyOrgAccountOperation({
    operationId = tonumber(row.id),
    balanceBefore = beforeBalance,
    balanceAfter = afterBalance,
    receiptId = receiptId,
    correlationId = correlationId,
    actorName = getPlayerDisplayName(player, source),
    reason = financial.reason
  }, financial.ledgerBatch)
  if not persisted then return false, 'database_error' end

  local applied = MZAccountRepository.getOrgAccountOperation(sourceResource, tostring(row.operation_key))
  if not applied or tostring(applied.status) ~= 'applied' then
    return false, 'balance_conflict'
  end

  local receipt = normalizeCommerceReceipt(applied, false)
  return true, receipt
end

function MZOrgAccountService.getCommerceCapabilities()
  local ready = MZEconomyState and MZEconomyState.ready == true
  return {
    schemaVersion = ORG_COMMERCE_VERSION,
    ready = ready,
    spend = ready,
    refund = ready,
    idempotent = true,
    receipt = true,
    error = ready and nil or 'economy_not_ready',
    purposes = { 'facility_purchase', 'furniture_purchase' }
  }
end

function MZOrgAccountService.spend(source, organization, amount, options, sourceResource)
  source = tonumber(source)
  local org = normalizeOrganization(organization)
  local orgCode = org and org.code or nil
  amount = math.floor(tonumber(amount) or 0)
  options = type(options) == 'table' and options or {}
  sourceResource = normalizeSourceResource(sourceResource)

  if not MZEconomyState or MZEconomyState.ready ~= true then return false, 'economy_not_ready' end
  if not source or source <= 0 then return false, 'invalid_source' end
  if not orgCode then return false, 'invalid_org' end
  if amount <= 0 or amount > MAX_SAFE_INTEGER then return false, 'invalid_amount' end
  if not sourceResource then return false, 'invalid_source_resource' end

  local purpose = normalizeBoundedToken(options.purpose, 3, 64)
  local policy = purpose and ORG_COMMERCE_PURPOSES[purpose] or nil
  if not policy or policy.resources[sourceResource] ~= true then
    return false, 'commerce_purpose_forbidden'
  end
  local operationKey = normalizeBoundedToken(
    options.operationKey or options.idempotencyKey or options.idempotency_key, 16, 128
  )
  if not operationKey then return false, 'invalid_operation_key' end
  local relatedRef = normalizeBoundedToken(options.relatedRef or options.related_ref, 8, 128)
  if not relatedRef then return false, 'invalid_related_ref' end

  local player = MZEconomyCore.getPlayer(source)
  if not player or not player.citizenid then return false, 'player_not_loaded' end
  local okBalance, balanceOrErr = MZOrgAccountService.getBalance(org)
  if not okBalance then return false, balanceOrErr end
  if not asBool(org.active) then return false, 'org_archived' end
  local fingerprint = commerceFingerprint(
    'spend', sourceResource, org, player.citizenid, amount, purpose, relatedRef
  )
  local metadataJson = encodeCommerceMetadata({
    schemaVersion = ORG_COMMERCE_VERSION,
    operation = 'spend', purpose = purpose, relatedRef = relatedRef,
    sourceResource = sourceResource, userReason = normalizeReason(options.reason)
  })
  if not metadataJson then return false, 'invalid_metadata' end

  local lockedOk, resultOrErr = MZAccountService.WithFinancialLocksInternal({
    ('org:%s'):format(org.id),
    ('org-commerce:%s:%s'):format(sourceResource, operationKey)
  }, function()
    player = MZEconomyCore.getPlayer(source)
    if not player or not player.citizenid then return false, 'player_not_loaded' end
    local currentOrg = normalizeOrganization(organization)
    if not currentOrg or tonumber(currentOrg.id) ~= tonumber(org.id) then return false, 'org_not_found' end
    if not asBool(currentOrg.active) then return false, 'org_archived' end
    if not asBool(currentOrg.has_shared_account) then return false, 'org_has_no_shared_account' end

    local existing = MZAccountRepository.getOrgAccountOperation(sourceResource, operationKey)
    local recovered, recoverErr, terminal = recoverCommerceOperation(
      existing, 'spend', purpose, fingerprint
    )
    if terminal then
      if recovered then return true, recovered end
      return false, recoverErr
    end

    local operation = existing
    if not operation then
      local account = MySQL.single.await(
        'SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id }
      )
      if not account then return false, 'org_account_missing' end
      local insufficient = math.floor(tonumber(account.balance) or 0) < amount
      local operationId = MZAccountRepository.createOrgAccountOperation({
        sourceResource = sourceResource, operationKey = operationKey,
        operationType = 'spend', purpose = purpose, orgId = org.id,
        orgCode = tostring(org.code), actorCitizenId = tostring(player.citizenid),
        amount = amount, relatedRef = relatedRef, fingerprint = fingerprint,
        status = insufficient and 'rejected' or 'pending',
        errorCode = insufficient and 'insufficient_org_funds' or nil,
        metadataJson = metadataJson
      })
      if not operationId then return false, 'database_error' end
      if insufficient then return false, 'insufficient_org_funds' end
      operation = MZAccountRepository.getOrgAccountOperation(sourceResource, operationKey)
      if not operation then return false, 'database_error' end
    end

    return applyPendingCommerceOperation(operation, org, player, source, sourceResource)
  end)

  if not lockedOk then return false, resultOrErr end
  logOrgAccountAction('org.account.spend', org, source, resultOrErr.balanceBefore, resultOrErr.balanceAfter, {
    amount = amount, purpose = purpose, receipt_id = resultOrErr.receiptId,
    replayed = resultOrErr.replayed == true, source_resource = sourceResource
  })
  return true, resultOrErr
end

function MZOrgAccountService.refund(source, organization, spendReceiptId, options, sourceResource)
  source = tonumber(source)
  local org = normalizeOrganization(organization)
  local orgCode = org and org.code or nil
  options = type(options) == 'table' and options or {}
  sourceResource = normalizeSourceResource(sourceResource)
  spendReceiptId = normalizeBoundedToken(spendReceiptId, 8, 128)

  if not MZEconomyState or MZEconomyState.ready ~= true then return false, 'economy_not_ready' end
  if not source or source <= 0 then return false, 'invalid_source' end
  if not orgCode then return false, 'invalid_org' end
  if not sourceResource then return false, 'invalid_source_resource' end
  if not spendReceiptId then return false, 'invalid_receipt_id' end
  local operationKey = normalizeBoundedToken(
    options.operationKey or options.idempotencyKey or options.idempotency_key, 16, 128
  )
  if not operationKey then return false, 'invalid_operation_key' end
  local player = MZEconomyCore.getPlayer(source)
  if not player or not player.citizenid then return false, 'player_not_loaded' end
  if not org then return false, 'org_not_found' end
  if not asBool(org.has_shared_account) then return false, 'org_has_no_shared_account' end

  local original = MZAccountRepository.getOrgAccountOperationByReceipt(spendReceiptId)
  local originalPurpose = original and tostring(original.purpose or '') or ''
  local originalPolicy = ORG_COMMERCE_PURPOSES[originalPurpose]
  if not original or tostring(original.status) ~= 'applied'
      or tostring(original.operation_type) ~= 'spend'
      or not originalPolicy or originalPolicy.resources[sourceResource] ~= true then
    return false, 'spend_receipt_not_found'
  end
  if tostring(original.source_resource) ~= sourceResource
      or tostring(original.org_code) ~= tostring(org.code)
      or tostring(original.actor_citizenid) ~= tostring(player.citizenid) then
    return false, 'spend_receipt_forbidden'
  end

  local amount = math.floor(tonumber(original.amount) or 0)
  local purpose = originalPurpose .. '_refund'
  local relatedRef = spendReceiptId
  local fingerprint = commerceFingerprint(
    'refund', sourceResource, org, player.citizenid, amount, purpose,
    relatedRef, original.id
  )
  local metadataJson = encodeCommerceMetadata({
    schemaVersion = ORG_COMMERCE_VERSION,
    operation = 'refund', purpose = purpose, relatedRef = relatedRef,
    sourceResource = sourceResource, reversalOfOperationId = tonumber(original.id),
    userReason = normalizeReason(options.reason)
  })
  if not metadataJson then return false, 'invalid_metadata' end

  local lockedOk, resultOrErr = MZAccountService.WithFinancialLocksInternal({
    ('org:%s'):format(org.id),
    ('org-commerce:%s:%s'):format(sourceResource, operationKey),
    ('org-commerce-reversal:%s'):format(original.id)
  }, function()
    local existing = MZAccountRepository.getOrgAccountOperation(sourceResource, operationKey)
    local recovered, recoverErr, terminal = recoverCommerceOperation(
      existing, 'refund', purpose, fingerprint
    )
    if terminal then
      if recovered then return true, recovered end
      return false, recoverErr
    end

    local reversal = MZAccountRepository.getOrgAccountReversal(original.id)
    if reversal and (not existing or tonumber(reversal.id) ~= tonumber(existing.id)) then
      return false, 'spend_already_refunded'
    end

    local operation = existing
    if not operation then
      local operationId = MZAccountRepository.createOrgAccountOperation({
        sourceResource = sourceResource, operationKey = operationKey,
        operationType = 'refund', purpose = purpose, orgId = org.id,
        orgCode = tostring(org.code), actorCitizenId = tostring(player.citizenid),
        amount = amount, relatedRef = relatedRef, fingerprint = fingerprint,
        status = 'pending', reversalOfOperationId = tonumber(original.id),
        metadataJson = metadataJson
      })
      if not operationId then return false, 'database_error' end
      operation = MZAccountRepository.getOrgAccountOperation(sourceResource, operationKey)
      if not operation then return false, 'database_error' end
    end

    return applyPendingCommerceOperation(operation, org, player, source, sourceResource)
  end)

  if not lockedOk then return false, resultOrErr end
  logOrgAccountAction('org.account.refund', org, source, resultOrErr.balanceBefore, resultOrErr.balanceAfter, {
    amount = amount, receipt_id = resultOrErr.receiptId,
    spend_receipt_id = spendReceiptId, replayed = resultOrErr.replayed == true,
    source_resource = sourceResource
  })
  return true, resultOrErr
end

local function organizationOwnerCaller()
  return type(GetInvokingResource) == 'function' and GetInvokingResource() == 'mz_org'
end

exports('GetOrganizationAccount', function(source, organization)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.getAccountReadOnly(source, organization)
end)

exports('DepositOrganizationAccount', function(source, organization, amount, reason)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.deposit(source, organization, amount, reason)
end)

exports('WithdrawOrganizationAccount', function(source, organization, amount, reason)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.withdraw(source, organization, amount, reason)
end)

exports('ListOrganizationAccountTransactions', function(source, organization, filters)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.listTransactions(source, organization, filters)
end)

exports('GetOrganizationAccountCommerceCapabilities', function()
  return MZOrgAccountService.getCommerceCapabilities()
end)

exports('SpendOrganizationAccount', function(source, organization, amount, options, sourceResource)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.spend(source, organization, amount, options, sourceResource)
end)

exports('RefundOrganizationAccount', function(source, organization, spendReceiptId, options, sourceResource)
  if not organizationOwnerCaller() then return false, 'forbidden_caller' end
  return MZOrgAccountService.refund(source, organization, spendReceiptId, options, sourceResource)
end)
