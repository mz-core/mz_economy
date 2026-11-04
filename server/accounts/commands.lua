local function reply(message)
  print(('[mz_economy] %s'):format(message))
end

local function replyPlayer(source, message)
  TriggerClientEvent('chat:addMessage', source, {
    color = { 255, 80, 80 },
    args = { 'mz_economy', tostring(message or '') }
  })
end

local function joinReason(args, startIndex)
  local parts = {}
  for index = startIndex, #(args or {}) do parts[#parts + 1] = tostring(args[index]) end
  local reason = table.concat(parts, ' '):gsub('^%s+', ''):gsub('%s+$', '')
  return reason ~= '' and reason or 'console_money_add'
end

RegisterCommand('mz_money_add', function(source, args)
  if tonumber(source) ~= 0 then
    return replyPlayer(source, 'Este comando so pode ser usado pelo console do servidor.')
  end

  args = type(args) == 'table' and args or {}
  local targetArg = tostring(args[1] or '')
  local accountArg = tostring(args[2] or '')
  local amountArg = tostring(args[3] or '')
  if targetArg == '' or accountArg == '' or amountArg == '' then
    return reply('mz_money_add ERRO: uso mz_money_add <source> <wallet|bank|dirty|cash|money|black_money> <amount> [reason]')
  end

  local targetSource = tonumber(targetArg)
  if not targetSource or targetSource <= 0 or math.floor(targetSource) ~= targetSource then
    return reply('mz_money_add ERRO: neste MVP o target deve ser source online numerico')
  end
  local player = MZEconomyCore.getPlayer(targetSource)
  if not player or not player.citizenid then
    return reply(('mz_money_add ERRO: target nao carregado no mz_economy (%s)'):format(targetArg))
  end

  local normalizedAccount, accountErr = MZAccountService.NormalizeMoneyAccount(accountArg)
  if not normalizedAccount then return reply(('mz_money_add ERRO: %s'):format(accountErr or 'invalid_account')) end
  local amount = tonumber(amountArg)
  if not amount or amount ~= amount or amount <= 0 or math.floor(amount) ~= amount then
    return reply('mz_money_add ERRO: amount deve ser inteiro positivo')
  end
  amount = math.floor(amount)

  local operationKey = MZAccountService.GenerateFinancialTransactionRefInternal('console_money_add')
  local ok, err = MZAccountService.addMoney(targetSource, normalizedAccount, amount, {
    __invokingResource = 'mz_economy',
    idempotency_key = operationKey,
    reason = joinReason(args, 4),
    category = 'admin_adjustment', source_resource = 'mz_economy', source_type = 'console_command',
    external_ref = operationKey,
    counts_as_income = false, counts_as_expense = false,
    data = { command = 'mz_money_add', target = targetArg, account = normalizedAccount, amount = amount }
  })
  if not ok then return reply(('mz_money_add ERRO: %s'):format(tostring(err or 'unknown'))) end
  reply(('mz_money_add OK: target=%s account=%s amount=%s'):format(targetArg, normalizedAccount, amount))
end, false)

RegisterCommand('recuperardinheiro', function(source)
  source = tonumber(source) or 0
  if source <= 0 then return reply('recuperardinheiro ERRO: comando disponivel apenas para jogadores.') end
  if not MZMoneyItemsService or type(MZMoneyItemsService.claimRecovery) ~= 'function' then
    return MZEconomyCore.notifyPlayer(source, 'O resgate de dinheiro esta indisponivel.', 'error')
  end

  local ok, result = MZMoneyItemsService.claimRecovery(source)
  result = type(result) == 'table' and result or { error = tostring(result or 'money_recovery_failed') }
  if ok then
    if math.floor(tonumber(result.total) or 0) <= 0 then
      return MZEconomyCore.notifyPlayer(source, 'Nao ha dinheiro protegido aguardando resgate.', 'info')
    end
    return MZEconomyCore.notifyPlayer(
      source,
      ('R$ %d foram movidos para o seu inventario.'):format(math.floor(result.total)),
      'success',
      'mz_economy:money_recovery_claimed'
    )
  end

  local noSpace = result.error == 'inventory_full' or result.error == 'no_free_slot'
  local message = noSpace
    and 'Ainda nao ha espaco no inventario. O dinheiro continua protegido.'
    or ('Nao foi possivel resgatar o dinheiro agora: %s.'):format(tostring(result.error))
  return MZEconomyCore.notifyPlayer(source, message, 'error', 'mz_economy:money_recovery_failed')
end, false)
