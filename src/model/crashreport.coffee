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

schema =
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  product: Sequelize.STRING
  version: Sequelize.STRING

options =
  indexes: [
    { fields: ['created_at'] }
  ]

for field in customFields.params
  schema[field.name] = Sequelize.STRING

for field in customFields.files
  schema[field.name] = Sequelize.BLOB

Crashreport = sequelize.define('crashreports', schema, options)

Crashreport.findReportById = (param) ->
  options = {}
  Crashreport.findById(param, options)

Crashreport.getAllReports = (limit, offset, callback) ->
  attributes = []

  # only fetch non-blob attributes to speed up the query
  for name, value of Crashreport.attributes
    unless value.type instanceof Sequelize.BLOB
      attributes.push name

  findAllQuery =
    order: [['created_at', 'DESC']]
    limit: limit
    offset: offset
    attributes: attributes

  Crashreport.findAndCountAll(findAllQuery).then (q) ->
    records = q.rows
    count = q.count
    callback(records, count)

Crashreport.createFromRequest = (req, res, callback) ->
  props = {}
  streamOps = []
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
      props['product'] = val
    else if fieldname == 'ver'
      props['version'] = val
    else if fieldname of Crashreport.attributes
      props[fieldname] = val.toString()

  req.busboy.on 'finish', ->
    Promise.all(streamOps).then ->

      if not props.hasOwnProperty('upload_file_minidump')
        res.status 400
        throw new Error 'Form must include a "upload_file_minidump" field'

      if not props.hasOwnProperty('version')
        res.status 400
        throw new Error 'Form must include a "ver" field'

      if not props.hasOwnProperty('product')
        res.status 400
        throw new Error 'Form must include a "prod" field'

      Crashreport.create(props).then (report) ->
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
