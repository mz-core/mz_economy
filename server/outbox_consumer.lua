-- Fase 3 / P3-C
-- Consumer privado e idempotente do ledger. Nao faz claim, ACK, retry,
-- dead-letter ou qualquer escrita na outbox pertencente ao mz_core.

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_PAYLOAD_BYTES = 32768
local MAX_ENTRIES = 8

local ALLOWED_CHANNELS = {
  atm = true,
  branch = true,
  system = true,
  resource = true,
  admin = true,
  payroll = true,
  org = true
}

local SINGLE_ENTRY_EVENTS = {
  add_money = 'in',
  remove_money = 'out',
  set_money = 'adjustment'
}

local ORG_ENTRY_EVENTS = {
  org_account_adjustment = true,
  org_transfer = true,
  payroll_payment = true
}

local FORBIDDEN_KEYS = {
  license = true,
  playerlicense = true,
  source = true,
  playersource = true,
  token = true,
  sessiontoken = true,
  resolutiontoken = true,
  pin = true,
  card = true,
  carduid = true,
  coords = true,
  coordinates = true,
  location = true
}

local function trim(value)
  if type(value) ~= 'string' then return '' end
  return value:match('^%s*(.-)%s*$') or ''
end

local function boundedString(value, maxLength, allowEmpty)
  local text = trim(value)
  if text == '' and allowEmpty ~= true then return nil end
  if #text > maxLength then return nil end
  return text
end

local function strictInteger(value, minimum, maximum)
  if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  if value % 1 ~= 0 or value < minimum or value > maximum then return nil end
  return math.floor(value)
end

local function eventValue(event, camelName, snakeName)
  if event[camelName] ~= nil then return event[camelName] end
  return event[snakeName]
end

local function consumerStateReady()
  local state = MZEconomyState and MZEconomyState.financialOutbox
  if not MZEconomyState or MZEconomyState.ready ~= true then
    return false, 'economy_not_ready'
  end
  if type(state) ~= 'table' or state.schemaReady ~= true then
    return false, 'outbox_receipt_schema_not_ready'
  end
  if state.enabled ~= true or state.consumerEnabled ~= true then
    return false, 'outbox_consumer_disabled'
  end
  return true
end

local function invokingResource()
  if type(GetInvokingResource) ~= 'function' then return nil end
  local ok, resource = pcall(GetInvokingResource)
  if not ok then return nil end
  return trim(resource)
end

local function containsForbiddenKey(value, depth)
  if type(value) ~= 'table' then return false end
  depth = (depth or 0) + 1
  if depth > 12 then return true end

  for key, nested in pairs(value) do
    if type(key) == 'string' then
      local normalized = key:lower():gsub('[^%w]', '')
      if FORBIDDEN_KEYS[normalized] == true then return true end
    end
    if type(nested) == 'table' and containsForbiddenKey(nested, depth) then return true end
  end
  return false
end

local function encodeJson(value)
  local ok, encoded = pcall(json.encode, value)
  if not ok or type(encoded) ~= 'string' then return nil end
  return encoded
end

local function decodeEnvelope(metadataJson)
  if type(metadataJson) ~= 'string' or metadataJson == '' or #metadataJson > MAX_PAYLOAD_BYTES then
    return nil, 'outbox_invalid_payload'
  end
  local ok, envelope = pcall(json.decode, metadataJson)
  if not ok or type(envelope) ~= 'table' then
    return nil, 'outbox_invalid_payload_json'
  end
  if containsForbiddenKey(envelope) then
    return nil, 'outbox_forbidden_payload_field'
  end
  return envelope
end

local function normalizeEvent(event)
  if type(event) ~= 'table' then return nil, 'outbox_invalid_event' end

  local normalized = {
    id = strictInteger(eventValue(event, 'id', 'id'), 1, MAX_SAFE_INTEGER),
    correlationId = boundedString(eventValue(event, 'correlationId', 'correlation_id'), 128),
    eventType = boundedString(eventValue(event, 'eventType', 'event_type'), 64),
    sourceCitizenId = boundedString(eventValue(event, 'sourceCitizenId', 'source_citizenid'), 64, true),
    targetCitizenId = boundedString(eventValue(event, 'targetCitizenId', 'target_citizenid'), 64, true),
    account = boundedString(eventValue(event, 'account', 'account'), 32),
    amount = strictInteger(eventValue(event, 'amount', 'amount'), 1, MAX_SAFE_INTEGER),
    fee = strictInteger(eventValue(event, 'fee', 'fee'), 0, MAX_SAFE_INTEGER),
    reason = boundedString(eventValue(event, 'reason', 'reason'), 128),
    sourceResource = boundedString(eventValue(event, 'sourceResource', 'source_resource'), 100),
    sourceChannel = boundedString(eventValue(event, 'sourceChannel', 'source_channel'), 32),
    payloadVersion = strictInteger(eventValue(event, 'payloadVersion', 'payload_version'), 1, 65535),
    metadataJson = eventValue(event, 'metadataJson', 'metadata_json')
  }

  if not normalized.id then return nil, 'outbox_invalid_id' end
  if not normalized.correlationId then return nil, 'outbox_invalid_correlation_id' end
  if not normalized.eventType then return nil, 'outbox_invalid_event_type' end
  if normalized.sourceCitizenId == nil then return nil, 'outbox_invalid_source_citizenid' end
  if normalized.sourceCitizenId == '' then normalized.sourceCitizenId = nil end
  if normalized.targetCitizenId == nil then return nil, 'outbox_invalid_target_citizenid' end
  if normalized.targetCitizenId == '' then normalized.targetCitizenId = nil end
  if not normalized.account then return nil, 'outbox_invalid_account' end
  if not normalized.amount then return nil, 'outbox_invalid_amount' end
  if not normalized.fee then return nil, 'outbox_invalid_fee' end
  if normalized.amount > MAX_SAFE_INTEGER - normalized.fee then return nil, 'outbox_invalid_fee' end
  if not normalized.reason then return nil, 'outbox_invalid_reason' end
  if not normalized.sourceResource then return nil, 'outbox_invalid_source_resource' end
  if not normalized.sourceChannel or ALLOWED_CHANNELS[normalized.sourceChannel] ~= true then
    return nil, 'outbox_invalid_source_channel'
  end
  if normalized.payloadVersion ~= 1 then return nil, 'outbox_unsupported_payload_version' end

  local envelope, envelopeErr = decodeEnvelope(normalized.metadataJson)
  if not envelope then return nil, envelopeErr end
  normalized.envelope = envelope
  return normalized
end

local function validateContext(event)
  local envelope = event.envelope
  if envelope.version ~= 1 then return nil, 'outbox_envelope_version_mismatch' end
  if trim(envelope.operation) ~= event.eventType then return nil, 'outbox_operation_mismatch' end
  if trim(envelope.correlationId) ~= event.correlationId then return nil, 'outbox_correlation_mismatch' end
  if type(envelope.context) ~= 'table' then return nil, 'outbox_invalid_context' end

  local sourceResource = boundedString(envelope.context.sourceResource, 100)
  local sourceChannel = boundedString(envelope.context.sourceChannel, 32)
  local sourceType = boundedString(envelope.context.sourceType, 64, true)
  local category = boundedString(envelope.context.category, 64, true)
  if sourceResource ~= event.sourceResource then return nil, 'outbox_source_resource_mismatch' end
  if sourceChannel ~= event.sourceChannel or ALLOWED_CHANNELS[sourceChannel] ~= true then
    return nil, 'outbox_source_channel_mismatch'
  end
  if sourceType == nil or category == nil then return nil, 'outbox_invalid_context' end

  return {
    sourceResource = sourceResource,
    sourceChannel = sourceChannel,
    sourceType = sourceType,
    category = category
  }
end

local function validateEntries(event, context)
  local entries = event.envelope.entries
  if type(entries) ~= 'table' or #entries < 1 or #entries > MAX_ENTRIES then
    return nil, 'outbox_invalid_entries'
  end

  local singleEntryDirection = SINGLE_ENTRY_EVENTS[event.eventType]
  local isTransfer = event.eventType == 'transfer_between_accounts' or event.eventType == 'bank_transfer'
  local isOrgEvent = ORG_ENTRY_EVENTS[event.eventType] == true
  if not isTransfer and not singleEntryDirection and not isOrgEvent then
    return nil, 'outbox_unsupported_event_type'
  end
  local expectedEntryCount = (singleEntryDirection or event.eventType == 'org_account_adjustment') and 1 or 2
  if #entries ~= expectedEntryCount then return nil, 'outbox_invalid_entry_count' end

  local payloads = {}
  for index, entry in ipairs(entries) do
    if type(entry) ~= 'table' then return nil, 'outbox_invalid_entry' end
    local leg = strictInteger(entry.leg, 1, MAX_ENTRIES)
    if leg ~= index then return nil, 'outbox_invalid_leg' end

    local citizenid = boundedString(entry.citizenid, 64, true)
    local account, accountErr = MZEconomyService.NormalizeAccount(entry.account)
    local direction, directionErr = MZEconomyService.NormalizeDirection(entry.direction)
    local amount = strictInteger(entry.amount, 1, MAX_SAFE_INTEGER)
    local balanceBefore = strictInteger(entry.balanceBefore, 0, MAX_SAFE_INTEGER)
    local balanceAfter = strictInteger(entry.balanceAfter, 0, MAX_SAFE_INTEGER)
    local category = boundedString(entry.category, 64)
    local reason = boundedString(entry.reason, 128)
    local relatedCitizenid = boundedString(entry.relatedCitizenid, 64, true)
    local relatedOrgCode = boundedString(entry.relatedOrgCode, 64, true)
    local externalRef = boundedString(entry.externalRef, 128, true)
    if citizenid == nil then return nil, 'outbox_invalid_entry_citizenid' end
    if not account then return nil, accountErr or 'outbox_invalid_entry_account' end
    if account ~= 'org' and citizenid == '' then return nil, 'outbox_invalid_entry_citizenid' end
    if account == 'org' and relatedOrgCode == '' then return nil, 'outbox_invalid_entry_org' end
    if direction ~= 'in' and direction ~= 'out' and direction ~= 'adjustment' then
      return nil, directionErr or 'outbox_invalid_entry_direction'
    end
    if not amount then return nil, 'outbox_invalid_entry_amount' end
    if not balanceBefore or not balanceAfter then return nil, 'outbox_invalid_entry_balance' end
    if direction == 'out' and balanceBefore - balanceAfter ~= amount then
      return nil, 'outbox_entry_balance_mismatch'
    end
    if direction == 'in' and balanceAfter - balanceBefore ~= amount then
      return nil, 'outbox_entry_balance_mismatch'
    end
    if direction == 'adjustment' and math.abs(balanceAfter - balanceBefore) ~= amount then
      return nil, 'outbox_entry_balance_mismatch'
    end
    if not category or not reason or relatedCitizenid == nil or relatedOrgCode == nil or externalRef == nil then
      return nil, 'outbox_invalid_entry_metadata'
    end
    if type(entry.countsAsIncome) ~= 'boolean' or type(entry.countsAsExpense) ~= 'boolean' then
      return nil, 'outbox_invalid_entry_flags'
    end
    if entry.countsAsIncome and entry.countsAsExpense then
      return nil, 'outbox_invalid_entry_flags'
    end

    local built, payload = MZEconomyService.BuildTransactionPayload({
      transaction_id = ('mzoutbox:%d:%d'):format(event.id, leg),
      citizenid = citizenid ~= '' and citizenid or nil,
      account = account,
      amount = amount,
      balance_before = balanceBefore,
      balance_after = balanceAfter,
      direction = direction,
      category = category,
      reason = reason,
      source_resource = context.sourceResource,
      source_type = context.sourceType ~= '' and context.sourceType or context.sourceChannel,
      counts_as_income = entry.countsAsIncome,
      counts_as_expense = entry.countsAsExpense,
      related_citizenid = relatedCitizenid,
      related_org_code = relatedOrgCode,
      external_ref = externalRef ~= '' and externalRef or event.correlationId,
      metadata = {
        outbox_id = event.id,
        correlation_id = event.correlationId,
        event_type = event.eventType,
        leg = leg,
        payload_version = event.payloadVersion
      }
    })
    if built ~= true or type(payload) ~= 'table' then
      return nil, payload or 'outbox_entry_build_failed'
    end
    if account == 'org' then payload.citizenid = nil end
    payload.license = nil
    payloads[index] = payload
  end

  local first, second = entries[1], entries[2]
  if singleEntryDirection then
    if not event.sourceCitizenId then return nil, 'outbox_invalid_source_citizenid' end
    if event.targetCitizenId ~= nil or event.fee ~= 0 or event.account ~= first.account then
      return nil, 'outbox_operation_mismatch'
    end
    if first.citizenid ~= event.sourceCitizenId or first.amount ~= event.amount then
      return nil, 'outbox_owner_mismatch'
    end
    if event.eventType == 'set_money' then
      if first.direction ~= 'adjustment' and first.direction ~= 'in' and first.direction ~= 'out' then
        return nil, 'outbox_invalid_entry_direction'
      end
    elseif first.direction ~= singleEntryDirection then
      return nil, 'outbox_invalid_entry_direction'
    end
    if trim(first.reason) ~= event.reason or trim(first.category) ~= context.category then
      return nil, 'outbox_entry_context_mismatch'
    end
    return payloads
  end


  if event.eventType == 'org_account_adjustment' then
    if event.targetCitizenId ~= nil or event.fee ~= 0 or event.account ~= 'org'
        or first.account ~= 'org' or first.direction ~= 'adjustment' then
      return nil, 'outbox_operation_mismatch'
    end
    if first.amount ~= event.amount or trim(first.relatedOrgCode) == '' then
      return nil, 'outbox_amount_mismatch'
    end
    if trim(first.reason) ~= event.reason or trim(first.category) ~= context.category then
      return nil, 'outbox_entry_context_mismatch'
    end
    return payloads
  end

  if event.eventType == 'org_transfer' or event.eventType == 'payroll_payment' then
    if not event.sourceCitizenId or event.targetCitizenId ~= nil or event.fee ~= 0
        or event.account ~= 'multi' then
      return nil, 'outbox_operation_mismatch'
    end
    local orgEntry = first.account == 'org' and first or second
    local playerEntry = first.account == 'bank' and first or second
    if not orgEntry or not playerEntry or orgEntry.account ~= 'org' or playerEntry.account ~= 'bank' then
      return nil, 'outbox_operation_mismatch'
    end
    if playerEntry.citizenid ~= event.sourceCitizenId
        or first.amount ~= event.amount or second.amount ~= event.amount
        or trim(orgEntry.relatedOrgCode) == '' then
      return nil, 'outbox_owner_mismatch'
    end
    if first.direction == second.direction or (first.direction ~= 'out' and second.direction ~= 'out')
        or (first.direction ~= 'in' and second.direction ~= 'in') then
      return nil, 'outbox_invalid_entry_order'
    end
    if event.eventType == 'payroll_payment'
        and (orgEntry.direction ~= 'out' or playerEntry.direction ~= 'in') then
      return nil, 'outbox_operation_mismatch'
    end
    if event.eventType == 'org_transfer' then
      if trim(first.category) ~= context.category or trim(second.category) ~= context.category then
        return nil, 'outbox_entry_context_mismatch'
      end
    elseif trim(playerEntry.category) ~= context.category
        or trim(orgEntry.category) ~= 'salary_expense' then
      return nil, 'outbox_entry_context_mismatch'
    end
    return payloads
  end

  if first.direction ~= 'out' or second.direction ~= 'in' then
    return nil, 'outbox_invalid_entry_order'
  end

  if event.eventType == 'transfer_between_accounts' then
    if event.targetCitizenId ~= nil or event.fee ~= 0 or event.account ~= 'multi' then
      return nil, 'outbox_operation_mismatch'
    end
    if first.citizenid ~= event.sourceCitizenId or second.citizenid ~= event.sourceCitizenId then
      return nil, 'outbox_owner_mismatch'
    end
    if first.amount ~= event.amount or second.amount ~= event.amount then
      return nil, 'outbox_amount_mismatch'
    end
  else
    if event.account ~= 'bank' or not event.targetCitizenId
        or event.targetCitizenId == event.sourceCitizenId then
      return nil, 'outbox_target_mismatch'
    end
    if first.citizenid ~= event.sourceCitizenId or second.citizenid ~= event.targetCitizenId then
      return nil, 'outbox_owner_mismatch'
    end
    if first.amount ~= event.amount + event.fee or second.amount ~= event.amount then
      return nil, 'outbox_amount_mismatch'
    end
    if trim(first.relatedCitizenid) ~= event.targetCitizenId
        or trim(second.relatedCitizenid) ~= event.sourceCitizenId then
      return nil, 'outbox_related_owner_mismatch'
    end
  end

  if trim(first.reason) ~= event.reason or trim(first.category) ~= context.category
      or trim(second.category) ~= context.category then
    return nil, 'outbox_entry_context_mismatch'
  end

  return payloads
end

local function matchingReceipt(rows, event, entryCount)
  if type(rows) ~= 'table' or #rows == 0 then return false, false end
  if #rows ~= 1 then return false, true end
  local row = rows[1]
  local matches = tonumber(row.outbox_id) == event.id
    and tostring(row.correlation_id or '') == event.correlationId
    and tonumber(row.payload_version) == event.payloadVersion
    and tonumber(row.entry_count) == entryCount
  return matches, not matches
end

local function findReceipt(event)
  local ok, rows = pcall(function()
    return MZEconomyRepository.findOutboxReceipts(event.id, event.correlationId)
  end)
  if not ok then return nil, 'outbox_receipt_lookup_failed' end
  return rows
end

function MZEconomyService.ConsumeFinancialOutbox(rawEvent)
  if invokingResource() ~= 'mz_core' then
    return { ok = false, error = 'outbox_consumer_forbidden', retryable = false }
  end

  local ready, readyErr = consumerStateReady()
  if not ready then return { ok = false, error = readyErr, retryable = true } end

  local event, eventErr = normalizeEvent(rawEvent)
  if not event then return { ok = false, error = eventErr, retryable = false } end

  local context, contextErr = validateContext(event)
  if not context then return { ok = false, error = contextErr, retryable = false } end

  local payloads, payloadErr = validateEntries(event, context)
  if not payloads then return { ok = false, error = payloadErr, retryable = false } end

  local rows, lookupErr = findReceipt(event)
  if not rows then return { ok = false, error = lookupErr, retryable = true } end
  local replay, conflict = matchingReceipt(rows, event, #payloads)
  if replay then
    return {
      ok = true,
      replayed = true,
      outboxId = event.id,
      correlationId = event.correlationId,
      entryCount = #payloads
    }
  end
  if conflict then
    return { ok = false, error = 'outbox_receipt_conflict', retryable = false }
  end

  local receiptMetadata = encodeJson({
    event_type = event.eventType,
    source_resource = context.sourceResource,
    payload_version = event.payloadVersion
  })
  if not receiptMetadata then
    return { ok = false, error = 'outbox_receipt_encode_failed', retryable = false }
  end

  local committedOk, committed = pcall(function()
    return MZEconomyRepository.consumeFinancialOutbox({
      outboxId = event.id,
      correlationId = event.correlationId,
      payloadVersion = event.payloadVersion,
      entryCount = #payloads,
      metadataJson = receiptMetadata
    }, payloads)
  end)

  if not committedOk or committed ~= true then
    local raceRows = findReceipt(event)
    local raceReplay, raceConflict = false, false
    if raceRows then
      raceReplay, raceConflict = matchingReceipt(raceRows, event, #payloads)
    end
    if raceReplay then
      return {
        ok = true,
        replayed = true,
        outboxId = event.id,
        correlationId = event.correlationId,
        entryCount = #payloads
      }
    end
    if raceConflict then
      return { ok = false, error = 'outbox_receipt_conflict', retryable = false }
    end
    return { ok = false, error = 'outbox_consume_failed', retryable = true }
  end

  return {
    ok = true,
    replayed = false,
    outboxId = event.id,
    correlationId = event.correlationId,
    entryCount = #payloads
  }
end

function MZEconomyService.GetFinancialOutboxConsumerReadiness()
  if invokingResource() ~= 'mz_core' then
    return { ok = false, ready = false, error = 'outbox_consumer_forbidden' }
  end

  local ready, readyErr = consumerStateReady()
  if not ready then
    return { ok = true, ready = false, error = readyErr }
  end

  return {
    ok = true,
    ready = true,
    schemaVersion = MZEconomyState.financialOutbox.schemaVersion
  }
end

function MZEconomyService.ValidateFinancialOutbox(rawEvent)
  if invokingResource() ~= 'mz_core' then
    return { ok = false, error = 'outbox_consumer_forbidden', retryable = false }
  end

  local ready, readyErr = consumerStateReady()
  if not ready then return { ok = false, error = readyErr, retryable = true } end

  local event, eventErr = normalizeEvent(rawEvent)
  if not event then return { ok = false, error = eventErr, retryable = false } end
  local context, contextErr = validateContext(event)
  if not context then return { ok = false, error = contextErr, retryable = false } end
  local payloads, payloadErr = validateEntries(event, context)
  if not payloads then return { ok = false, error = payloadErr, retryable = false } end

  return {
    ok = true,
    outboxId = event.id,
    entryCount = #payloads,
    payloadVersion = event.payloadVersion
  }
end
