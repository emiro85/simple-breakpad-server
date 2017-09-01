config = require '../config'
path = require 'path'
fs = require 'fs-promise'
cache = require './cache'
minidump = require 'minidump'
Sequelize = require 'sequelize'
sequelize = require './db'
tmp = require 'tmp'

symbolsPath = config.getSymbolsPath()

# custom fields should have 'files' and 'params'
customFields = config.get('customFields') || {}

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

Crashreport.getAllReports = (limit, offset, callback) ->
  attributes = []

  # only fetch non-blob attributes to speed up the query
  for name, value of Crashreport.attributes
    unless value.type instanceof Sequelize.BLOB
      attributes.push name

  findAllQuery =
    order: 'created_at DESC'
    limit: limit
    offset: offset
    attributes: attributes

  Crashreport.findAndCountAll(findAllQuery).then (q) ->
    records = q.rows
    count = q.count
    callback(records, count)

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
