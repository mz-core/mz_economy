MZEconomyPrepare = MZEconomyPrepare or {}
MZEconomyState = MZEconomyState or {
  prepareDone = false,
  prepareOk = false,
  prepareError = nil,
  ready = false
}

local MYSQL_READY_TIMEOUT_MS = 15000

local statements = {
  [[CREATE TABLE IF NOT EXISTS mz_player_accounts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizenid VARCHAR(64) NOT NULL,
    bank BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_player_accounts_citizenid (citizenid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_money_item_sagas (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    source_resource VARCHAR(100) NOT NULL,
    actor_citizenid VARCHAR(64) NOT NULL,
    operation_key VARCHAR(64) NOT NULL,
    operation VARCHAR(64) NOT NULL,
    request_fingerprint VARCHAR(255) NOT NULL,
    account VARCHAR(32) NOT NULL,
    from_account VARCHAR(32) NULL,
    to_account VARCHAR(32) NULL,
    item_name VARCHAR(64) NOT NULL,
    amount BIGINT UNSIGNED NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'pending',
    bank_before BIGINT NULL,
    bank_after BIGINT NULL,
    inventory_result_json LONGTEXT NULL,
    result_json LONGTEXT NULL,
    error_code VARCHAR(64) NULL,
    correlation_id VARCHAR(128) NOT NULL,
    metadata_json LONGTEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_money_item_saga_scope (source_resource, actor_citizenid, operation_key),
    UNIQUE KEY uq_mz_money_item_saga_correlation (correlation_id),
    KEY idx_mz_money_item_saga_recovery (status, updated_at),
    KEY idx_mz_money_item_saga_actor (actor_citizenid, created_at)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_account_idempotency (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    source_resource VARCHAR(100) NOT NULL,
    actor_citizenid VARCHAR(64) NOT NULL,
    idempotency_key VARCHAR(64) NOT NULL,
    operation VARCHAR(64) NOT NULL,
    request_fingerprint VARCHAR(255) NOT NULL,
    correlation_id VARCHAR(128) NOT NULL,
    result_json LONGTEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_account_idempotency_scope (source_resource, actor_citizenid, idempotency_key),
    UNIQUE KEY uq_mz_account_idempotency_correlation (correlation_id),
    KEY idx_mz_account_idempotency_created_at (created_at)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_org_accounts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    org_id BIGINT UNSIGNED NOT NULL,
    balance BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_org_accounts_org_id (org_id)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_org_account_operations (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    source_resource VARCHAR(100) NOT NULL,
    operation_key VARCHAR(128) NOT NULL,
    operation_type VARCHAR(24) NOT NULL,
    purpose VARCHAR(64) NOT NULL,
    org_id BIGINT UNSIGNED NOT NULL,
    org_code VARCHAR(64) NOT NULL,
    actor_citizenid VARCHAR(64) NOT NULL,
    amount BIGINT UNSIGNED NOT NULL,
    related_ref VARCHAR(128) NOT NULL,
    request_fingerprint VARCHAR(1024) NOT NULL,
    status VARCHAR(24) NOT NULL DEFAULT 'pending',
    error_code VARCHAR(64) NULL,
    balance_before BIGINT NULL,
    balance_after BIGINT NULL,
    receipt_id VARCHAR(128) NULL,
    correlation_id VARCHAR(128) NULL,
    reversal_of_operation_id BIGINT UNSIGNED NULL,
    metadata_json LONGTEXT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_org_acc_op_scope (source_resource, operation_key),
    UNIQUE KEY uq_mz_org_acc_op_receipt (receipt_id),
    UNIQUE KEY uq_mz_org_acc_op_reversal (reversal_of_operation_id),
    KEY idx_mz_org_acc_op_org (org_id, status, id),
    KEY idx_mz_org_acc_op_actor (actor_citizenid, created_at),
    KEY idx_mz_org_acc_op_related_ref (related_ref)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_economy_transactions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    transaction_id VARCHAR(128) NULL,
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
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],

  [[CREATE TABLE IF NOT EXISTS mz_economy_daily_player_stats (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
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
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mz_econ_daily_player (stat_date, citizenid),
    KEY idx_mz_econ_daily_date (stat_date),
    KEY idx_mz_econ_daily_citizen (citizenid),
    KEY idx_mz_econ_daily_income_hour (income_per_hour)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]
}

local function mysqlReady()
  return MySQL and MySQL.query and type(MySQL.query.await) == 'function'
    and MySQL.single and type(MySQL.single.await) == 'function'
    and MySQL.transaction and type(MySQL.transaction.await) == 'function'
end

local function waitForMySQL()
  local startedAt = GetGameTimer()
  while not mysqlReady() do
    if GetGameTimer() - startedAt >= MYSQL_READY_TIMEOUT_MS then
      return false, 'mysql_not_ready'
    end
    Wait(250)
  end
  return true
end

local function validateTable(tableName)
  local row = MySQL.single.await([[
    SELECT ENGINE AS engine, TABLE_COLLATION AS table_collation
    FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = ?
    LIMIT 1
  ]], { tableName })
  if not row then return false, ('schema_invalid:%s:missing'):format(tableName) end
  if tostring(row.engine or ''):lower() ~= 'innodb' then
    return false, ('schema_invalid:%s:engine'):format(tableName)
  end
  if not tostring(row.table_collation or ''):lower():find('^utf8mb4_') then
    return false, ('schema_invalid:%s:charset'):format(tableName)
  end
  return true
end

function MZEconomyPrepare.ensureTables()
  local ready, err = waitForMySQL()
  if not ready then return false, err end
  for _, statement in ipairs(statements) do MySQL.query.await(statement) end
  for _, tableName in ipairs({
    'mz_player_accounts', 'mz_account_idempotency', 'mz_money_item_sagas', 'mz_org_accounts',
    'mz_org_account_operations', 'mz_economy_transactions', 'mz_economy_daily_player_stats'
  }) do
    local ok, validationErr = validateTable(tableName)
    if not ok then return false, validationErr end
  end
  return true
end

function MZEconomyPrepare.run()
  local callOk, ok, err = pcall(MZEconomyPrepare.ensureTables)
  MZEconomyState.prepareDone = true
  MZEconomyState.prepareOk = callOk == true and ok == true
  MZEconomyState.ready = MZEconomyState.prepareOk
  MZEconomyState.prepareError = MZEconomyState.prepareOk and nil or tostring(callOk and err or ok)
  if not MZEconomyState.prepareOk then return false, MZEconomyState.prepareError end
  return true
end
