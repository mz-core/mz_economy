fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_economy'
author 'Mazus'
description 'Canonical financial accounts, mutations, ledger and reporting for MZ Framework'
version '1.0.0'

shared_scripts {
  'shared/config.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/prepare.lua',
  'server/repository.lua',
  'server/service.lua',
  'server/accounts/repository.lua',
  'server/accounts/core_adapter.lua',
  'server/accounts/service.lua',
  'server/accounts/money_items.lua',
  'server/accounts/org_accounts.lua',
  'server/accounts/police_charges.lua',
  'server/accounts/payroll.lua',
  'server/accounts/exports.lua',
  'server/accounts/commands.lua',
  'server/commands.lua',
  'server/main.lua'
}

dependencies {
  'oxmysql',
  'mz_core',
  'mz_inventory'
}
