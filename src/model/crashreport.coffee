config = require '../config'
path = require 'path'
fs = require 'fs-promise'
cache = require './cache'
minidump = require 'minidump'
Sequelize = require 'sequelize'
sequelize = require './db'
tmp = require 'tmp'
addr = require 'addr'
streamToArray = require 'stream-to-array'

symbolsPath = config.getSymbolsPath()

# custom fields should have 'files' and 'params'
customFields = config.get('crashreports:customFields') || {}

Product = sequelize.define('crashreport_product',
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  value:
    type: Sequelize.STRING
)

Version = sequelize.define('crashreport_version',
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  value:
    type: Sequelize.STRING
)

schema =
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  product_id:
    type: Sequelize.INTEGER
  version_id:
    type: Sequelize.INTEGER
  ip:
    type: Sequelize.STRING

options =
  indexes: [
    { fields: ['created_at'] }
  ]

for field in customFields.files
  schema[field.name] = Sequelize.BLOB

Crashreport = sequelize.define('crashreports', schema, options)

exclude = ['product_id', 'version_id']

Crashreport.belongsTo(Product, foreignKey: 'product_id', as: 'product')
Product.hasMany(Crashreport, foreignKey: 'product_id', as: 'product')
Crashreport.belongsTo(Version, foreignKey: 'version_id', as: 'version')
Version.hasMany(Crashreport, foreignKey: 'version_id', as: 'version')

getAliasFromDbName = (dbName) ->
  alias = dbName.substring(dbName.lastIndexOf('_') + 1)
  return alias

CustomFields = []
customFields.params.map (alias) ->
  param = 'crashreport_' + alias.name
  customField = sequelize.define( param,
    id:
      type: Sequelize.INTEGER
      autoIncrement: yes
      primaryKey: yes
    value:
      type: Sequelize.STRING
  )
  foreignKey = alias.name + '_id'
  Crashreport.belongsTo(customField, foreignKey: foreignKey, as: alias.name)
  customField.hasMany(Crashreport, foreignKey: foreignKey, as: alias.name)
  CustomFields.push(customField)
  exclude.push(foreignKey)

Sequelize.sync

Crashreport.findReportById = (param) ->
  include = [
    { model: Product, as: 'product'}
    { model: Version, as: 'version' }
  ]

  CustomFields.map (customField) ->
    alias = getAliasFromDbName(customField.name)
    customInclude = { model: customField, as: alias }
    include.push(customInclude)

  options =
    include: include
    attributes:
      exclude: exclude
  Crashreport.findById(param, options)

Crashreport.getAllReports = (limit, offset, query, callback) ->
  include = []
  # only fetch non-blob attributes to speed up the query
  excludeWithBlob = ['product_id', 'version_id', 'upload_file_minidump']

  productInclude = { model: Product, as: 'product'}
  if 'product' of query && !!query['product']
    productInclude['where'] =  { value: query['product'] }
  include.push(productInclude)

  versionInclude = { model: Version, as: 'version'}
  if 'version' of query && !!query['version']
    versionInclude['where'] =  { value: query['version'] }
  include.push(versionInclude)

  CustomFields.map (customField) ->
    alias = getAliasFromDbName(customField.name)
    customInclude = { model: customField, as: alias }
    if alias of query && !!query[alias]
      customInclude['where'] =  { value: query[alias] }
    include.push(customInclude)
    excludeWithBlob.push(alias + '_id')

  findAllQuery =
    order: [['created_at', 'DESC']]
    limit: limit
    offset: offset
    attributes:
      exclude: excludeWithBlob
    include: include

  Crashreport.findAndCountAll(findAllQuery).then (q) ->
    records = q.rows
    count = q.count
    callback(records, count)

Crashreport.getAllQueryParameters = (callback) ->
  allPromises = []
  allPromises.push(Product.findAll())
  allPromises.push(Version.findAll())
  CustomFields.map((customField) ->
    allPromises.push(customField.findAll())
  )
  queryParameters = {}
  Sequelize.Promise.all(allPromises).then (results) ->
    values = []
    for product in results[0]
      values.push(product.value)
    queryParameters['product'] = values

    values = []
    for version in results[1]
      values.push(version.value)
    queryParameters['version'] = values

    for i in [0...CustomFields.length]
      values = []
      for field in results[i+2]
        values.push(field.value)
      queryParameters[getAliasFromDbName(CustomFields[i].name)] = values

    callback(queryParameters)

Crashreport.createFromRequest = (req, res, callback) ->
  props = {}
  streamOps = []
  httpPostFields = {}
  product = undefined
  version = undefined

  # Get originating request address, respecting reverse proxies (e.g.
  #   X-Forwarded-For header)
  # Fixed list of just localhost as trusted reverse-proxy, we can add
  #   a config option if needed
  props.ip = addr(req, ['127.0.0.1', '::ffff:127.0.0.1'])

  req.busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
    streamOps.push streamToArray(file).then((parts) ->
      buffers = []
      for i in [0 .. parts.length - 1]
        part = parts[i]
        buffers.push if part instanceof Buffer then part else new Buffer(part)

      return Buffer.concat(buffers)
    ).then (buffer) ->
      if fieldname of Crashreport.attributes
        props[fieldname] = buffer

  req.busboy.on 'field', (fieldname, val, fieldnameTruncated, valTruncated) ->
    if fieldname == 'prod'
      product = val
    else if fieldname == 'ver'
      version = val
    else
      httpPostFields[fieldname] = val.toString()

  req.busboy.on 'finish', ->
    Promise.all(streamOps).then ->

      if not props.hasOwnProperty('upload_file_minidump')
        res.status 400
        throw new Error 'Form must include a "upload_file_minidump" field'

      if not version
        res.status 400
        throw new Error 'Form must include a "ver" field'

      if not product
        res.status 400
        throw new Error 'Form must include a "prod" field'

      sequelize.transaction (t) ->
        allPromises = []
        allPromises.push(Product.findOrCreate({where: {value: product}, transaction: t}))
        allPromises.push(Version.findOrCreate({where: {value: version}, transaction: t}))
        postedFieldNames = []
        CustomFields.map (customField) ->
          fieldName = getAliasFromDbName(customField.name)
          if fieldName of httpPostFields
            postedFieldNames.push(fieldName)
            allPromises.push(customField.findOrCreate({where: {value: httpPostFields[fieldName]},transaction: t}))

        Sequelize.Promise.all(allPromises).then (results) ->

          props.product_id = results[0][0].id
          props.version_id = results[1][0].id
          for i in [2...allPromises.length]
            if !results[i]
              continue
            customFieldId = postedFieldNames[i-2] + '_id'
            customField = results[i][0]
            props[customFieldId] = customField.id

          include = [
            { model: Product, as: 'product'}
            { model: Version, as: 'version' }
          ]
          CustomFields.map (customField) ->
            customInclude = { model: customField, as: getAliasFromDbName(customField.name) }
            include.push(customInclude)

          Crashreport.create(props, include: include, transaction: t).then (report) ->
            query =
              where: props
              include: include
              attributes:
                exclude: exclude
              transaction: t
            Crashreport.findOne(query).then (report) ->
              callback(null, report)

    .catch (err) ->
      callback err

  req.pipe(req.busboy)

Crashreport.getStackTrace = (record, callback) ->
  return callback(null, cache.get(record.id)) if cache.has record.id

  tmpfile = tmp.fileSync()
  fs.writeFile(tmpfile.name, record.upload_file_minidump).then ->
    minidump.walkStack tmpfile.name, [symbolsPath], (err, report) ->
      tmpfile.removeCallback()
      cache.set record.id, report unless err?
      callback err, report
  .catch (err) ->
    tmpfile.removeCallback()
    callback err

module.exports = Crashreport
