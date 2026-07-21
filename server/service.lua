MZEconomyService = MZEconomyService or {}

local randomSeeded = false

local function config()
  return (Config and Config.Economy) or {}
end

local function trim(value)
  local text = tostring(value or '')
  text = text:gsub('^%s+', '')
  text = text:gsub('%s+$', '')
  return text
end

local function truncate(value, length)
  value = trim(value)
  length = tonumber(length) or 64
  if #value > length then
    return value:sub(1, length)
  end
  return value
end

local function boolValue(value)
  if value == true or value == 1 then return true end
  local normalized = trim(value):lower()
  return normalized == 'true' or normalized == '1' or normalized == 'yes' or normalized == 'sim'
end

local function intBool(value)
  return boolValue(value) and 1 or 0
end

local function encodeJson(value)
  local ok, encoded = pcall(function()
    return json.encode(value)
  end)

  if ok and encoded then
    return encoded
  end

  return '{}'
end

local function normalizeMetadata(value)
  if type(value) == 'table' then
    return value
  end

  if value == nil then
    return {}
  end

  return {
    raw_metadata = tostring(value),
    raw_metadata_type = type(value)
  }
end

local function isReady()
  return MZEconomyState and MZEconomyState.prepareOk == true and MZEconomyState.ready == true
end

local function today()
  return os.date('%Y-%m-%d')
end

local function normalizeDate(date)
  date = trim(date)
  if date == '' then
    return today()
  end

  if date:match('^%d%d%d%d%-%d%d%-%d%d$') then
    return date
  end

  return nil, 'invalid_date'
end

local function debugLog(message)
  if config().Debug == true then
    print(('[mz_economy] %s'):format(tostring(message)))
  end
end

local function statsConfig()
  local stats = config().Stats
  if type(stats) ~= 'table' then stats = {} end

  return {
    minMinutesOnlineToCount = tonumber(stats.MinMinutesOnlineToCount) or 60,
    maxTopRows = tonumber(stats.MaxTopRows) or 10,
    includeOpenSessions = stats.IncludeOpenSessions ~= false
  }
end

local function normalizeLimit(limit)
  local cfg = statsConfig()
  local value = math.floor(tonumber(limit) or cfg.maxTopRows)
  if value < 1 then value = cfg.maxTopRows end
  if value > cfg.maxTopRows then value = cfg.maxTopRows end
  return value
end

local function reportsConfig()
  local reports = config().Reports
  if type(reports) ~= 'table' then reports = {} end

  return {
    maxRows = tonumber(reports.MaxRows) or 10,
    unknownWarningPercent = tonumber(reports.UnknownWarningPercent) or 5,
    unknownCriticalPercent = tonumber(reports.UnknownCriticalPercent) or 15,
    suspiciousIncomeMultiplier = tonumber(reports.SuspiciousIncomeMultiplier) or 3.0,
    minMinutesForSuspicious = tonumber(reports.MinMinutesForSuspicious) or 60,
    largeTransactionAmount = tonumber(reports.LargeTransactionAmount) or 100000
  }
end

local function normalizeReportLimit(limit)
  local cfg = reportsConfig()
  local value = math.floor(tonumber(limit) or cfg.maxRows)
  if value < 1 then value = cfg.maxRows end
  if value > cfg.maxRows then value = cfg.maxRows end
  return value
end

local function normalizeTopMode(mode)
  mode = trim(mode):lower()
  if mode == '' then return 'income' end
  if mode == 'income' or mode == 'expense' or mode == 'unknown' then
    return mode
  end

  return nil, 'invalid_top_mode'
end

local function getInvokingResourceSafe()
  if type(GetInvokingResource) ~= 'function' then
    return nil
  end

  local ok, resource = pcall(GetInvokingResource)
  if ok then
    return trim(resource)
  end

  return nil
end

local function seedRandom()
  if randomSeeded then return end

  local timer = type(GetGameTimer) == 'function' and GetGameTimer() or 0
  math.randomseed((os.time() or 0) + timer)
  randomSeeded = true
end

local function generateTransactionId()
  seedRandom()
  local timer = type(GetGameTimer) == 'function' and GetGameTimer() or 0
  return ('mzecon-%s-%s-%06d'):format(os.time(), timer, math.random(0, 999999))
end

local function resolveIdentity(data)
  data = type(data) == 'table' and data or {}
  local source = tonumber(data.source)
  local citizenid = trim(data.citizenid)
  local license = trim(data.license)

  if not source or source <= 0 then
    return citizenid, license, nil
  end

  local ok, identity = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)

  if ok and type(identity) == 'table' and identity.ok == true then
    if citizenid == '' then citizenid = trim(identity.citizenid) end
    if license == '' then license = trim(identity.license) end
    return citizenid, license, nil
  end

  local err = ok and (identity and identity.error or 'identity_not_found') or identity
  return citizenid, license, tostring(err or 'identity_error')
end

function MZEconomyService.NormalizeAccount(account)
  local cfg = config()
  local value = trim(account):lower()
  local aliases = type(cfg.AccountAliases) == 'table' and cfg.AccountAliases or {}
  local accounts = type(cfg.Accounts) == 'table' and cfg.Accounts or {}

  if aliases[value] then
    value = trim(aliases[value]):lower()
  end

  if value == '' or accounts[value] ~= true then
    return nil, 'invalid_account'
  end

  return value
end

function MZEconomyService.NormalizeCategory(category)
  local defaultCategory = trim(config().DefaultCategory)
  if defaultCategory == '' then defaultCategory = 'unknown' end

  category = truncate(category, 64)
  if category == '' then
    return defaultCategory
  end

  return category
end

function MZEconomyService.NormalizeDirection(direction)
  local value = trim(direction):lower()
  local directions = type(config().Directions) == 'table' and config().Directions or {}

  if value == '' or directions[value] ~= true then
    return nil, 'invalid_direction'
  end

  return value
end

function MZEconomyService.BuildTransactionPayload(data)
  data = type(data) == 'table' and data or {}

  local account, accountErr = MZEconomyService.NormalizeAccount(data.account)
  if not account then return false, accountErr end

  local direction, directionErr = MZEconomyService.NormalizeDirection(data.direction)
  if not direction then return false, directionErr end

  local amount = tonumber(data.amount)
  if not amount or amount <= 0 then
    return false, 'invalid_amount'
  end
  amount = math.floor(amount)
  if amount <= 0 then
    return false, 'invalid_amount'
  end

  local metadata = normalizeMetadata(data.metadata)
  local citizenid, license, identityError = resolveIdentity(data)

  local sourceResource = trim(data.source_resource or metadata.source_resource)
  if sourceResource == '' then
    sourceResource = getInvokingResourceSafe() or ''
  end
  if sourceResource == '' then
    sourceResource = trim(config().DefaultSourceResource)
  end
  if sourceResource == '' then
    sourceResource = 'unknown'
  end

  local countsAsIncome = boolValue(data.counts_as_income)
  local countsAsExpense = boolValue(data.counts_as_expense)

  if countsAsIncome and countsAsExpense and config().AllowIncomeExpenseSameTransaction ~= true then
    countsAsIncome = false
    countsAsExpense = false
    metadata.validation_warning = 'income_and_expense_flags_reset'
    print('[mz_economy] warning: transaction received income and expense flags; both reset to false')
  end

  if identityError then
    metadata.identity_warning = identityError
  end

  local payload = {
    transaction_id = truncate(data.transaction_id, 64),
    citizenid = truncate(citizenid, 64),
    license = truncate(license, 128),
    account = account,
    amount = amount,
    balance_before = data.balance_before ~= nil and math.floor(tonumber(data.balance_before) or 0) or nil,
    balance_after = data.balance_after ~= nil and math.floor(tonumber(data.balance_after) or 0) or nil,
    direction = direction,
    category = MZEconomyService.NormalizeCategory(data.category),
    reason = truncate(data.reason, 128),
    source_resource = truncate(sourceResource, 100),
    source_type = truncate(data.source_type, 64),
    counts_as_income = intBool(countsAsIncome),
    counts_as_expense = intBool(countsAsExpense),
    related_citizenid = truncate(data.related_citizenid, 64),
    related_org_code = truncate(data.related_org_code, 64),
    external_ref = truncate(data.external_ref, 128),
    metadata_json = encodeJson(metadata)
  }

  if payload.transaction_id == '' then
    payload.transaction_id = generateTransactionId()
  end

  if payload.citizenid == '' then payload.citizenid = nil end
  if payload.license == '' then payload.license = nil end
  if payload.reason == '' then payload.reason = nil end
  if payload.source_resource == '' then payload.source_resource = 'unknown' end
  if payload.source_type == '' then payload.source_type = nil end
  if payload.related_citizenid == '' then payload.related_citizenid = nil end
  if payload.related_org_code == '' then payload.related_org_code = nil end
  if payload.external_ref == '' then payload.external_ref = nil end

  return true, payload
end

function MZEconomyService.RecordTransaction(data)
  if not isReady() then
    return {
      ok = false,
      error = 'economy_not_ready',
      detail = MZEconomyState and MZEconomyState.prepareError or nil
    }
  end

  local built, payloadOrError = MZEconomyService.BuildTransactionPayload(data)
  if not built then
    return { ok = false, error = payloadOrError or 'invalid_transaction' }
  end

  local ok, insertId = pcall(function()
    return MZEconomyRepository.insertTransaction(payloadOrError)
  end)

  if not ok then
    print(('[mz_economy] insert failed: %s'):format(tostring(insertId)))
    return { ok = false, error = 'insert_failed', detail = tostring(insertId) }
  end

  debugLog(('recorded transaction id=%s tx=%s'):format(tostring(insertId), tostring(payloadOrError.transaction_id)))
  return {
    ok = true,
    id = insertId,
    transaction_id = payloadOrError.transaction_id
  }
end

function MZEconomyService.GetDailySummary(date)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local ok, result = pcall(function()
    return MZEconomyRepository.getDailySummary(normalized)
  end)

  if not ok then return false, tostring(result) end
  return true, result
end

function MZEconomyService.GetUnknownTransactions(date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local cfg = config()
  limit = tonumber(limit) or tonumber(cfg.UnknownLimitDefault) or 25
  local maxLimit = tonumber(cfg.UnknownLimitMax) or 100
  if limit < 1 then limit = tonumber(cfg.UnknownLimitDefault) or 25 end
  if limit > maxLimit then limit = maxLimit end

  local ok, result = pcall(function()
    return MZEconomyRepository.getUnknownTransactions(normalized, limit)
  end)

  if not ok then return false, tostring(result) end
  return true, { date = normalized, limit = limit, rows = result }
end

function MZEconomyService.GetSourceSummary(date)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local ok, result = pcall(function()
    return MZEconomyRepository.getSourceSummary(normalized)
  end)

  if not ok then return false, tostring(result) end
  return true, { date = normalized, rows = result }
end

function MZEconomyService.GetHealthReport(date)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local ok, result = pcall(function()
    return MZEconomyRepository.getHealthReport(normalized)
  end)

  if not ok then return false, tostring(result) end

  local cfg = reportsConfig()
  local total = tonumber(result.totalTransactions) or 0
  local unknown = tonumber(result.unknownCount) or 0
  local unknownPercent = 0
  if total > 0 then
    unknownPercent = (unknown / total) * 100
  end

  local status = 'OK'
  if unknownPercent >= cfg.unknownCriticalPercent then
    status = 'CRITICO'
  elseif unknownPercent >= cfg.unknownWarningPercent then
    status = 'ATENCAO'
  end

  result.date = normalized
  result.unknownPercent = unknownPercent
  result.status = status
  result.thresholds = {
    unknownWarningPercent = cfg.unknownWarningPercent,
    unknownCriticalPercent = cfg.unknownCriticalPercent
  }

  return true, result
end

function MZEconomyService.GetUnknownSources(date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local normalizedLimit = normalizeReportLimit(limit)
  local ok, rows = pcall(function()
    return MZEconomyRepository.getUnknownSources(normalized, normalizedLimit)
  end)

  if not ok then return false, tostring(rows) end
  return true, { date = normalized, limit = normalizedLimit, rows = rows }
end

function MZEconomyService.GetCategoryReport(date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local normalizedLimit = normalizeReportLimit(limit)
  local ok, rows = pcall(function()
    return MZEconomyRepository.getCategoryReport(normalized, normalizedLimit)
  end)

  if not ok then return false, tostring(rows) end
  return true, { date = normalized, limit = normalizedLimit, rows = rows }
end

function MZEconomyService.GetSuspiciousReport(date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local cfg = reportsConfig()
  local normalizedLimit = normalizeReportLimit(limit)
  local report = {
    date = normalized,
    limit = normalizedLimit,
    largeTransactionAmount = cfg.largeTransactionAmount,
    suspiciousIncomeMultiplier = cfg.suspiciousIncomeMultiplier,
    minMinutesForSuspicious = cfg.minMinutesForSuspicious,
    dailyStatsAvailable = true,
    largeTransactions = {},
    highUnknownPlayers = {},
    highAdjustmentPlayers = {},
    highIncomePerHour = {},
    badIncomeCategories = {},
    unknownSourceTransactions = {}
  }

  local ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousLargeTransactions(
      normalized,
      cfg.largeTransactionAmount,
      normalizedLimit
    )
  end)
  if not ok then return false, tostring(rows) end
  report.largeTransactions = rows

  ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousUnknownPlayers(normalized, normalizedLimit)
  end)
  if not ok then return false, tostring(rows) end
  report.highUnknownPlayers = rows

  ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousAdjustmentPlayers(normalized, normalizedLimit)
  end)
  if not ok then return false, tostring(rows) end
  report.highAdjustmentPlayers = rows

  ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousIncomePerHour(
      normalized,
      cfg.minMinutesForSuspicious,
      cfg.suspiciousIncomeMultiplier,
      normalizedLimit
    )
  end)
  if ok then
    report.highIncomePerHour = rows
  else
    report.dailyStatsAvailable = false
    report.dailyStatsError = tostring(rows)
  end

  ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousBadIncomeCategories(normalized, normalizedLimit)
  end)
  if not ok then return false, tostring(rows) end
  report.badIncomeCategories = rows

  ok, rows = pcall(function()
    return MZEconomyRepository.getSuspiciousUnknownSourceTransactions(normalized, normalizedLimit)
  end)
  if not ok then return false, tostring(rows) end
  report.unknownSourceTransactions = rows

  return true, report
end

function MZEconomyService.RebuildDailyStats(date)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local cfg = statsConfig()
  local ok, affected, affectedErr = pcall(function()
    return MZEconomyRepository.rebuildDailyPlayerStats(normalized, {
      includeOpenSessions = cfg.includeOpenSessions
    })
  end)

  if not ok then return false, tostring(affected) end
  if affected == false then return false, affectedErr or 'daily_stats_rebuild_failed' end

  local summaryOk, summary = MZEconomyService.GetDailyStatsSummary(normalized)
  if not summaryOk then
    return false, summary
  end

  summary.rebuiltRows = tonumber(affected) or 0
  return true, summary
end

function MZEconomyService.GetDailyStatsSummary(date)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local cfg = statsConfig()
  local ok, result = pcall(function()
    return MZEconomyRepository.getDailyStatsSummary(
      normalized,
      cfg.minMinutesOnlineToCount,
      math.min(cfg.maxTopRows, 5)
    )
  end)

  if not ok then return false, tostring(result) end
  result.date = normalized
  result.minMinutesOnlineToCount = cfg.minMinutesOnlineToCount
  return true, result
end

function MZEconomyService.ResolveCitizenIdTarget(target)
  target = trim(target)
  if target == '' then return nil, 'invalid_target' end

  local source = tonumber(target)
  if source and source > 0 and math.floor(source) == source then
    local ok, identity = pcall(function()
      return exports['mz_core']:ResolvePlayerIdentity(source)
    end)

    if ok and type(identity) == 'table' and identity.ok == true and trim(identity.citizenid) ~= '' then
      return trim(identity.citizenid), {
        resolvedFrom = 'source',
        source = source,
        license = trim(identity.license),
        name = trim((identity.firstname or '') .. ' ' .. (identity.lastname or ''))
      }
    end
  end

  return target, {
    resolvedFrom = 'citizenid'
  }
end

function MZEconomyService.GetDailyPlayerStats(target, date)
  if not isReady() then return false, 'economy_not_ready' end

  local citizenid, targetInfoOrErr = MZEconomyService.ResolveCitizenIdTarget(target)
  if not citizenid then return false, targetInfoOrErr end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local ok, row = pcall(function()
    return MZEconomyRepository.getDailyPlayerStats(normalized, citizenid)
  end)

  if not ok then return false, tostring(row) end
  if not row then
    return false, 'daily_stats_not_found'
  end

  row.date = normalized
  row.target = targetInfoOrErr
  return true, row
end

function MZEconomyService.GetDailyTop(date, mode, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local normalizedMode, modeErr = normalizeTopMode(mode)
  if not normalizedMode then return false, modeErr end

  local normalizedLimit = normalizeLimit(limit)
  local ok, rows = pcall(function()
    return MZEconomyRepository.getDailyTop(normalized, normalizedMode, normalizedLimit)
  end)

  if not ok then return false, tostring(rows) end
  return true, {
    date = normalized,
    mode = normalizedMode,
    limit = normalizedLimit,
    rows = rows
  }
end

function MZEconomyService.GetPlayerTransactions(target, date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  local citizenid, targetInfoOrErr = MZEconomyService.ResolveCitizenIdTarget(target)
  if not citizenid then return false, targetInfoOrErr end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local normalizedLimit = normalizeReportLimit(limit)
  local ok, rows = pcall(function()
    return MZEconomyRepository.getPlayerTransactions(citizenid, normalized, normalizedLimit)
  end)

  if not ok then return false, tostring(rows) end
  return true, {
    date = normalized,
    target = targetInfoOrErr,
    citizenid = citizenid,
    limit = normalizedLimit,
    rows = rows
  }
end

function MZEconomyService.GetAccountStatement(source, account, limit)
  if not isReady() then return false, 'economy_not_ready' end

  source = tonumber(source)
  if not source or source <= 0 then return false, 'invalid_source' end

  local okIdentity, identity = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not okIdentity or type(identity) ~= 'table' or identity.ok ~= true or trim(identity.citizenid) == '' then
    return false, 'player_not_loaded'
  end

  local normalizedAccount, accountErr = MZEconomyService.NormalizeAccount(account or 'bank')
  if not normalizedAccount then return false, accountErr end

  local normalizedLimit = math.floor(tonumber(limit) or 15)
  if normalizedLimit < 1 then normalizedLimit = 1 end
  if normalizedLimit > (tonumber(config().StatementLimitMax) or 100) then
    normalizedLimit = tonumber(config().StatementLimitMax) or 100
  end
  local ok, rows = pcall(function()
    return MZEconomyRepository.getAccountStatement(trim(identity.citizenid), normalizedAccount, normalizedLimit)
  end)

  if not ok then return false, 'database_error' end
  return true, {
    account = normalizedAccount,
    limit = normalizedLimit,
    rows = rows
  }
end

function MZEconomyService.GetSourceTransactions(sourceResource, date, limit)
  if not isReady() then return false, 'economy_not_ready' end

  sourceResource = truncate(sourceResource, 100)
  if sourceResource == '' then return false, 'invalid_source_resource' end

  local normalized, err = normalizeDate(date)
  if not normalized then return false, err end

  local normalizedLimit = normalizeReportLimit(limit)
  local ok, rows = pcall(function()
    return MZEconomyRepository.getSourceTransactions(sourceResource, normalized, normalizedLimit)
  end)

  if not ok then return false, tostring(rows) end
  return true, {
    date = normalized,
    sourceResource = sourceResource,
    limit = normalizedLimit,
    rows = rows
  }
end
