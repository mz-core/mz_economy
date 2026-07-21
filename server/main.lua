CreateThread(function()
  local ok, err = MZEconomyPrepare.run()
  if not ok then
    print(('[mz_economy] prepare failed: %s'):format(tostring(err or 'unknown')))
    return
  end

  print('[mz_economy] passive ledger ready')
end)

exports('RecordTransaction', function(data)
  return MZEconomyService.RecordTransaction(data)
end)

-- Contrato privado P3-C. A implementacao valida novamente GetInvokingResource
-- e aceita exclusivamente o mz_core.
exports('ConsumeFinancialOutbox', function(event)
  return MZEconomyService.ConsumeFinancialOutbox(event)
end)

exports('GetFinancialOutboxConsumerReadiness', function()
  return MZEconomyService.GetFinancialOutboxConsumerReadiness()
end)

exports('ValidateFinancialOutbox', function(event)
  return MZEconomyService.ValidateFinancialOutbox(event)
end)

exports('GetDailySummary', function(date)
  return MZEconomyService.GetDailySummary(date)
end)

exports('GetUnknownTransactions', function(date, limit)
  return MZEconomyService.GetUnknownTransactions(date, limit)
end)

exports('GetSourceSummary', function(date)
  return MZEconomyService.GetSourceSummary(date)
end)

exports('GetHealthReport', function(date)
  return MZEconomyService.GetHealthReport(date)
end)

exports('GetUnknownSources', function(date, limit)
  return MZEconomyService.GetUnknownSources(date, limit)
end)

exports('GetCategoryReport', function(date, limit)
  return MZEconomyService.GetCategoryReport(date, limit)
end)

exports('GetSuspiciousReport', function(date, limit)
  return MZEconomyService.GetSuspiciousReport(date, limit)
end)

exports('RebuildDailyStats', function(date)
  return MZEconomyService.RebuildDailyStats(date)
end)

exports('GetDailyStatsSummary', function(date)
  return MZEconomyService.GetDailyStatsSummary(date)
end)

exports('GetDailyPlayerStats', function(target, date)
  return MZEconomyService.GetDailyPlayerStats(target, date)
end)

exports('GetDailyTop', function(date, mode, limit)
  return MZEconomyService.GetDailyTop(date, mode, limit)
end)

exports('GetPlayerTransactions', function(target, date, limit)
  return MZEconomyService.GetPlayerTransactions(target, date, limit)
end)

exports('GetAccountStatement', function(source, account, limit)
  return MZEconomyService.GetAccountStatement(source, account, limit)
end)

exports('GetSourceTransactions', function(sourceResource, date, limit)
  return MZEconomyService.GetSourceTransactions(sourceResource, date, limit)
end)
