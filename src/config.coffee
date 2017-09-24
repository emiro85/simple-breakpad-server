nconf = require 'nconf'
nconf.formats.yaml = require 'nconf-yaml'
fs = require 'fs-promise'
os = require 'os'
path = require 'path'

SBS_HOME = path.join(os.homedir(), '.simple-breakpad-server')

nconf.file 'pwd', {
  file: path.join(process.cwd(), 'breakpad-server.yaml')
  format: nconf.formats.yaml
}
nconf.file 'user', {
  file: path.join(SBS_HOME, 'breakpad-server.yaml')
  format: nconf.formats.yaml
}
unless process.platform == 'win32'
  nconf.file 'system', {
    file: '/etc/breakpad-server.yaml'
    format: nconf.formats.yaml
  }

nconf.argv()
nconf.env()

nconf.defaults
  port: 1127
  baseUrl: '/'
  serverName: 'Breakpad Server'
  database:
    host: 'localhost'
    dialect: 'sqlite'
    storage: path.join(SBS_HOME, 'database.sqlite')
    logging: no
  auth:
    enabled: false
  crashreports:
    order: ['upload_file_minidump', 'product', 'version', 'ip', 'created']
    customFields:
      files: []
      params: []
  symbols:
    order: ['os', 'name', 'arch', 'code', 'created' ]
    customFields:
      params: []
  dataDir: SBS_HOME
  trustedProxies: ['127.0.0.1', '::ffff:127.0.0.1']

# Post-process custom files and params
customFields = nconf.get('crashreports:customFields')

# Ensure array
customFields.files = customFields.files || []
# Always add upload_file_minidump file as first file
customFields.files.splice(0, 0,
  name: 'upload_file_minidump'
  downloadAs: 'upload_file_minidump.{{id}}.dmp'
)
# Ensure array members are objects and build lookup
customFields.filesById = {}
for field, idx in customFields.files
  if typeof field is 'string'
    customFields.files[idx] =
      name: field
  customFields.filesById[customFields.files[idx].name] = customFields.files[idx]

# Ensure array
customFields.params = customFields.params || []

# Ensure array members are objects and build lookup
customFields.paramsById = {}
for field, idx in customFields.params
  if typeof field is 'string'
    customFields.params[idx] =
      name: field
  customFields.paramsById[customFields.params[idx].name] = customFields.params[idx]

nconf.set('crashreports:customFields', customFields)

nconf.getSymbolsPath = -> path.join(nconf.get('dataDir'), 'symbols')

fs.mkdirsSync(nconf.getSymbolsPath())

module.exports = nconf
