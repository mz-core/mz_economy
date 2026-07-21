Config = Config or {}

Config.Economy = {
  Debug = false,

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

-- Fase 3 / P3-C: o consumer privado e idempotente existe, mas permanece
-- desligado por padrao. Ele aceita somente chamadas server-side do mz_core.
Config.Economy.FinancialOutbox = {
  Enabled = false,
  ConsumerEnabled = false,
  SchemaVersion = 1
}
