MZPoliceChargeService = MZPoliceChargeService or {}

local MAX_SAFE_INTEGER = 9007199254740991

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function asBool(value)
  return value == true or value == 1 or trim(value):lower() == 'true'
end

local function normalizeOrganization(value)
  if type(value) ~= 'table' then return nil end
  local id = tonumber(value.id or value.orgId or value.org_id)
  local code = trim(value.code or value.orgCode or value.org_code):lower()
  if not id or id <= 0 or code == '' or #code > 64 or not code:match('^[a-z0-9_-]+$') then return nil end
  return {
    id = math.floor(id), code = code,
    active = asBool(value.active),
    hasSharedAccount = asBool(value.hasSharedAccount or value.has_shared_account)
  }
end

local function operationKey(value)
  value = trim(value)
  if #value < 16 or #value > 64 or not value:match('^[%w_-]+$') then return nil end
  return value
end

local function recover(citizenid, key, fingerprint)
  local row = MZAccountRepository.getIdempotentOperation('mz_police', citizenid, key)
  if not row then return nil, nil, false end
  if tostring(row.operation or '') ~= 'police_org_charge'
      or tostring(row.request_fingerprint or '') ~= fingerprint then
    return nil, 'idempotency_conflict', true
  end
  local ok, result = pcall(json.decode, tostring(row.result_json or ''))
  if not ok or type(result) ~= 'table' then return nil, 'database_error', true end
  result.replayed = true
  return result, nil, true
end

function MZPoliceChargeService.settle(targetSource, organization, amount, options)
  targetSource = tonumber(targetSource)
  local org = normalizeOrganization(organization)
  amount = tonumber(amount)
  options = type(options) == 'table' and options or {}
  local key = operationKey(options.idempotencyKey or options.idempotency_key)
  local reference = trim(options.reference)
  local expectedCitizenid = trim(options.targetCitizenid or options.target_citizenid)

  if not MZEconomyState or MZEconomyState.ready ~= true then return false, 'economy_not_ready' end
  if not targetSource or targetSource <= 0 then return false, 'invalid_target_source' end
  if not org then return false, 'invalid_org' end
  if not org.active then return false, 'org_archived' end
  if not org.hasSharedAccount then return false, 'org_has_no_shared_account' end
  if type(amount) ~= 'number' or amount ~= amount or amount == math.huge or amount == -math.huge
      or amount % 1 ~= 0 or amount <= 0 or amount > MAX_SAFE_INTEGER then return false, 'invalid_amount' end
  if not key then return false, 'invalid_idempotency_key' end
  if reference == '' or #reference > 128 then return false, 'invalid_reference' end

  local player = MZEconomyCore.getPlayer(targetSource)
  if not player or not player.citizenid then return false, 'target_not_loaded' end
  local citizenid = tostring(player.citizenid)
  if expectedCitizenid == '' or expectedCitizenid ~= citizenid then return false, 'target_identity_mismatch' end
  local fingerprint = table.concat({ citizenid, org.code, tostring(org.id), tostring(amount), reference }, '|')

  local locked, resultOrError = MZAccountService.WithFinancialLocksInternal({
    citizenid, ('org:%s'):format(org.id), ('police-charge:%s:%s'):format(citizenid, key)
  }, function()
    local stored, storedError, found = recover(citizenid, key, fingerprint)
    if found then return stored ~= nil, stored or storedError end

    player = MZEconomyCore.getPlayer(targetSource)
    if not player or tostring(player.citizenid or '') ~= citizenid then return false, 'target_identity_mismatch' end
    MySQL.insert.await([[
      INSERT INTO mz_org_accounts (org_id, balance) VALUES (?, 0)
      ON DUPLICATE KEY UPDATE org_id = VALUES(org_id)
    ]], { org.id })
    local account = MySQL.single.await('SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1', { org.id })
    if not account then return false, 'org_account_missing' end

    local playerBefore = math.floor(tonumber((player.money or {}).bank) or 0)
    local orgBefore = math.floor(tonumber(account.balance) or 0)
    if playerBefore < amount then return false, 'not_enough_money' end
    if orgBefore > MAX_SAFE_INTEGER - amount then return false, 'amount_overflow' end
    local playerAfter, orgAfter = playerBefore - amount, orgBefore + amount
    local correlationId = MZAccountService.GenerateFinancialTransactionRefInternal('mzacc-police-charge')
    local metadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal({
      __invokingResource = 'mz_police', category = 'police_citation', reason = 'police_citation',
      source_type = 'resource', related_org_code = org.code, related_citizenid = citizenid,
      external_ref = reference, counts_as_expense = true,
      data = { actor_citizenid = trim(options.actorCitizenid), reference = reference }
    }, {})
    local ledger, ledgerError = MZAccountService.BuildFinancialLedgerBatchInternal({
      correlationId = correlationId, eventType = 'police_org_charge', sourceCitizenId = citizenid,
      account = 'multi', amount = amount, fee = 0, reason = 'police_citation',
      ledgerMetadata = metadata, options = metadata,
      entries = {
        MZAccountService.BuildFinancialLedgerEntryInternal(
          1, citizenid, 'bank', 'out', amount, playerBefore, playerAfter, metadata
        ),
        MZAccountService.BuildFinancialLedgerEntryInternal(
          2, nil, 'org', 'in', amount, orgBefore, orgAfter, metadata
        )
      }
    })
    if ledger == false then return false, ledgerError end

    local result = {
      receiptId = correlationId, correlationId = correlationId, amount = amount,
      orgCode = org.code, targetCitizenid = citizenid,
      playerBalanceAfter = playerAfter, orgBalanceAfter = orgAfter, replayed = false
    }
    local idempotency = {
      sourceResource = 'mz_police', actorCitizenId = citizenid, key = key,
      operation = 'police_org_charge', fingerprint = fingerprint,
      correlationId = correlationId, resultJson = json.encode(result)
    }
    if not MZAccountRepository.transferPlayerBankAndOrg(
      citizenid, playerAfter, org.id, orgAfter, ledger, idempotency
    ) then
      local replay, replayError, replayFound = recover(citizenid, key, fingerprint)
      if replayFound then return replay ~= nil, replay or replayError end
      return false, 'database_error'
    end
    player.money = player.money or {}
    player.money.bank = playerAfter
    return true, result
  end)
  if not locked then return false, resultOrError end
  return true, resultOrError
end

exports('SettlePlayerOrganizationCharge', function(targetSource, organization, amount, options)
  if type(GetInvokingResource) ~= 'function' or GetInvokingResource() ~= 'mz_police' then
    return false, 'forbidden_caller'
  end
  return MZPoliceChargeService.settle(targetSource, organization, amount, options)
end)
