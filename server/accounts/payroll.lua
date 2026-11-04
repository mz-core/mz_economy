MZPayrollService = MZPayrollService or {}

local function asBool(value)
  if value == true then return true end
  if value == false or value == nil then return false end
  if type(value) == 'number' then return value == 1 end
  if type(value) == 'string' then
    value = value:lower()
    return value == '1' or value == 'true'
  end
  return false
end

local function buildPayrollActor(actor)
  if actor == nil then
    return {
      type = 'system',
      id = 'system'
    }
  end

  if tonumber(actor) == 0 then
    return {
      type = 'console',
      id = 'console'
    }
  end

  if type(actor) == 'number' then
    local player = MZEconomyCore.getPlayer(actor)
    if player and player.citizenid then
      return {
        type = 'player',
        id = tostring(player.citizenid),
        source = actor
      }
    end

    return {
      type = 'source',
      id = tostring(actor)
    }
  end

  return {
    type = 'system',
    id = tostring(actor)
  }
end

local ledgerSequence = 0

local function nextPayrollLedgerRef(orgCode, citizenid)
  ledgerSequence = ledgerSequence + 1
  local stamp = type(GetGameTimer) == 'function' and GetGameTimer() or os.time()
  return ('payroll:%s:%s:%s:%s'):format(
    tostring(orgCode or 'unknown'),
    tostring(citizenid or 'unknown'),
    tostring(stamp),
    tostring(ledgerSequence)
  )
end

local persistPayrollPayment

function MZPayrollService.payCitizen(citizenid, memberships, actor, options)
  local playerRow = MZEconomyCore.getByCitizenId(citizenid)
  if not playerRow then
    return false, 'player_not_found'
  end

  memberships = type(memberships) == 'table' and memberships or {}
  if #memberships == 0 then
    return false, 'no_memberships'
  end

  local paid = {}
  local skipped = {}
  options = type(options) == 'table' and options or {}
  local requireDuty = options.requireDuty ~= false
  local bankBefore = nil
  local bankAfter = nil

  for _, membership in ipairs(memberships) do
    local salary = math.floor(tonumber(membership.salary) or 0)

    if asBool(membership.has_salary) and salary > 0 then
      if (not requireDuty) or asBool(membership.duty) then
        if not asBool(membership.has_shared_account) then
          skipped[#skipped + 1] = {
            org = membership.org_code,
            amount = salary,
            reason = 'org_has_no_shared_account'
          }
          goto continue_membership
        end

        local paidOk, detailOrErr = persistPayrollPayment(
          citizenid, membership, salary, playerRow, requireDuty
        )
        if paidOk then
          local detail = detailOrErr
          if bankBefore == nil then bankBefore = detail.bankBefore end
          bankAfter = detail.bankAfter
          paid[#paid + 1] = {
            org = membership.org_code,
            amount = salary,
            source = 'org_account',
            replayed = detail.replayed == true
          }
        else
          skipped[#skipped + 1] = {
            org = membership.org_code,
            amount = salary,
            reason = detailOrErr or 'payment_failed'
          }
        end
      end
    end

    ::continue_membership::
  end

  if MZEconomyCore and #skipped > 0 then
    MZEconomyCore.createDetailed('payroll', 'pay_citizen_inconsistency', {
      actor = buildPayrollActor(actor),
      target = {
        type = 'player_account',
        id = tostring(citizenid)
      },
      context = {
        citizenid = tostring(citizenid),
        require_duty = requireDuty == true,
        membership_count = #memberships
      },
      meta = {
        skipped = skipped
      }
    })
  end

  if #paid == 0 then
    return false, 'nothing_paid'
  end

  if MZEconomyCore then
    MZEconomyCore.createDetailed('payroll', 'pay_citizen', {
      actor = buildPayrollActor(actor),
      target = {
        type = 'player_account',
        id = tostring(citizenid)
      },
      context = {
        citizenid = tostring(citizenid),
        require_duty = requireDuty == true,
        membership_count = #memberships
      },
      before = {
        bank = math.floor(tonumber(bankBefore) or 0)
      },
      after = {
        bank = math.floor(tonumber(bankAfter ~= nil and bankAfter or bankBefore) or 0)
      },
      meta = {
        payments = paid,
        skipped = skipped
      }
    })
  end

  return true, paid
end

persistPayrollPayment = function(citizenid, membership, salary, playerRow, requireDuty)
  return MZAccountService.WithFinancialLocksInternal({
    tostring(citizenid),
    ('org:%s'):format(membership.org_id)
  }, function()
    local playerAccount = MySQL.single.await(
      'SELECT bank FROM mz_player_accounts WHERE citizenid = ? LIMIT 1',
      { citizenid }
    )
    local orgAccount = MySQL.single.await(
      'SELECT balance FROM mz_org_accounts WHERE org_id = ? LIMIT 1',
      { membership.org_id }
    )
    if not playerAccount then return false, 'account_not_found' end
    if not orgAccount then return false, 'org_account_missing' end

    local bankBefore = math.floor(tonumber(playerAccount.bank) or 0)
    local orgBefore = math.floor(tonumber(orgAccount.balance) or 0)
    local intervalMinutes = math.max(1, math.floor(tonumber(Config.Payroll and Config.Payroll.intervalMinutes) or 30))
    local payrollBucket = math.floor(os.time() / (intervalMinutes * 60))
    local idempotencyKey = ('payroll_%s_%d'):format(tostring(membership.org_id), payrollBucket)
    local requestFingerprint = ('org=%s;citizen=%s;salary=%d;bucket=%d'):format(
      tostring(membership.org_id), tostring(citizenid), salary, payrollBucket
    )
    local existing = MZAccountRepository.getIdempotentOperation('mz_economy', citizenid, idempotencyKey)
    if existing then
      if tostring(existing.operation or '') ~= 'payroll_payment'
          or tostring(existing.request_fingerprint or '') ~= requestFingerprint then
        return false, 'idempotency_conflict'
      end
      return true, {
        bankBefore = bankBefore, bankAfter = bankBefore,
        orgBefore = orgBefore, orgAfter = orgBefore,
        externalRef = tostring(existing.correlation_id or ''),
        ledgerPersisted = true, replayed = true
      }
    end
    if orgBefore < salary then return false, 'insufficient_org_funds' end
    if bankBefore > 9007199254740991 - salary then return false, 'amount_overflow' end

    local bankAfter = bankBefore + salary
    local orgAfter = orgBefore - salary
    local externalRef = nextPayrollLedgerRef(membership.org_code, citizenid)
    local commonData = {
      channel = 'payroll',
      operation = 'pay_salary',
      org_id = tonumber(membership.org_id) or membership.org_id,
      org_code = tostring(membership.org_code),
      grade_level = tonumber(membership.grade_level) or 0,
      salary = salary,
      duty = asBool(membership.duty),
      require_duty = requireDuty == true
    }
    local playerOptions = {
      reason = 'payroll_salary', category = 'salary',
      source_resource = 'mz_economy', source_type = 'payroll',
      sourceType = 'payroll', related_org_code = tostring(membership.org_code),
      external_ref = externalRef, counts_as_income = true, counts_as_expense = false,
      data = commonData
    }
    local orgOptions = {
      reason = 'payroll_salary_expense', category = 'salary_expense',
      source_resource = 'mz_economy', source_type = 'payroll',
      sourceType = 'payroll', related_citizenid = tostring(citizenid),
      related_org_code = tostring(membership.org_code), external_ref = externalRef,
      counts_as_income = false, counts_as_expense = true, data = commonData
    }
    local playerMetadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(playerOptions, {})
    local orgMetadata = MZAccountService.NormalizeFinancialLedgerOptionsInternal(orgOptions, {})
    local correlationId = MZAccountService.GenerateFinancialTransactionRefInternal('mzacc-payroll')
    local idempotency = {
      sourceResource = 'mz_economy', actorCitizenId = tostring(citizenid),
      key = idempotencyKey, operation = 'payroll_payment',
      fingerprint = requestFingerprint, correlationId = correlationId,
      resultJson = json.encode({ ok = true, correlationId = correlationId, replayed = false })
    }
    local ledgerBatch, ledgerErr = MZAccountService.BuildFinancialLedgerBatchInternal({
      correlationId = correlationId,
      idempotency = idempotency,
      eventType = 'payroll_payment',
      sourceCitizenId = citizenid,
      account = 'multi', amount = salary, fee = 0,
      reason = playerMetadata.reason, ledgerMetadata = playerMetadata,
      options = playerOptions,
      entries = {
        MZAccountService.BuildFinancialLedgerEntryInternal(
          1, nil, 'org', 'out', salary, orgBefore, orgAfter, orgMetadata
        ),
        MZAccountService.BuildFinancialLedgerEntryInternal(
          2, citizenid, 'bank', 'in', salary, bankBefore, bankAfter, playerMetadata
        )
      }
    })
    if ledgerBatch == false then return false, ledgerErr end

    if not MZAccountRepository.transferPlayerBankAndOrg(
      citizenid, bankAfter, membership.org_id, orgAfter, ledgerBatch, idempotency
    ) then
      local replay = MZAccountRepository.getIdempotentOperation('mz_economy', citizenid, idempotencyKey)
      if replay and tostring(replay.operation or '') == 'payroll_payment'
          and tostring(replay.request_fingerprint or '') == requestFingerprint then
        return true, {
          bankBefore = bankBefore, bankAfter = bankBefore,
          orgBefore = orgBefore, orgAfter = orgBefore,
          externalRef = tostring(replay.correlation_id or ''),
          ledgerPersisted = true, replayed = true
        }
      end
      return false, 'database_error'
    end

    local online = MZEconomyCore.getPlayerByCitizenId(citizenid)
    if online and online.money then online.money.bank = bankAfter end
    return true, {
      bankBefore = bankBefore, bankAfter = bankAfter,
      orgBefore = orgBefore, orgAfter = orgAfter,
      externalRef = externalRef, ledgerPersisted = type(ledgerBatch) == 'table',
      playerMetadata = playerMetadata, orgMetadata = orgMetadata
    }
  end)
end

exports('PayOrganizationSalaries', function(citizenid, memberships, actor, options)
  if GetInvokingResource() ~= 'mz_org' then return false, 'forbidden_caller' end
  return MZPayrollService.payCitizen(citizenid, memberships, actor, options)
end)
