fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_economy'
author 'Mazus'
description 'Passive economy ledger and diagnostics for mz_core'
version '0.1.0'

shared_scripts {
  'shared/config.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/prepare.lua',
  'server/repository.lua',
  'server/service.lua',
  'server/outbox_consumer.lua',
  'server/commands.lua',
  'server/main.lua'
}

dependencies {
  'oxmysql',
  'mz_core'
}
