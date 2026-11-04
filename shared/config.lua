Config = Config or {}

Config.Economy = {
  Debug = false,

  StarterMoney = {
    money = 500,
    bank = 5000,
    dirty_money = 0
  },

  PhysicalMoney = {
    Enabled = true,
    InventoryResource = 'mz_inventory',
    RecoveryIntervalMs = 15000
  },

  Accounts = {
    wallet = true,
    bank = true,
    dirty = true,
    org = true
  },

  AccountAliases = {
    cash = 'wallet',
    money = 'wallet',
    black_money = 'dirty'
  },

  Directions = {
    ['in'] = true,
    out = true,
    transfer = true,
    adjustment = true
  },

  DefaultCategory = 'unknown',
  DefaultSourceResource = 'unknown',

  -- Operacoes sem source sao fail-closed e precisam declarar identity_mode.
  -- Esta lista autoriza o chamador real; source_resource no payload nao concede confianca.
  SourceLessIdentityAllowedResources = {
    mz_economy = true
  },

  StaffAce = 'group.mz_owner',

  UnknownLimitDefault = 25,
  UnknownLimitMax = 100,
  StatementLimitMax = 100,

  Stats = {
    MinMinutesOnlineToCount = 60,
    MaxTopRows = 10,
    IncludeOpenSessions = true
  },

  Reports = {
    MaxRows = 10,
    UnknownWarningPercent = 5,
    UnknownCriticalPercent = 15,
    SuspiciousIncomeMultiplier = 3.0,
    MinMinutesForSuspicious = 60,
    LargeTransactionAmount = 100000
  },

  AllowIncomeExpenseSameTransaction = false
}
