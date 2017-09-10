config = require '../config'
cache = require './cache'
Sequelize = require 'sequelize'
sequelize = require './db'
fs = require 'fs-promise'
path = require 'path'
streamToArray = require 'stream-to-array'

symbolsPath = config.getSymbolsPath()
COMPOSITE_INDEX = 'compositeIndex'

Os = sequelize.define('symfile_os',
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  value:
    type: Sequelize.STRING
)

Name = sequelize.define('symfile_name',
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes
  value:
    type: Sequelize.STRING
)

Arch = sequelize.define('symfile_arch',
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
  os_id:
    type: Sequelize.INTEGER
    unique: COMPOSITE_INDEX
  name_id:
    type: Sequelize.INTEGER
    unique: COMPOSITE_INDEX
  arch_id:
    type: Sequelize.INTEGER
    unique: COMPOSITE_INDEX
  code:
    type: Sequelize.STRING
    unique: COMPOSITE_INDEX
  contents: Sequelize.TEXT

Symfile = sequelize.define('symfiles',
  schema,
  indexes: [
    { fields: ['created_at'] }
  ])

include = [
  { model: Name, as: 'name'}
  { model: Os, as: 'os' }
  { model: Arch, as: 'arch' }
  ]

exclude = ['os_id', 'arch_id', 'name_id']

Symfile.belongsTo(Os, foreignKey: 'os_id', as: 'os')
Os.hasMany(Symfile, foreignKey: 'os_id', as: 'os')
Symfile.belongsTo(Name, foreignKey: 'name_id', as: 'name')
Name.hasMany(Symfile, foreignKey: 'name_id', as: 'name')
Symfile.belongsTo(Arch, foreignKey: 'arch_id', as: 'arch')
Arch.hasMany(Symfile, foreignKey: 'arch_id', as: 'arch')

Symfile.findFileById = (param) ->
  include = [
    { model: Name, as: 'name'}
    { model: Os, as: 'os' }
    { model: Arch, as: 'arch' }
  ]

  options =
    include: include
    attributes:
      exclude: exclude
  Symfile.findById(param, options)

Symfile.getAllSymfiles = (limit, offset, callback) ->
  findAllQuery =
    order: [['created_at', 'DESC']]
    limit: limit
    offset: offset
    include: include
    attributes:
      exclude: exclude

  Symfile.findAndCountAll(findAllQuery).then (q) ->
    records = q.rows
    count = q.count
    callback(records, count)

Symfile.saveToDisk = (symfile) ->
  symbolName = symfile.name.value
  symfileDir = path.join(symbolsPath, symbolName, symfile.code)

  fs.mkdirs(symfileDir).then ->
    # From https://chromium.googlesource.com/breakpad/breakpad/+/master/src/processor/simple_symbol_supplier.cc#179:
    # Transform the debug file name into one ending in .sym.  If the existing
    #   name ends in .pdb, strip the .pdb.  Otherwise, add .sym to the non-.pdb
    #   name.
    if path.extname(symbolName).toLowerCase() == '.pdb'
      symbolName = symbolName.slice(0, -4)
    symbolName += '.sym'
    filePath = path.join(symfileDir, symbolName)
    fs.writeFile(filePath, symfile.contents)

Symfile.saveAllToDisk = () ->
  include = [
    { model: Name, as: 'name'}
    { model: Os, as: 'os' }
    { model: Arch, as: 'arch' }
  ]
  Symfile.findAll(include: include).then (symfiles) ->
    Promise.all(symfiles.map((s) -> Symfile.saveToDisk(s)))

Symfile.createFromRequest = (req, res, callback) ->
  props = {}
  streamOps = []

  req.busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
    streamOps.push streamToArray(file).then((parts) ->
      buffers = []
      for i in [0 .. parts.length - 1]
        part = parts[i]
        buffers.push if part instanceof Buffer then part else new Buffer(part)

      return Buffer.concat(buffers)
    ).then (buffer) ->
      if fieldname == 'symfile'
        props[fieldname] = buffer.toString()

  req.busboy.on 'finish', ->
    Promise.all(streamOps).then ->
      if not props.hasOwnProperty('symfile')
        res.status 400
        throw new Error 'Form must include a "symfile" field'

      contents = props.symfile
      header = contents.split('\n')[0].split(/\s+/)

      [dec, os, arch, code, name] = header

      if dec != 'MODULE'
        msg = 'Could not parse header (expecting MODULE as first line)'
        throw new Error msg

      sequelize.transaction (t) ->
        # The following section cannot be simplified by a Symfile.create with nested associations, since the associated
        # models will always create a new row and not reference an existing one.
        # If somebody can find an easier way, feel free to refactor the section.
        allPromises = []
        allPromises.push(Os.findOrCreate({where: {value: os}, transaction: t}))
        allPromises.push(Name.findOrCreate({where: {value: name}, transaction: t}))
        allPromises.push(Arch.findOrCreate({where: {value: arch}, transaction: t}))
        Sequelize.Promise.all(allPromises).then (results) ->
          os = results[0][0]
          name = results[1][0]
          arch = results[2][0]
          props =
            os_id: os.id
            name_id: name.id
            arch_id: arch.id
            code: code
            contents: contents

          Symfile.findOne(where: props, transaction: t).then (duplicate) ->
            p =
              if duplicate?
                duplicate.destroy(transaction: t)
              else
                Promise.resolve()
            p.then ->
              Symfile.create(props, transaction: t).then () ->
                query =
                  where: props
                  include: include
                  attributes:
                    exclude: exclude
                  transaction: t
                # Run findOne again to get the full object back with all references resolved
                Symfile.findOne(query).then (symfile) ->
                  Symfile.saveToDisk(symfile).then ->
                    cache.clear()
                    callback(null, symfile)

    .catch (err) ->
      callback err

  req.pipe(req.busboy)

module.exports = Symfile
