MZEconomyPrepare = MZEconomyPrepare or {}
MZEconomyState = MZEconomyState or {
  prepareDone = false,
  prepareOk = false,
  prepareError = nil,
  ready = false
}
MZEconomyState.financialOutbox = {
  schemaVersion = 1,
  schemaReady = false,
  enabled = Config
    and Config.Economy
    and Config.Economy.FinancialOutbox
    and Config.Economy.FinancialOutbox.Enabled == true
    or false,
  consumerEnabled = Config
    and Config.Economy
    and Config.Economy.FinancialOutbox
    and Config.Economy.FinancialOutbox.Enabled == true
    and Config.Economy.FinancialOutbox.ConsumerEnabled == true
    or false
}

local MYSQL_READY_TIMEOUT_MS = 15000

local function debugLog(message)
  if Config and Config.Economy and Config.Economy.Debug == true then
    print(('[mz_economy][prepare] %s'):format(tostring(message)))
  end
end

local function isMySQLReady()
  return MySQL
    and type(MySQL.query) == 'table'
    and type(MySQL.query.await) == 'function'
    and type(MySQL.single) == 'table'
    and type(MySQL.single.await) == 'function'
    and type(MySQL.insert) == 'table'
    and type(MySQL.insert.await) == 'function'
end

local function waitForMySQLReady()
  local startedAt = GetGameTimer()

  while not isMySQLReady() do
    if GetGameTimer() - startedAt >= MYSQL_READY_TIMEOUT_MS then
      return false, 'mysql_not_ready'
    end

    Wait(250)
  end

  return true
end

local statements = {
  [[CREATE TABLE IF NOT EXISTS mz_economy_transactions (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(64) NULL,
    citizenid VARCHAR(64) NULL,
    license VARCHAR(128) NULL,
    account VARCHAR(32) NOT NULL,
    amount BIGINT NOT NULL,
    balance_before BIGINT NULL,
    balance_after BIGINT NULL,
    direction VARCHAR(32) NOT NULL,
    category VARCHAR(64) NOT NULL,
    reason VARCHAR(128) NULL,
    source_resource VARCHAR(100) NULL,
    source_type VARCHAR(64) NULL,
    counts_as_income TINYINT(1) NOT NULL DEFAULT 0,
    counts_as_expense TINYINT(1) NOT NULL DEFAULT 0,
    related_citizenid VARCHAR(64) NULL,
    related_org_code VARCHAR(64) NULL,
    external_ref VARCHAR(128) NULL,
    metadata_json LONGTEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_economy_transactions_txid (transaction_id),
    KEY idx_mz_econ_tx_citizen_date (citizenid, created_at),
    KEY idx_mz_econ_tx_category_date (category, created_at),
    KEY idx_mz_econ_tx_source_date (source_resource, created_at),
    KEY idx_mz_econ_tx_income_date (counts_as_income, created_at),
    KEY idx_mz_econ_tx_expense_date (counts_as_expense, created_at),
    KEY idx_mz_econ_tx_org_date (related_org_code, created_at),
    KEY idx_mz_econ_tx_created_at (created_at)
  )]],

  [[CREATE TABLE IF NOT EXISTS mz_economy_daily_player_stats (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    stat_date DATE NOT NULL,
    citizenid VARCHAR(64) NOT NULL,
    license VARCHAR(128) NULL,
    player_name VARCHAR(128) NULL,
    playtime_minutes INT NOT NULL DEFAULT 0,
    income_total BIGINT NOT NULL DEFAULT 0,
    expense_total BIGINT NOT NULL DEFAULT 0,
    transfer_total BIGINT NOT NULL DEFAULT 0,
    adjustment_total BIGINT NOT NULL DEFAULT 0,
    income_per_hour DECIMAL(18,2) NOT NULL DEFAULT 0,
    expense_per_hour DECIMAL(18,2) NOT NULL DEFAULT 0,
    legal_income BIGINT NOT NULL DEFAULT 0,
    illegal_income BIGINT NOT NULL DEFAULT 0,
    salary_income BIGINT NOT NULL DEFAULT 0,
    business_income BIGINT NOT NULL DEFAULT 0,
    reward_income BIGINT NOT NULL DEFAULT 0,
    vehicle_expense BIGINT NOT NULL DEFAULT 0,
    cosmetic_expense BIGINT NOT NULL DEFAULT 0,
    shop_expense BIGINT NOT NULL DEFAULT 0,
    salary_expense BIGINT NOT NULL DEFAULT 0,
    unknown_total BIGINT NOT NULL DEFAULT 0,
    transaction_count INT NOT NULL DEFAULT 0,
    unknown_count INT NOT NULL DEFAULT 0,
    metadata_json LONGTEXT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_econ_daily_player (stat_date, citizenid),
    KEY idx_mz_econ_daily_date (stat_date),
    KEY idx_mz_econ_daily_citizen (citizenid),
    KEY idx_mz_econ_daily_income_hour (income_per_hour)
  )]],

  [[CREATE TABLE IF NOT EXISTS mz_economy_outbox_receipts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    outbox_id BIGINT UNSIGNED NOT NULL,
    correlation_id VARCHAR(128) NOT NULL,
    payload_version SMALLINT UNSIGNED NOT NULL,
    entry_count SMALLINT UNSIGNED NOT NULL,
    processed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    metadata_json LONGTEXT NULL,
    UNIQUE KEY uq_mz_economy_outbox_receipt_outbox (outbox_id),
    UNIQUE KEY uq_mz_economy_outbox_receipt_correlation (correlation_id),
    KEY idx_mz_economy_outbox_receipt_processed (processed_at)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]
}

local function validateTableStructure(tableName, requiredColumns, requiredIndexes)
  local tableRow = MySQL.single.await([[
    SELECT ENGINE AS engine, TABLE_COLLATION AS table_collation
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = ?
    LIMIT 1
  ]], { tableName })

  if not tableRow then return false, ('schema_invalid:%s:table_missing'):format(tableName) end
  if tostring(tableRow.engine or ''):lower() ~= 'innodb' then
    return false, ('schema_invalid:%s:engine:%s'):format(tableName, tostring(tableRow.engine))
  end
  if not tostring(tableRow.table_collation or ''):lower():find('^utf8mb4_') then
    return false, ('schema_invalid:%s:charset:%s'):format(tableName, tostring(tableRow.table_collation))
  end

  local columnRows = MySQL.query.await([[
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = ?
  ]], { tableName }) or {}
  local columns = {}
  for _, row in ipairs(columnRows) do
    columns[tostring(row.column_name or ''):lower()] = true
  end
  for _, columnName in ipairs(requiredColumns or {}) do
    if columns[tostring(columnName):lower()] ~= true then
      return false, ('schema_invalid:%s:column:%s'):format(tableName, tostring(columnName))
    end
  end

  local indexRows = MySQL.query.await([[
    SELECT DISTINCT index_name
    FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = ?
  ]], { tableName }) or {}
  local indexes = {}
  for _, row in ipairs(indexRows) do
    indexes[tostring(row.index_name or ''):lower()] = true
  end
  for _, indexName in ipairs(requiredIndexes or {}) do
    if indexes[tostring(indexName):lower()] ~= true then
      return false, ('schema_invalid:%s:index:%s'):format(tableName, tostring(indexName))
    end
  end

  return true
end

function MZEconomyPrepare.ensureTables()
  local ready, readyErr = waitForMySQLReady()
  if not ready then
    return false, readyErr
  end

  for _, statement in ipairs(statements) do
    MySQL.query.await(statement)
  end

  local schemaOk, schemaErr = validateTableStructure('mz_economy_outbox_receipts', {
    'id', 'outbox_id', 'correlation_id', 'payload_version', 'entry_count',
    'processed_at', 'metadata_json'
  }, {
    'PRIMARY', 'uq_mz_economy_outbox_receipt_outbox',
    'uq_mz_economy_outbox_receipt_correlation',
    'idx_mz_economy_outbox_receipt_processed'
  })
  if not schemaOk then return false, schemaErr end

  MZEconomyState.financialOutbox.schemaVersion = tonumber(
    Config
      and Config.Economy
      and Config.Economy.FinancialOutbox
      and Config.Economy.FinancialOutbox.SchemaVersion
  ) or 1
  MZEconomyState.financialOutbox.schemaReady = true
  MZEconomyState.financialOutbox.enabled = Config
    and Config.Economy
    and Config.Economy.FinancialOutbox
    and Config.Economy.FinancialOutbox.Enabled == true
    or false
  MZEconomyState.financialOutbox.consumerEnabled = MZEconomyState.financialOutbox.enabled == true
    and Config.Economy.FinancialOutbox.ConsumerEnabled == true
    or false
  print(('[mz_economy][outbox] receipt schema ready version=%s enabled=%s consumer=%s'):format(
    tostring(MZEconomyState.financialOutbox.schemaVersion),
    tostring(MZEconomyState.financialOutbox.enabled),
    tostring(MZEconomyState.financialOutbox.consumerEnabled)
  ))

  return true
end

function MZEconomyPrepare.run()
  local ok, result, resultErr = pcall(MZEconomyPrepare.ensureTables)
  if not ok then
    MZEconomyState.prepareDone = true
    MZEconomyState.prepareOk = false
    MZEconomyState.ready = false
    MZEconomyState.prepareError = tostring(result)
    print(('[mz_economy][prepare] failed: %s'):format(tostring(result)))
    return false, tostring(result)
  end

  if result ~= true then
    MZEconomyState.prepareDone = true
    MZEconomyState.prepareOk = false
    MZEconomyState.ready = false
    MZEconomyState.prepareError = tostring(resultErr or result)
    print(('[mz_economy][prepare] failed: %s'):format(tostring(resultErr or result)))
    return false, tostring(resultErr or result)
  end

  MZEconomyState.prepareDone = true
  MZEconomyState.prepareOk = true
  MZEconomyState.ready = true
  MZEconomyState.prepareError = nil
  debugLog('tables ready')
  return true
end
