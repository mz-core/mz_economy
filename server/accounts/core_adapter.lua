MZEconomyCore = MZEconomyCore or {}

local playersBySource = {}
local playersByCitizenId = {}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function starterMoney()
  local configured = Config and Config.Economy and Config.Economy.StarterMoney or {}
  local function amount(name)
    local value = math.floor(tonumber(configured[name]) or 0)
    return value >= 0 and value or 0
  end
  return amount('money'), amount('bank'), amount('dirty_money')
end

function MZEconomyCore.ensureAccount(citizenid)
  citizenid = trim(citizenid)
  if citizenid == '' then return false, 'invalid_citizenid' end
  local _, bank = starterMoney()
  local ok, err = pcall(function()
    MySQL.insert.await([[
      INSERT INTO mz_player_accounts (citizenid, bank)
      VALUES (?, ?)
      ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid)
    ]], { citizenid, bank })
  end)
  return ok == true, ok and nil or tostring(err)
end

local function clearSource(source)
  source = tonumber(source)
  local previous = source and playersBySource[source] or nil
  if previous then playersByCitizenId[previous.citizenid] = nil end
  if source then playersBySource[source] = nil end
end

local function buildPlayer(source, identity)
  local citizenid = trim(identity and identity.citizenid)
  if citizenid == '' then return nil end
  local ensured = MZEconomyCore.ensureAccount(citizenid)
  if not ensured then return nil end
  local account = MZAccountRepository.getPlayerAccount(citizenid)
  if not account then return nil end
  local player = {
    source = tonumber(source),
    accountId = tonumber(identity.accountId),
    characterId = tonumber(identity.characterId),
    citizenid = citizenid,
    charinfo = {
      firstname = trim(identity.firstname),
      lastname = trim(identity.lastname),
      phone = trim(identity.phone)
    },
    money = {
      bank = math.floor(tonumber(account.bank) or 0)
    }
  }
  clearSource(source)
  playersBySource[player.source] = player
  playersByCitizenId[citizenid] = player
  if MZMoneyItemsService and type(MZMoneyItemsService.ensureStarterMoney) == 'function' then
    local starterOk, starterErr = MZMoneyItemsService.ensureStarterMoney(citizenid)
    if not starterOk and starterErr ~= 'physical_money_disabled' then
      print(('[mz_economy][money_items] starter pendente citizenid=%s error=%s'):format(
        citizenid, tostring(starterErr or 'unknown')
      ))
    end
  end
  if MZMoneyItemsService and type(MZMoneyItemsService.getPendingRecovery) == 'function' then
    local pending = MZMoneyItemsService.getPendingRecovery(player.source)
    if type(pending) == 'table' and tonumber(pending.total) and pending.total > 0 then
      MZEconomyCore.notifyPlayer(
        player.source,
        ('Voce possui R$ %d em dinheiro protegido aguardando espaco. Use /recuperardinheiro.'):format(pending.total),
        'warning',
        'mz_economy:money_recovery_pending'
      )
    end
  end
  return player
end

function MZEconomyCore.getPlayer(source)
  source = tonumber(source)
  if not source or source <= 0 then return nil end
  local ok, identity = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not ok or type(identity) ~= 'table' or identity.ok ~= true then
    clearSource(source)
    return nil
  end
  local citizenid = trim(identity.citizenid)
  local cached = playersBySource[source]
  if cached and cached.citizenid == citizenid then return cached end
  return buildPlayer(source, identity)
end

function MZEconomyCore.getPlayerByCitizenId(citizenid)
  citizenid = trim(citizenid)
  local cached = playersByCitizenId[citizenid]
  if cached then return MZEconomyCore.getPlayer(cached.source) end
  local ok, snapshot = pcall(function()
    return exports['mz_core']:GetPlayerByCitizenIdSnapshot(citizenid)
  end)
  if not ok or type(snapshot) ~= 'table' or not snapshot.source then return nil end
  return MZEconomyCore.getPlayer(snapshot.source)
end

function MZEconomyCore.getByCitizenId(citizenid)
  local ok, character = pcall(function()
    return exports['mz_core']:GetCharacterByCitizenId(citizenid)
  end)
  if not ok or type(character) ~= 'table' then return nil end
  return {
    id = character.id,
    account_id = character.accountId,
    citizenid = character.citizenid,
    firstname = character.firstname,
    lastname = character.lastname,
    phone = character.phone
  }
end

function MZEconomyCore.canPerformAction(source, action)
  local ok, allowed, detail = pcall(function()
    return exports['mz_core']:CanPlayerPerformAction(source, action)
  end)
  if not ok then return false, { allowed = false, code = 'core_unavailable' } end
  return allowed, detail
end

function MZEconomyCore.makeActor(actorType, actorId, extra)
  local actor = { type = actorType, id = tostring(actorId or '') }
  for key, value in pairs(type(extra) == 'table' and extra or {}) do actor[key] = value end
  return actor
end

function MZEconomyCore.makeTarget(targetType, targetId, extra)
  local target = { type = targetType, id = tostring(targetId or '') }
  for key, value in pairs(type(extra) == 'table' and extra or {}) do target[key] = value end
  return target
end

function MZEconomyCore.createDetailed(scope, action, payload)
  local ok, result = pcall(function()
    return exports['mz_core']:CreateDetailedLog(scope, action, payload)
  end)
  return ok and result or false
end

function MZEconomyCore.create(scope, action, actor, target, data)
  return MZEconomyCore.createDetailed(scope, action, {
    actor = MZEconomyCore.makeActor('system', actor or 'system'),
    target = MZEconomyCore.makeTarget('financial_account', target or 'unknown'),
    meta = type(data) == 'table' and data or {}
  })
end

function MZEconomyCore.notifyPlayer(source, message, notifyType, notificationId)
  source = tonumber(source)
  if not source or source <= 0 then return false end
  local payload = {
    title = 'Economia',
    message = tostring(message or ''),
    type = tostring(notifyType or 'info'),
    duration = 7000,
    id = tostring(notificationId or 'mz_economy:notice')
  }
  if type(GetResourceState) == 'function' and GetResourceState('mz_notify') == 'started' then
    local ok = pcall(function() exports['mz_notify']:Notify(source, payload) end)
    if ok then return true end
  end
  TriggerClientEvent('chat:addMessage', source, {
    color = { 230, 190, 70 },
    args = { 'mz_economy', payload.message }
  })
  return true
end

function MZEconomyCore.jsonEncode(value)
  local ok, encoded = pcall(json.encode, value or {})
  return ok and encoded or '{}'
end

local function ensureLoadedSource(source, snapshot)
  if not (MZEconomyState and MZEconomyState.ready == true) then return end
  local identity = type(snapshot) == 'table' and snapshot or nil
  if not identity or trim(identity.citizenid) == '' then
    local ok, resolved = pcall(function()
      return exports['mz_core']:ResolvePlayerIdentity(source)
    end)
    if not ok or type(resolved) ~= 'table' or resolved.ok ~= true then return end
    identity = resolved
  end
  buildPlayer(source, identity)
end

AddEventHandler('mz_core:server:playerLoaded', function(source, snapshot)
  ensureLoadedSource(source, snapshot)
end)

AddEventHandler('playerDropped', function()
  clearSource(source)
end)

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  CreateThread(function()
    while not (MZEconomyState and MZEconomyState.ready == true) do Wait(100) end
    for _, source in ipairs(GetPlayers()) do ensureLoadedSource(tonumber(source)) end
  end)
end)
