local function trim(value)
  local text = tostring(value or '')
  text = text:gsub('^%s+', '')
  text = text:gsub('%s+$', '')
  return text
end

local function isAceAllowed(src, ace)
  local sourceId = tonumber(src)
  if not sourceId or sourceId <= 0 then return false end

  ace = trim(ace)
  if ace == '' then return false end

  local allowed = IsPlayerAceAllowed(sourceId, ace)
  local normalized = tostring(allowed):lower()
  return allowed == true or allowed == 1 or normalized == '1' or normalized == 'true'
end

local function canUseEconomyCommand(src)
  if tonumber(src) == 0 then
    return true
  end

  local ace = (((Config or {}).Economy or {}).StaffAce) or 'group.mz_owner'
  return isAceAllowed(src, ace)
end

local function reply(source, message)
  message = tostring(message or '')
  if tonumber(source) == 0 then
    print(('[mz_economy] %s'):format(message))
    return
  end

  TriggerClientEvent('chat:addMessage', source, {
    color = { 80, 220, 140 },
    args = { 'mz_economy', message }
  })
end

local function numberValue(value)
  return tonumber(value) or 0
end

local function dateArg(args, index)
  args = type(args) == 'table' and args or {}
  return trim(args[index or 1])
end

local function isTopMode(value)
  value = trim(value):lower()
  return value == 'income' or value == 'expense' or value == 'unknown'
end

local function parseTopArgs(args)
  args = type(args) == 'table' and args or {}

  local first = trim(args[1])
  local second = trim(args[2])
  local third = trim(args[3])

  if isTopMode(first) then
    return '', first, second
  end

  return first, second, third
end

local function ensureAllowed(source)
  if canUseEconomyCommand(source) then
    return true
  end

  reply(source, 'Sem permissao.')
  return false
end

local function replyTransactionRow(source, row)
  reply(source, ('id=%s citizenid=%s account=%s amount=%s dir=%s cat=%s income=%s expense=%s src=%s reason=%s created=%s'):format(
    tostring(row.id or ''),
    tostring(row.citizenid or 'NULL'),
    tostring(row.account or ''),
    tostring(row.amount or 0),
    tostring(row.direction or ''),
    tostring(row.category or 'unknown'),
    tostring(row.counts_as_income or 0),
    tostring(row.counts_as_expense or 0),
    tostring(row.source_resource or 'unknown'),
    tostring(row.reason or ''),
    tostring(row.created_at or '')
  ))
end

local function sectionHasRows(rows)
  return type(rows) == 'table' and #rows > 0
end

RegisterCommand('mzecon_report', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, summary = MZEconomyService.GetDailySummary(dateArg(args, 1))
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(summary or 'unknown')))
  end

  reply(source, ('Relatorio economia: data=%s transacoes=%d'):format(
    tostring(summary.date),
    numberValue(summary.totalTransactions)
  ))
  reply(source, ('Totais: in=%d out=%d transfer=%d adjustment=%d'):format(
    numberValue(summary.directionInAmount),
    numberValue(summary.directionOutAmount),
    numberValue(summary.transferAmount),
    numberValue(summary.adjustmentAmount)
  ))
  reply(source, ('Flags: income=%d (%d tx) expense=%d (%d tx) unknown=%d'):format(
    numberValue(summary.incomeAmount),
    numberValue(summary.incomeCount),
    numberValue(summary.expenseAmount),
    numberValue(summary.expenseCount),
    numberValue(summary.unknownCount)
  ))

  local categoryLines = {}
  for _, row in ipairs(summary.topCategories or {}) do
    categoryLines[#categoryLines + 1] = ('%s:%d/%d'):format(
      tostring(row.category or 'unknown'),
      numberValue(row.total),
      numberValue(row.amount)
    )
  end
  reply(source, ('Top categorias: %s'):format(#categoryLines > 0 and table.concat(categoryLines, ' | ') or 'nenhuma'))

  local sourceLines = {}
  for _, row in ipairs(summary.topSources or {}) do
    sourceLines[#sourceLines + 1] = ('%s:%d/%d'):format(
      tostring(row.source_resource or 'unknown'),
      numberValue(row.total),
      numberValue(row.amount)
    )
  end
  reply(source, ('Top fontes: %s'):format(#sourceLines > 0 and table.concat(sourceLines, ' | ') or 'nenhuma'))
end, false)

RegisterCommand('mzecon_health', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, report = MZEconomyService.GetHealthReport(dateArg(args, 1))
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(report or 'unknown')))
  end

  reply(source, ('Health: data=%s status=%s tx=%d unknown=%d (%.2f%%) unknown_total=%d'):format(
    tostring(report.date),
    tostring(report.status),
    numberValue(report.totalTransactions),
    numberValue(report.unknownCount),
    numberValue(report.unknownPercent),
    numberValue(report.unknownTotal)
  ))
  reply(source, ('Totais: in=%d out=%d income_flag=%d expense_flag=%d transfer=%d adjustment=%d stats_players=%d'):format(
    numberValue(report.totalAmountIn),
    numberValue(report.totalAmountOut),
    numberValue(report.totalIncomeFlag),
    numberValue(report.totalExpenseFlag),
    numberValue(report.transferTotal),
    numberValue(report.adjustmentTotal),
    numberValue(report.playersWithStats)
  ))
  reply(source, ('Top: source=%s tx=%d amount=%d | category=%s tx=%d amount=%d'):format(
    tostring((report.topSource or {}).source_resource or 'nenhuma'),
    numberValue((report.topSource or {}).total_transactions),
    numberValue((report.topSource or {}).amount),
    tostring((report.topCategory or {}).category or 'nenhuma'),
    numberValue((report.topCategory or {}).total_transactions),
    numberValue((report.topCategory or {}).amount)
  ))
end, false)

RegisterCommand('mzecon_unknown', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, result = MZEconomyService.GetUnknownTransactions(dateArg(args, 1), args and args[2])
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Unknown transactions: data=%s limit=%d'):format(tostring(result.date), numberValue(result.limit)))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma transacao unknown encontrada.')
  end

  for _, row in ipairs(rows) do
    reply(source, ('id=%s citizenid=%s account=%s amount=%s direction=%s source=%s reason=%s created=%s'):format(
      tostring(row.id or ''),
      tostring(row.citizenid or 'NULL'),
      tostring(row.account or ''),
      tostring(row.amount or 0),
      tostring(row.direction or ''),
      tostring(row.source_resource or 'unknown'),
      tostring(row.reason or ''),
      tostring(row.created_at or '')
    ))
  end
end, false)

RegisterCommand('mzecon_unknown_sources', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local ok, result = MZEconomyService.GetUnknownSources(dateArg(args, 1), args[2])
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Unknown sources: data=%s limit=%d'):format(tostring(result.date), numberValue(result.limit)))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma transacao unknown encontrada no periodo.')
  end

  for _, row in ipairs(rows) do
    reply(source, ('source=%s tx=%d total=%d first=%s last=%s accounts=%s directions=%s reasons=%s'):format(
      tostring(row.source_resource or 'unknown_resource'),
      numberValue(row.tx_count),
      numberValue(row.total_amount),
      tostring(row.first_seen or ''),
      tostring(row.last_seen or ''),
      tostring(row.accounts or ''),
      tostring(row.directions or ''),
      tostring(row.reasons or '')
    ))
  end
end, false)

RegisterCommand('mzecon_sources', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, result = MZEconomyService.GetSourceSummary(dateArg(args, 1))
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Fontes economia: data=%s'):format(tostring(result.date)))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma fonte encontrada.')
  end

  for _, row in ipairs(rows) do
    reply(source, ('source=%s tx=%d in=%d out=%d unknown=%d'):format(
      tostring(row.source_resource or 'unknown'),
      numberValue(row.total_transactions),
      numberValue(row.direction_in_amount),
      numberValue(row.direction_out_amount),
      numberValue(row.unknown_count)
    ))
  end
end, false)

RegisterCommand('mzecon_category_report', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local ok, result = MZEconomyService.GetCategoryReport(dateArg(args, 1), args[2])
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Category report: data=%s limit=%d'):format(tostring(result.date), numberValue(result.limit)))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma categoria encontrada no periodo.')
  end

  for _, row in ipairs(rows) do
    reply(source, ('category=%s dir=%s tx=%d total=%d income_flags=%d expense_flags=%d top_source=%s'):format(
      tostring(row.category or 'unknown'),
      tostring(row.direction or 'unknown'),
      numberValue(row.tx_count),
      numberValue(row.total_amount),
      numberValue(row.income_flag_count),
      numberValue(row.expense_flag_count),
      tostring(row.top_source_resource or 'unknown_resource')
    ))
  end
end, false)

RegisterCommand('mzecon_rebuild_day', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, summary = MZEconomyService.RebuildDailyStats(dateArg(args, 1))
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(summary or 'unknown')))
  end

  reply(source, ('Daily stats recalculado para %s. Players=%d tx=%d income=%d expense=%d rows=%d'):format(
    tostring(summary.date),
    numberValue(summary.players),
    numberValue(summary.transactionCount),
    numberValue(summary.incomeTotal),
    numberValue(summary.expenseTotal),
    numberValue(summary.rebuiltRows)
  ))
end, false)

RegisterCommand('mzecon_daily', function(source, args)
  if not ensureAllowed(source) then return end

  local ok, summary = MZEconomyService.GetDailyStatsSummary(dateArg(args, 1))
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(summary or 'unknown')))
  end

  if numberValue(summary.players) <= 0 then
    reply(source, ('Daily stats: data=%s sem dados calculados. Rode /mzecon_rebuild_day %s'):format(
      tostring(summary.date),
      tostring(summary.date)
    ))
    return
  end

  reply(source, ('Daily stats: data=%s players=%d playtime=%dmin tx=%d'):format(
    tostring(summary.date),
    numberValue(summary.players),
    numberValue(summary.playtimeMinutes),
    numberValue(summary.transactionCount)
  ))
  reply(source, ('Totais: income=%d expense=%d transfer=%d adjustment=%d unknown=%d/%d'):format(
    numberValue(summary.incomeTotal),
    numberValue(summary.expenseTotal),
    numberValue(summary.transferTotal),
    numberValue(summary.adjustmentTotal),
    numberValue(summary.unknownTotal),
    numberValue(summary.unknownCount)
  ))
  reply(source, ('Por hora media (%dmin+): income=%.2f expense=%.2f'):format(
    numberValue(summary.minMinutesOnlineToCount),
    numberValue(summary.avgIncomePerHour),
    numberValue(summary.avgExpensePerHour)
  ))
  reply(source, ('Income: legal=%d illegal=%d salary=%d business=%d reward=%d'):format(
    numberValue(summary.legalIncome),
    numberValue(summary.illegalIncome),
    numberValue(summary.salaryIncome),
    numberValue(summary.businessIncome),
    numberValue(summary.rewardIncome)
  ))
  reply(source, ('Expenses: vehicle=%d cosmetic=%d shop=%d salary=%d'):format(
    numberValue(summary.vehicleExpense),
    numberValue(summary.cosmeticExpense),
    numberValue(summary.shopExpense),
    numberValue(summary.salaryExpense)
  ))

  local lines = {}
  for _, row in ipairs(summary.topIncomePerHour or {}) do
    lines[#lines + 1] = ('%s:%s/h income=%s play=%smin'):format(
      tostring(row.citizenid or ''),
      tostring(row.income_per_hour or 0),
      tostring(row.income_total or 0),
      tostring(row.playtime_minutes or 0)
    )
  end
  reply(source, ('Top income/h: %s'):format(#lines > 0 and table.concat(lines, ' | ') or 'nenhum'))
end, false)

RegisterCommand('mzecon_player', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local target = trim(args[1])
  local date = trim(args[2])

  if target == '' and tonumber(source) and tonumber(source) > 0 then
    target = tostring(source)
    date = trim(args[1])
  end

  if target == '' then
    return reply(source, 'Uso: /mzecon_player [source|citizenid] [YYYY-MM-DD]')
  end

  local ok, row = MZEconomyService.GetDailyPlayerStats(target, date)
  if not ok then
    if row == 'daily_stats_not_found' then
      return reply(source, ('Sem stats para target=%s. Rode /mzecon_rebuild_day %s'):format(
        tostring(target),
        tostring(date ~= '' and date or 'hoje')
      ))
    end

    return reply(source, ('Erro: %s'):format(tostring(row or 'unknown')))
  end

  reply(source, ('Player daily: data=%s citizenid=%s nome=%s playtime=%dmin tx=%d'):format(
    tostring(row.date),
    tostring(row.citizenid or ''),
    tostring(row.player_name or ''),
    numberValue(row.playtime_minutes),
    numberValue(row.transaction_count)
  ))
  reply(source, ('Totais: income=%d expense=%d income/h=%.2f expense/h=%.2f unknown=%d/%d'):format(
    numberValue(row.income_total),
    numberValue(row.expense_total),
    numberValue(row.income_per_hour),
    numberValue(row.expense_per_hour),
    numberValue(row.unknown_total),
    numberValue(row.unknown_count)
  ))
  reply(source, ('Income: legal=%d illegal=%d salary=%d business=%d reward=%d'):format(
    numberValue(row.legal_income),
    numberValue(row.illegal_income),
    numberValue(row.salary_income),
    numberValue(row.business_income),
    numberValue(row.reward_income)
  ))
  reply(source, ('Expenses: vehicle=%d cosmetic=%d shop=%d salary=%d'):format(
    numberValue(row.vehicle_expense),
    numberValue(row.cosmetic_expense),
    numberValue(row.shop_expense),
    numberValue(row.salary_expense)
  ))
end, false)

RegisterCommand('mzecon_top', function(source, args)
  if not ensureAllowed(source) then return end

  local date, mode, limit = parseTopArgs(args)
  local ok, result = MZEconomyService.GetDailyTop(date, mode, limit)
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Top economia: data=%s mode=%s limit=%d'):format(
    tostring(result.date),
    tostring(result.mode),
    numberValue(result.limit)
  ))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, ('Sem stats calculados. Rode /mzecon_rebuild_day %s'):format(tostring(result.date)))
  end

  for index, row in ipairs(rows) do
    reply(source, ('#%d citizenid=%s nome=%s income=%d expense=%d income/h=%.2f expense/h=%.2f unknown=%d/%d'):format(
      index,
      tostring(row.citizenid or ''),
      tostring(row.player_name or ''),
      numberValue(row.income_total),
      numberValue(row.expense_total),
      numberValue(row.income_per_hour),
      numberValue(row.expense_per_hour),
      numberValue(row.unknown_total),
      numberValue(row.unknown_count)
    ))
  end
end, false)

RegisterCommand('mzecon_suspicious', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local ok, result = MZEconomyService.GetSuspiciousReport(dateArg(args, 1), args[2])
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Suspicious report: data=%s limit=%d large_amount=%d income/h>=%.2fx media'):format(
    tostring(result.date),
    numberValue(result.limit),
    numberValue(result.largeTransactionAmount),
    numberValue(result.suspiciousIncomeMultiplier)
  ))

  local found = false

  if sectionHasRows(result.largeTransactions) then
    found = true
    reply(source, 'Transacoes grandes:')
    for _, row in ipairs(result.largeTransactions) do
      replyTransactionRow(source, row)
    end
  end

  if sectionHasRows(result.highUnknownPlayers) then
    found = true
    reply(source, 'Players com maior unknown:')
    for _, row in ipairs(result.highUnknownPlayers) do
      reply(source, ('citizenid=%s unknown=%d total=%d first=%s last=%s'):format(
        tostring(row.citizenid or ''),
        numberValue(row.unknown_count),
        numberValue(row.unknown_total),
        tostring(row.first_seen or ''),
        tostring(row.last_seen or '')
      ))
    end
  end

  if sectionHasRows(result.highAdjustmentPlayers) then
    found = true
    reply(source, 'Players com maior adjustment:')
    for _, row in ipairs(result.highAdjustmentPlayers) do
      reply(source, ('citizenid=%s adjustments=%d total=%d first=%s last=%s'):format(
        tostring(row.citizenid or ''),
        numberValue(row.adjustment_count),
        numberValue(row.adjustment_total),
        tostring(row.first_seen or ''),
        tostring(row.last_seen or '')
      ))
    end
  end

  if sectionHasRows(result.highIncomePerHour) then
    found = true
    reply(source, 'Players com income/h acima do multiplicador:')
    for _, row in ipairs(result.highIncomePerHour) do
      reply(source, ('citizenid=%s nome=%s playtime=%dmin income=%d income/h=%.2f avg=%.2f'):format(
        tostring(row.citizenid or ''),
        tostring(row.player_name or ''),
        numberValue(row.playtime_minutes),
        numberValue(row.income_total),
        numberValue(row.income_per_hour),
        numberValue(row.avg_income_per_hour)
      ))
    end
  elseif result.dailyStatsAvailable ~= true then
    reply(source, 'Daily stats indisponivel para income/h. Rode /mzecon_rebuild_day antes desse recorte.')
  end

  if sectionHasRows(result.badIncomeCategories) then
    found = true
    reply(source, 'Categorias suspeitas marcadas como income:')
    for _, row in ipairs(result.badIncomeCategories) do
      replyTransactionRow(source, row)
    end
  end

  if sectionHasRows(result.unknownSourceTransactions) then
    found = true
    reply(source, 'Transacoes com source unknown:')
    for _, row in ipairs(result.unknownSourceTransactions) do
      replyTransactionRow(source, row)
    end
  end

  if not found then
    reply(source, 'Nenhuma anomalia simples encontrada.')
  end
end, false)

RegisterCommand('mzecon_player_tx', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local target = trim(args[1])
  local date = trim(args[2])
  local limit = args[3]

  if target == '' and tonumber(source) and tonumber(source) > 0 then
    target = tostring(source)
    date = trim(args[1])
    limit = args[2]
  end

  if target == '' then
    return reply(source, 'Uso: /mzecon_player_tx [source|citizenid] [YYYY-MM-DD] [limit]')
  end

  local ok, result = MZEconomyService.GetPlayerTransactions(target, date, limit)
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Player transactions: data=%s citizenid=%s limit=%d'):format(
    tostring(result.date),
    tostring(result.citizenid or ''),
    numberValue(result.limit)
  ))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma transacao encontrada para o player no periodo.')
  end

  for _, row in ipairs(rows) do
    replyTransactionRow(source, row)
  end
end, false)

RegisterCommand('mzecon_source_tx', function(source, args)
  if not ensureAllowed(source) then return end

  args = type(args) == 'table' and args or {}
  local sourceResource = trim(args[1])
  if sourceResource == '' then
    return reply(source, 'Uso: /mzecon_source_tx [source_resource] [YYYY-MM-DD] [limit]')
  end

  local ok, result = MZEconomyService.GetSourceTransactions(sourceResource, args[2], args[3])
  if not ok then
    return reply(source, ('Erro: %s'):format(tostring(result or 'unknown')))
  end

  reply(source, ('Source transactions: data=%s source=%s limit=%d'):format(
    tostring(result.date),
    tostring(result.sourceResource),
    numberValue(result.limit)
  ))

  local rows = result.rows or {}
  if #rows == 0 then
    return reply(source, 'Nenhuma transacao encontrada para a fonte no periodo.')
  end

  for _, row in ipairs(rows) do
    replyTransactionRow(source, row)
  end
end, false)

RegisterCommand('mzecon_test', function(source)
  if not ensureAllowed(source) then return end

  if ((Config or {}).Economy or {}).Debug ~= true then
    return reply(source, 'Comando disponivel apenas com Config.Economy.Debug = true.')
  end

  local result = MZEconomyService.RecordTransaction({
    source = tonumber(source) and tonumber(source) > 0 and tonumber(source) or nil,
    account = 'wallet',
    amount = 123,
    direction = 'adjustment',
    category = 'admin_adjustment',
    reason = 'mzecon_test',
    source_resource = 'mz_economy',
    source_type = 'manual_test',
    counts_as_income = false,
    counts_as_expense = false,
    metadata = {
      command = 'mzecon_test'
    }
  })

  if not result or result.ok ~= true then
    return reply(source, ('Erro: %s'):format(tostring(result and result.error or 'unknown')))
  end

  reply(source, ('Transacao teste registrada: id=%s tx=%s'):format(
    tostring(result.id or ''),
    tostring(result.transaction_id or '')
  ))
end, false)
