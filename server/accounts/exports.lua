exports('GetMoney', function(source)
  return MZAccountService.getMoney(source)
end)

local function cloneTable(value)
  if type(value) ~= 'table' then return value end

  local out = {}
  for key, item in pairs(value) do
    out[key] = cloneTable(item)
  end
  return out
end

local function getInvokingResourceSafe()
  if type(GetInvokingResource) ~= 'function' then return nil end

  local ok, resource = pcall(GetInvokingResource)
  if ok and tostring(resource or '') ~= '' then
    return tostring(resource)
  end

  return nil
end

local function withExportContext(metadata)
  local out
  if type(metadata) == 'table' then
    out = cloneTable(metadata)
  elseif metadata ~= nil then
    out = { __rawMetadata = metadata }
  else
    out = {}
  end

  -- O escopo de idempotência deve vir do runtime server-side. Um
  -- resource chamador não pode escolher outro namespace pelo metadata.
  out.__invokingResource = getInvokingResourceSafe() or 'unknown'
  out.__legacyExport = metadata == nil
  return out
end

exports('NormalizeMoneyAccount', function(moneyType)
  return MZAccountService.NormalizeMoneyAccount(moneyType)
end)

exports('SetMoney', function(source, moneyType, amount, metadata)
  return MZAccountService.setMoney(source, moneyType, amount, withExportContext(metadata))
end)

exports('AddMoney', function(source, moneyType, amount, metadata)
  return MZAccountService.addMoney(source, moneyType, amount, withExportContext(metadata))
end)

exports('RemoveMoney', function(source, moneyType, amount, metadata)
  return MZAccountService.removeMoney(source, moneyType, amount, withExportContext(metadata))
end)

exports('TransferMoneyBetweenAccounts', function(source, fromAccount, toAccount, amount, metadata)
  return MZAccountService.transferMoneyBetweenAccounts(source, fromAccount, toAccount, amount, withExportContext(metadata))
end)

exports('TransferBankBetweenPlayers', function(source, targetCitizenIdOrSource, amount, metadata)
  return MZAccountService.transferBankBetweenPlayers(source, targetCitizenIdOrSource, amount, withExportContext(metadata))
end)

exports('GetOperationResult', function(source, idempotencyKey, operation)
  return MZAccountService.getOperationResult(
    source, idempotencyKey, operation, withExportContext(nil)
  )
end)
