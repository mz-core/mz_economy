MZEconomyRepository = MZEconomyRepository or {}

local function dayRange(date)
  return tostring(date), tostring(date)
end

local function numberValue(value)
  return tonumber(value) or 0
end

local function intValue(value)
  return math.floor(tonumber(value) or 0)
end

local function encodeJson(value)
  local ok, encoded = pcall(function()
    return json.encode(value or {})
  end)

  if ok and encoded then return encoded end
  return '{}'
end

local PLAYTIME_AGGREGATE_SQL = [[
  SELECT citizenid, COALESCE(SUM(session_minutes), 0) AS playtime_minutes
  FROM (
    SELECT
      citizenid,
      CASE
        WHEN session_end <= session_start THEN 0
        WHEN TIMESTAMPDIFF(SECOND, session_start, session_end) < 60 THEN 0
        ELSE FLOOR(TIMESTAMPDIFF(SECOND, session_start, session_end) / 60)
      END AS session_minutes
    FROM (
      SELECT
        citizenid,
        GREATEST(joined_at, ?) AS session_start,
        LEAST(
          CASE
            WHEN is_active = 1 AND ? = 1 THEN NOW()
            ELSE COALESCE(dropped_at, last_seen_at, joined_at)
          END,
          DATE_ADD(?, INTERVAL 1 DAY)
        ) AS session_end
      FROM mz_player_sessions
      WHERE citizenid IS NOT NULL
        AND citizenid <> ''
        AND joined_at < DATE_ADD(?, INTERVAL 1 DAY)
        AND (
          CASE
            WHEN is_active = 1 AND ? = 1 THEN NOW()
            ELSE COALESCE(dropped_at, last_seen_at, joined_at)
          END
        ) > ?
    ) bounded_sessions
  ) calculated_sessions
  GROUP BY citizenid
]]

local TRANSACTION_AGGREGATE_SQL = [[
  SELECT
    citizenid,
    MAX(license) AS license,
    COALESCE(SUM(CASE WHEN counts_as_income = 1 THEN amount ELSE 0 END), 0) AS income_total,
    COALESCE(SUM(CASE WHEN counts_as_expense = 1 THEN amount ELSE 0 END), 0) AS expense_total,
    COALESCE(SUM(CASE WHEN direction = 'transfer' OR category = 'org_transfer' THEN amount ELSE 0 END), 0) AS transfer_total,
    COALESCE(SUM(CASE WHEN category IN ('admin_adjustment', 'admin_org_adjustment', 'system_bootstrap') THEN amount ELSE 0 END), 0) AS adjustment_total,
    COALESCE(SUM(CASE WHEN category IN ('legal_job', 'sale_to_npc', 'mission') THEN amount ELSE 0 END), 0) AS legal_income,
    COALESCE(SUM(CASE WHEN category IN ('illegal_job', 'illegal_sale', 'heist') THEN amount ELSE 0 END), 0) AS illegal_income,
    COALESCE(SUM(CASE WHEN category = 'salary' THEN amount ELSE 0 END), 0) AS salary_income,
    COALESCE(SUM(CASE WHEN category = 'business_revenue' THEN amount ELSE 0 END), 0) AS business_income,
    COALESCE(SUM(CASE WHEN category IN ('reward', 'event_reward') THEN amount ELSE 0 END), 0) AS reward_income,
    COALESCE(SUM(CASE WHEN category = 'vehicle_expense' THEN amount ELSE 0 END), 0) AS vehicle_expense,
    COALESCE(SUM(CASE WHEN category = 'cosmetic_expense' THEN amount ELSE 0 END), 0) AS cosmetic_expense,
    COALESCE(SUM(CASE WHEN category = 'shop_expense' THEN amount ELSE 0 END), 0) AS shop_expense,
    COALESCE(SUM(CASE WHEN category = 'salary_expense' THEN amount ELSE 0 END), 0) AS salary_expense,
    COALESCE(SUM(CASE WHEN category = 'unknown' OR category IS NULL OR category = '' THEN amount ELSE 0 END), 0) AS unknown_total,
    COUNT(*) AS transaction_count,
    COALESCE(SUM(CASE WHEN category = 'unknown' OR category IS NULL OR category = '' THEN 1 ELSE 0 END), 0) AS unknown_count
  FROM mz_economy_transactions
  WHERE citizenid IS NOT NULL
    AND citizenid <> ''
    AND created_at >= ?
    AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
  GROUP BY citizenid
]]

local function appendPlaytimeParams(params, date, includeOpenSessions)
  params[#params + 1] = date
  params[#params + 1] = includeOpenSessions
  params[#params + 1] = date
  params[#params + 1] = date
  params[#params + 1] = includeOpenSessions
  params[#params + 1] = date
end

function MZEconomyRepository.ensureTables()
  if not MZEconomyPrepare or type(MZEconomyPrepare.ensureTables) ~= 'function' then
    return false, 'prepare_unavailable'
  end

  return MZEconomyPrepare.ensureTables()
end

function MZEconomyRepository.insertTransaction(payload)
  payload = type(payload) == 'table' and payload or {}

  local insertId = MySQL.insert.await([[
    INSERT INTO mz_economy_transactions (
      transaction_id, citizenid, license, account, amount, balance_before, balance_after,
      direction, category, reason, source_resource, source_type, counts_as_income,
      counts_as_expense, related_citizenid, related_org_code, external_ref, metadata_json
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ]], {
    payload.transaction_id,
    payload.citizenid,
    payload.license,
    payload.account,
    payload.amount,
    payload.balance_before,
    payload.balance_after,
    payload.direction,
    payload.category,
    payload.reason,
    payload.source_resource,
    payload.source_type,
    payload.counts_as_income,
    payload.counts_as_expense,
    payload.related_citizenid,
    payload.related_org_code,
    payload.external_ref,
    payload.metadata_json
  })

  return tonumber(insertId) or insertId
end

function MZEconomyRepository.getDailySummary(date)
  local startDate, endDate = dayRange(date)

  local totals = MySQL.single.await([[
    SELECT
      COUNT(*) AS total_transactions,
      COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS direction_in_amount,
      COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS direction_out_amount,
      COALESCE(SUM(CASE WHEN direction = 'transfer' THEN amount ELSE 0 END), 0) AS transfer_amount,
      COALESCE(SUM(CASE WHEN direction = 'adjustment' THEN amount ELSE 0 END), 0) AS adjustment_amount,
      COALESCE(SUM(CASE WHEN counts_as_income = 1 THEN amount ELSE 0 END), 0) AS income_amount,
      COALESCE(SUM(CASE WHEN counts_as_expense = 1 THEN amount ELSE 0 END), 0) AS expense_amount,
      COALESCE(SUM(CASE WHEN counts_as_income = 1 THEN 1 ELSE 0 END), 0) AS income_count,
      COALESCE(SUM(CASE WHEN counts_as_expense = 1 THEN 1 ELSE 0 END), 0) AS expense_count,
      COALESCE(SUM(CASE WHEN category = 'unknown' THEN 1 ELSE 0 END), 0) AS unknown_count
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
  ]], { startDate, endDate }) or {}

  local topCategories = MySQL.query.await([[
    SELECT category, COUNT(*) AS total, COALESCE(SUM(amount), 0) AS amount
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY category
    ORDER BY total DESC, amount DESC
    LIMIT 5
  ]], { startDate, endDate }) or {}

  local topSources = MySQL.query.await([[
    SELECT source_resource, COUNT(*) AS total, COALESCE(SUM(amount), 0) AS amount
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY source_resource
    ORDER BY total DESC, amount DESC
    LIMIT 5
  ]], { startDate, endDate }) or {}

  return {
    date = date,
    totalTransactions = numberValue(totals.total_transactions),
    directionInAmount = numberValue(totals.direction_in_amount),
    directionOutAmount = numberValue(totals.direction_out_amount),
    transferAmount = numberValue(totals.transfer_amount),
    adjustmentAmount = numberValue(totals.adjustment_amount),
    incomeAmount = numberValue(totals.income_amount),
    expenseAmount = numberValue(totals.expense_amount),
    incomeCount = numberValue(totals.income_count),
    expenseCount = numberValue(totals.expense_count),
    unknownCount = numberValue(totals.unknown_count),
    topCategories = topCategories,
    topSources = topSources
  }
end

function MZEconomyRepository.getUnknownTransactions(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, source_resource, reason, created_at
    FROM mz_economy_transactions
    WHERE category = 'unknown'
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY created_at DESC, id DESC
    LIMIT ?
  ]], { startDate, endDate, tonumber(limit) or 25 }) or {}
end

function MZEconomyRepository.getSourceSummary(date)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT
      source_resource,
      COUNT(*) AS total_transactions,
      COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS direction_in_amount,
      COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS direction_out_amount,
      COALESCE(SUM(CASE WHEN category = 'unknown' THEN 1 ELSE 0 END), 0) AS unknown_count
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY source_resource
    ORDER BY total_transactions DESC, source_resource ASC
  ]], { startDate, endDate }) or {}
end

function MZEconomyRepository.getHealthReport(date)
  local startDate, endDate = dayRange(date)

  local totals = MySQL.single.await([[
    SELECT
      COUNT(*) AS total_transactions,
      COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END), 0) AS total_amount_in,
      COALESCE(SUM(CASE WHEN direction = 'out' THEN amount ELSE 0 END), 0) AS total_amount_out,
      COALESCE(SUM(CASE WHEN counts_as_income = 1 THEN amount ELSE 0 END), 0) AS total_income_flag,
      COALESCE(SUM(CASE WHEN counts_as_expense = 1 THEN amount ELSE 0 END), 0) AS total_expense_flag,
      COALESCE(SUM(CASE WHEN direction = 'transfer' OR category = 'org_transfer' THEN amount ELSE 0 END), 0) AS transfer_total,
      COALESCE(SUM(CASE WHEN direction = 'adjustment' OR category IN ('admin_adjustment', 'admin_org_adjustment', 'system_bootstrap') THEN amount ELSE 0 END), 0) AS adjustment_total,
      COALESCE(SUM(CASE WHEN category = 'unknown' OR category IS NULL OR category = '' THEN 1 ELSE 0 END), 0) AS unknown_count,
      COALESCE(SUM(CASE WHEN category = 'unknown' OR category IS NULL OR category = '' THEN amount ELSE 0 END), 0) AS unknown_total
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
  ]], { startDate, endDate }) or {}

  local topSource = MySQL.single.await([[
    SELECT COALESCE(NULLIF(source_resource, ''), 'unknown_resource') AS source_resource,
      COUNT(*) AS total_transactions,
      COALESCE(SUM(amount), 0) AS amount
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY COALESCE(NULLIF(source_resource, ''), 'unknown_resource')
    ORDER BY total_transactions DESC, amount DESC, source_resource ASC
    LIMIT 1
  ]], { startDate, endDate }) or {}

  local topCategory = MySQL.single.await([[
    SELECT COALESCE(NULLIF(category, ''), 'unknown') AS category,
      COUNT(*) AS total_transactions,
      COALESCE(SUM(amount), 0) AS amount
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY COALESCE(NULLIF(category, ''), 'unknown')
    ORDER BY total_transactions DESC, amount DESC, category ASC
    LIMIT 1
  ]], { startDate, endDate }) or {}

  local playersWithStats = 0
  local ok, statsRow = pcall(function()
    return MySQL.single.await([[
      SELECT COUNT(*) AS total
      FROM mz_economy_daily_player_stats
      WHERE stat_date = ?
    ]], { date }) or {}
  end)

  if ok and statsRow then
    playersWithStats = intValue(statsRow.total)
  end

  return {
    date = date,
    totalTransactions = intValue(totals.total_transactions),
    totalAmountIn = intValue(totals.total_amount_in),
    totalAmountOut = intValue(totals.total_amount_out),
    totalIncomeFlag = intValue(totals.total_income_flag),
    totalExpenseFlag = intValue(totals.total_expense_flag),
    transferTotal = intValue(totals.transfer_total),
    adjustmentTotal = intValue(totals.adjustment_total),
    unknownCount = intValue(totals.unknown_count),
    unknownTotal = intValue(totals.unknown_total),
    playersWithStats = playersWithStats,
    topSource = topSource,
    topCategory = topCategory
  }
end

function MZEconomyRepository.getUnknownSources(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT
      COALESCE(NULLIF(source_resource, ''), 'unknown_resource') AS source_resource,
      COUNT(*) AS tx_count,
      COALESCE(SUM(amount), 0) AS total_amount,
      MIN(created_at) AS first_seen,
      MAX(created_at) AS last_seen,
      SUBSTRING(GROUP_CONCAT(DISTINCT COALESCE(NULLIF(account, ''), 'NULL') ORDER BY account SEPARATOR ', '), 1, 160) AS accounts,
      SUBSTRING(GROUP_CONCAT(DISTINCT COALESCE(NULLIF(direction, ''), 'NULL') ORDER BY direction SEPARATOR ', '), 1, 160) AS directions,
      SUBSTRING(GROUP_CONCAT(DISTINCT COALESCE(NULLIF(reason, ''), 'NULL') ORDER BY reason SEPARATOR ', '), 1, 160) AS reasons
    FROM mz_economy_transactions
    WHERE (category = 'unknown' OR category IS NULL OR category = '')
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY COALESCE(NULLIF(source_resource, ''), 'unknown_resource')
    ORDER BY tx_count DESC, total_amount DESC, source_resource ASC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getCategoryReport(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT
      COALESCE(NULLIF(category, ''), 'unknown') AS category,
      COALESCE(NULLIF(direction, ''), 'unknown') AS direction,
      COUNT(*) AS tx_count,
      COALESCE(SUM(amount), 0) AS total_amount,
      COALESCE(SUM(CASE WHEN counts_as_income = 1 THEN 1 ELSE 0 END), 0) AS income_flag_count,
      COALESCE(SUM(CASE WHEN counts_as_expense = 1 THEN 1 ELSE 0 END), 0) AS expense_flag_count,
      SUBSTRING_INDEX(GROUP_CONCAT(COALESCE(NULLIF(source_resource, ''), 'unknown_resource') ORDER BY amount DESC SEPARATOR ','), ',', 1) AS top_source_resource
    FROM mz_economy_transactions
    WHERE created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY COALESCE(NULLIF(category, ''), 'unknown'), COALESCE(NULLIF(direction, ''), 'unknown')
    ORDER BY total_amount DESC, tx_count DESC, category ASC, direction ASC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getSuspiciousLargeTransactions(date, largeAmount, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, category, reason, source_resource, created_at
    FROM mz_economy_transactions
    WHERE amount >= ?
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY amount DESC, created_at DESC, id DESC
    LIMIT ?
  ]], { largeAmount, startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getSuspiciousUnknownPlayers(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT citizenid,
      COUNT(*) AS unknown_count,
      COALESCE(SUM(amount), 0) AS unknown_total,
      MIN(created_at) AS first_seen,
      MAX(created_at) AS last_seen
    FROM mz_economy_transactions
    WHERE citizenid IS NOT NULL
      AND citizenid <> ''
      AND (category = 'unknown' OR category IS NULL OR category = '')
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY citizenid
    ORDER BY unknown_total DESC, unknown_count DESC, citizenid ASC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getSuspiciousAdjustmentPlayers(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT citizenid,
      COUNT(*) AS adjustment_count,
      COALESCE(SUM(amount), 0) AS adjustment_total,
      MIN(created_at) AS first_seen,
      MAX(created_at) AS last_seen
    FROM mz_economy_transactions
    WHERE citizenid IS NOT NULL
      AND citizenid <> ''
      AND (direction = 'adjustment' OR category IN ('admin_adjustment', 'admin_org_adjustment', 'system_bootstrap'))
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    GROUP BY citizenid
    ORDER BY adjustment_total DESC, adjustment_count DESC, citizenid ASC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getSuspiciousIncomePerHour(date, minMinutes, multiplier, limit)
  return MySQL.query.await([[
    SELECT s.citizenid, s.player_name, s.playtime_minutes, s.income_total, s.income_per_hour,
      avg_table.avg_income_per_hour
    FROM mz_economy_daily_player_stats s
    CROSS JOIN (
      SELECT COALESCE(AVG(income_per_hour), 0) AS avg_income_per_hour
      FROM mz_economy_daily_player_stats
      WHERE stat_date = ? AND playtime_minutes >= ?
    ) avg_table
    WHERE s.stat_date = ?
      AND s.playtime_minutes >= ?
      AND avg_table.avg_income_per_hour > 0
      AND s.income_per_hour >= (avg_table.avg_income_per_hour * ?)
    ORDER BY s.income_per_hour DESC, s.income_total DESC, s.citizenid ASC
    LIMIT ?
  ]], { date, minMinutes, date, minMinutes, multiplier, limit }) or {}
end

function MZEconomyRepository.getSuspiciousBadIncomeCategories(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, category, reason, source_resource, created_at
    FROM mz_economy_transactions
    WHERE counts_as_income = 1
      AND category IN ('admin_adjustment', 'admin_org_adjustment', 'org_transfer', 'player_transfer', 'system_bootstrap', 'unknown')
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY amount DESC, created_at DESC, id DESC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getSuspiciousUnknownSourceTransactions(date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, category, reason, source_resource, created_at
    FROM mz_economy_transactions
    WHERE LOWER(COALESCE(NULLIF(source_resource, ''), 'unknown')) IN ('unknown', 'unknown_resource')
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY amount DESC, created_at DESC, id DESC
    LIMIT ?
  ]], { startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getPlayerTransactions(citizenid, date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, category, reason, source_resource,
      counts_as_income, counts_as_expense, created_at
    FROM mz_economy_transactions
    WHERE citizenid = ?
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY created_at DESC, id DESC
    LIMIT ?
  ]], { citizenid, startDate, endDate, limit }) or {}
end

function MZEconomyRepository.getAccountStatement(citizenid, account, limit)
  return MySQL.query.await([[
    SELECT id, transaction_id, account, amount, balance_before, balance_after, direction,
      category, reason, source_resource, source_type, related_citizenid, external_ref, created_at
    FROM mz_economy_transactions
    WHERE citizenid = ? AND account = ?
    ORDER BY created_at DESC, id DESC
    LIMIT ?
  ]], { citizenid, account, limit }) or {}
end

function MZEconomyRepository.getSourceTransactions(sourceResource, date, limit)
  local startDate, endDate = dayRange(date)

  return MySQL.query.await([[
    SELECT id, citizenid, account, amount, direction, category, reason, source_resource,
      counts_as_income, counts_as_expense, created_at
    FROM mz_economy_transactions
    WHERE source_resource = ?
      AND created_at >= ? AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
    ORDER BY created_at DESC, id DESC
    LIMIT ?
  ]], { sourceResource, startDate, endDate, limit }) or {}
end

function MZEconomyRepository.rebuildDailyPlayerStats(date, options)
  options = type(options) == 'table' and options or {}
  local includeOpenSessions = options.includeOpenSessions == true and 1 or 0
  local metadataJson = encodeJson({
    rebuilt_by = 'mz_economy',
    include_open_sessions = includeOpenSessions == 1
  })

  local sql = ([[
    INSERT INTO mz_economy_daily_player_stats (
      stat_date, citizenid, license, player_name, playtime_minutes,
      income_total, expense_total, transfer_total, adjustment_total,
      income_per_hour, expense_per_hour,
      legal_income, illegal_income, salary_income, business_income, reward_income,
      vehicle_expense, cosmetic_expense, shop_expense, salary_expense,
      unknown_total, transaction_count, unknown_count, metadata_json
    )
    SELECT
      ? AS stat_date,
      base.citizenid,
      tx.license AS license,
      NULLIF(TRIM(CONCAT(COALESCE(p.firstname, ''), ' ', COALESCE(p.lastname, ''))), '') AS player_name,
      COALESCE(pt.playtime_minutes, 0) AS playtime_minutes,
      COALESCE(tx.income_total, 0) AS income_total,
      COALESCE(tx.expense_total, 0) AS expense_total,
      COALESCE(tx.transfer_total, 0) AS transfer_total,
      COALESCE(tx.adjustment_total, 0) AS adjustment_total,
      CASE
        WHEN COALESCE(pt.playtime_minutes, 0) > 0 THEN ROUND(COALESCE(tx.income_total, 0) / (COALESCE(pt.playtime_minutes, 0) / 60), 2)
        ELSE 0
      END AS income_per_hour,
      CASE
        WHEN COALESCE(pt.playtime_minutes, 0) > 0 THEN ROUND(COALESCE(tx.expense_total, 0) / (COALESCE(pt.playtime_minutes, 0) / 60), 2)
        ELSE 0
      END AS expense_per_hour,
      COALESCE(tx.legal_income, 0) AS legal_income,
      COALESCE(tx.illegal_income, 0) AS illegal_income,
      COALESCE(tx.salary_income, 0) AS salary_income,
      COALESCE(tx.business_income, 0) AS business_income,
      COALESCE(tx.reward_income, 0) AS reward_income,
      COALESCE(tx.vehicle_expense, 0) AS vehicle_expense,
      COALESCE(tx.cosmetic_expense, 0) AS cosmetic_expense,
      COALESCE(tx.shop_expense, 0) AS shop_expense,
      COALESCE(tx.salary_expense, 0) AS salary_expense,
      COALESCE(tx.unknown_total, 0) AS unknown_total,
      COALESCE(tx.transaction_count, 0) AS transaction_count,
      COALESCE(tx.unknown_count, 0) AS unknown_count,
      ? AS metadata_json
    FROM (
      SELECT citizenid
      FROM mz_economy_transactions
      WHERE citizenid IS NOT NULL
        AND citizenid <> ''
        AND created_at >= ?
        AND created_at < DATE_ADD(?, INTERVAL 1 DAY)
      UNION
      SELECT citizenid
      FROM (%s) pt_base
      WHERE COALESCE(pt_base.playtime_minutes, 0) > 0
    ) base
    LEFT JOIN (%s) tx ON tx.citizenid = base.citizenid
    LEFT JOIN (%s) pt ON pt.citizenid = base.citizenid
    LEFT JOIN mz_players p ON p.citizenid = base.citizenid
  ]]):format(PLAYTIME_AGGREGATE_SQL, TRANSACTION_AGGREGATE_SQL, PLAYTIME_AGGREGATE_SQL)

  local params = { date, metadataJson, date, date }
  appendPlaytimeParams(params, date, includeOpenSessions)
  params[#params + 1] = date
  params[#params + 1] = date
  appendPlaytimeParams(params, date, includeOpenSessions)

  local ok = MySQL.transaction.await({
    {
      query = 'DELETE FROM mz_economy_daily_player_stats WHERE stat_date = ?',
      parameters = { date }
    },
    {
      query = sql,
      parameters = params
    }
  })

  if ok == false then
    return false, 'daily_stats_rebuild_failed'
  end

  local row = MySQL.single.await([[
    SELECT COUNT(*) AS total
    FROM mz_economy_daily_player_stats
    WHERE stat_date = ?
  ]], { date }) or {}

  return intValue(row.total)
end

function MZEconomyRepository.getDailyStatsSummary(date, minMinutes, topLimit)
  minMinutes = intValue(minMinutes)
  topLimit = intValue(topLimit)
  if minMinutes < 0 then minMinutes = 0 end
  if topLimit < 1 then topLimit = 5 end

  local totals = MySQL.single.await([[
    SELECT
      COUNT(*) AS players,
      COALESCE(SUM(playtime_minutes), 0) AS playtime_minutes,
      COALESCE(SUM(income_total), 0) AS income_total,
      COALESCE(SUM(expense_total), 0) AS expense_total,
      COALESCE(SUM(transfer_total), 0) AS transfer_total,
      COALESCE(SUM(adjustment_total), 0) AS adjustment_total,
      COALESCE(AVG(CASE WHEN playtime_minutes >= ? THEN income_per_hour ELSE NULL END), 0) AS avg_income_per_hour,
      COALESCE(AVG(CASE WHEN playtime_minutes >= ? THEN expense_per_hour ELSE NULL END), 0) AS avg_expense_per_hour,
      COALESCE(SUM(legal_income), 0) AS legal_income,
      COALESCE(SUM(illegal_income), 0) AS illegal_income,
      COALESCE(SUM(salary_income), 0) AS salary_income,
      COALESCE(SUM(business_income), 0) AS business_income,
      COALESCE(SUM(reward_income), 0) AS reward_income,
      COALESCE(SUM(vehicle_expense), 0) AS vehicle_expense,
      COALESCE(SUM(cosmetic_expense), 0) AS cosmetic_expense,
      COALESCE(SUM(shop_expense), 0) AS shop_expense,
      COALESCE(SUM(salary_expense), 0) AS salary_expense,
      COALESCE(SUM(unknown_total), 0) AS unknown_total,
      COALESCE(SUM(transaction_count), 0) AS transaction_count,
      COALESCE(SUM(unknown_count), 0) AS unknown_count
    FROM mz_economy_daily_player_stats
    WHERE stat_date = ?
  ]], { minMinutes, minMinutes, date }) or {}

  local topIncome = MySQL.query.await([[
    SELECT citizenid, player_name, playtime_minutes, income_total, income_per_hour, unknown_total
    FROM mz_economy_daily_player_stats
    WHERE stat_date = ?
    ORDER BY income_per_hour DESC, income_total DESC, citizenid ASC
    LIMIT ?
  ]], { date, topLimit }) or {}

  return {
    date = date,
    players = intValue(totals.players),
    playtimeMinutes = intValue(totals.playtime_minutes),
    incomeTotal = intValue(totals.income_total),
    expenseTotal = intValue(totals.expense_total),
    transferTotal = intValue(totals.transfer_total),
    adjustmentTotal = intValue(totals.adjustment_total),
    avgIncomePerHour = numberValue(totals.avg_income_per_hour),
    avgExpensePerHour = numberValue(totals.avg_expense_per_hour),
    legalIncome = intValue(totals.legal_income),
    illegalIncome = intValue(totals.illegal_income),
    salaryIncome = intValue(totals.salary_income),
    businessIncome = intValue(totals.business_income),
    rewardIncome = intValue(totals.reward_income),
    vehicleExpense = intValue(totals.vehicle_expense),
    cosmeticExpense = intValue(totals.cosmetic_expense),
    shopExpense = intValue(totals.shop_expense),
    salaryExpense = intValue(totals.salary_expense),
    unknownTotal = intValue(totals.unknown_total),
    transactionCount = intValue(totals.transaction_count),
    unknownCount = intValue(totals.unknown_count),
    topIncomePerHour = topIncome
  }
end

function MZEconomyRepository.getDailyPlayerStats(date, citizenid)
  return MySQL.single.await([[
    SELECT *
    FROM mz_economy_daily_player_stats
    WHERE stat_date = ? AND citizenid = ?
    LIMIT 1
  ]], { date, citizenid })
end

function MZEconomyRepository.getDailyTop(date, mode, limit)
  local orderBy = 'income_total DESC, income_per_hour DESC'
  if mode == 'expense' then
    orderBy = 'expense_total DESC, expense_per_hour DESC'
  elseif mode == 'unknown' then
    orderBy = 'unknown_total DESC, unknown_count DESC'
  end

  return MySQL.query.await(([[
    SELECT citizenid, player_name, playtime_minutes, income_total, expense_total,
      income_per_hour, expense_per_hour, unknown_total, unknown_count
    FROM mz_economy_daily_player_stats
    WHERE stat_date = ?
    ORDER BY %s, citizenid ASC
    LIMIT ?
  ]]):format(orderBy), { date, limit }) or {}
end
