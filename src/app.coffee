config = require './config'
moment = require 'moment'
bodyParser = require 'body-parser'
methodOverride = require('method-override')
path = require 'path'
express = require 'express'
expressSession = require 'express-session'
exphbs = require 'express-handlebars'
hbsPaginate = require 'handlebars-paginate'
paginate = require 'express-paginate'
Crashreport = require './model/crashreport'
Symfile = require './model/symfile'
db = require './model/db'
titleCase = require 'title-case'
busboy = require 'connect-busboy'
streamToArray = require 'stream-to-array'
Sequelize = require 'sequelize'
addr = require 'addr'
crypto = require 'crypto'
passport = require 'passport'
passportLocal = require 'passport-local'

crashreportToApiJson = (crashreport) ->
  json = crashreport.toJSON()

  for k,v of json
    if Buffer.isBuffer(json[k])
      json[k] = "/crashreports/#{json.id}/files/#{k}"

  json

crashreportToViewJson = (report) ->
  hidden = ['id', 'updated_at']
  fields =
    id: report.id
    props: {}

  for name, value of Crashreport.attributes
    if value.type instanceof Sequelize.BLOB
      fields.props[name] = { path: "/crashreports/#{report.id}/files/#{name}" }

  json = report.toJSON()
  for k,v of json
    if k in hidden
      # pass
    else if Buffer.isBuffer(json[k])
      # already handled
    else if k == 'created_at'
      # change the name of this key for display purposes
      fields.props['created'] = moment(v).fromNow()
    else if v instanceof Date
      fields.props[k] = moment(v).fromNow()
    else
      fields.props[k] = if v? then v else 'not present'

  return fields

symfileToViewJson = (symfile) ->
  hidden = ['id', 'updated_at', 'contents']
  fields =
    id: symfile.id
    contents: symfile.contents
    props: {}

  json = symfile.toJSON()

  for k,v of json
    if k in hidden
      # pass
    else if k == 'created_at'
      # change the name of this key for display purposes
      fields.props['created'] = moment(v).fromNow()
    else if v instanceof Date
      fields.props[k] = moment(v).fromNow()
    else
      fields.props[k] = if v? then v else 'not present'

  return fields

# simple function to check if user is logged in
isLoggedIn = (req, res, next) ->
  return next() if !config.get('auth:enabled') || req.isAuthenticated()
  res.redirect("/login")

# initialization: init db and write all symfiles to disk
db.sync()
  .then ->
    Symfile.saveAllToDisk().then(run)
  .catch (err) ->
    console.error err.stack
    process.exit 1

run = ->
  app = express()
  breakpad = express()

  hbs = exphbs.create
    defaultLayout: 'main'
    partialsDir: path.resolve(__dirname, '..', 'views')
    layoutsDir: path.resolve(__dirname, '..', 'views', 'layouts')
    helpers:
      paginate: hbsPaginate
      reportUrl: (id) -> "/crashreports/#{id}"
      symfileUrl: (id) -> "/symfiles/#{id}"
      titleCase: titleCase

  breakpad.set 'json spaces', 2
  breakpad.set 'views', path.resolve(__dirname, '..', 'views')
  breakpad.engine('handlebars', hbs.engine)
  breakpad.set 'view engine', 'handlebars'
  breakpad.use bodyParser.json()
  breakpad.use bodyParser.urlencoded({extended: true})
  breakpad.use methodOverride()

  baseUrl = config.get('baseUrl')
  port = config.get('port')
  serverName = config.get('serverName')

  app.use baseUrl, breakpad

  bsStatic = path.resolve(__dirname, '..', 'node_modules/bootstrap/dist')
  breakpad.use '/assets', express.static(bsStatic)
  cssDirectory = path.resolve(__dirname, '..', 'views', 'css')
  breakpad.use '/css', express.static(cssDirectory)

  # error handler
  app.use (err, req, res, next) ->
    if not err.message?
      console.log 'warning: error thrown without a message'

    console.trace err
    res.status(500).send "Bad things happened:<br/> #{err.message || err}"

  breakpad.use(busboy())

  # Authentication
  if config.get('auth:enabled')
    staticUser = config.get('auth:username')
    staticPassword = config.get('auth:password')
    if !staticUser || !staticPassword
      throw new Error 'Authentication enabled but username or password not configured'

    passport.use new passportLocal.Strategy (username, password, done) ->
      # TODO change this to hit a database of users
      if username != staticUser
        done null, false
      if password != staticPassword
        done null, false
      done null, user: 'this is the user object'

    passport.serializeUser (user, callback) ->
      callback null, user

    passport.deserializeUser (user, callback) ->
      callback null, user

    sessionSecret = crypto.randomBytes(64).toString('hex')
    breakpad.use expressSession(secret: sessionSecret, resave: true, saveUninitialized: true)
    breakpad.use passport.initialize()
    breakpad.use passport.session()

  breakpad.post '/crashreports', (req, res, next) ->
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
        Crashreport.create(props).then (report) ->
          res.json(crashreportToApiJson(report))
      .catch (err) ->
        next err

    req.pipe(req.busboy)

  breakpad.get '/login', (req, res, next) ->
    res.render 'login',
      serverName: serverName
      layout: false

  breakpad.post '/auth', passport.authenticate("local", successRedirect:"/", failureRedirect:"/login")

  breakpad.get '/', isLoggedIn, (req, res, next) ->
    res.redirect '/crashreports'

  breakpad.use paginate.middleware(10, 50)
  breakpad.get '/crashreports', isLoggedIn, (req, res, next) ->
    limit = req.query.limit
    offset = req.offset
    page = req.query.page

    Crashreport.getAllReports limit, offset, (records, count) ->
      pageCount = Math.ceil(count / limit)
      viewReports = records.map(crashreportToViewJson)

      fields =
        if viewReports.length
          Object.keys(viewReports[0].props)
        else
          []

      res.render 'crashreport-index',
        serverName: serverName
        title: 'Crash Reports'
        crashreportsActive: yes
        records: viewReports
        fields: fields
        pagination:
          hide: pageCount <= 1
          page: page
          pageCount: pageCount

  breakpad.get '/symfiles', isLoggedIn, (req, res, next) ->
    limit = req.query.limit
    offset = req.offset
    page = req.query.page

    Symfile.getAllSymfiles limit, offset, (records, count) ->
      pageCount = Math.ceil(count / limit)
      viewSymfiles = records.map(symfileToViewJson)

      fields =
        if viewSymfiles.length
          Object.keys(viewSymfiles[0].props)
        else
          []

      res.render 'symfile-index',
        serverName: serverName
        title: 'Symfiles'
        symfilesActive: yes
        records: viewSymfiles
        fields: fields
        pagination:
          hide: pageCount <= 1
          page: page
          pageCount: pageCount

  breakpad.get '/symfiles/:id', isLoggedIn, (req, res, next) ->
    Symfile.findById(req.params.id).then (symfile) ->
      if not symfile?
        return res.send 404, 'Symfile not found'

      if 'raw' of req.query
        res.set 'content-type', 'text/plain'
        res.send(symfile.contents.toString())
        res.end()
      else
        res.render 'symfile-view', {
          serverName: serverName
          title: 'Symfile'
          symfile: symfileToViewJson(symfile)
        }

  breakpad.get '/crashreports/:id', isLoggedIn, (req, res, next) ->
    Crashreport.findById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        fields = crashreportToViewJson(report).props

        res.render 'crashreport-view', {
          serverName: serverName
          title: 'Crash Report'
          stackwalk: stackwalk
          product: fields.product
          version: fields.version
          fields: fields
        }

  breakpad.get '/crashreports/:id/stackwalk', isLoggedIn, (req, res, next) ->
    # give the raw stackwalk
    Crashreport.findById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        res.set('Content-Type', 'text/plain')
        res.send(stackwalk.toString('utf8'))

  breakpad.get '/crashreports/:id/files/:filefield', isLoggedIn, (req, res, next) ->
    # download the file for the given id
    Crashreport.findById(req.params.id).then (crashreport) ->
      if not crashreport?
        return res.status(404).send 'Crash report not found'

      field = req.params.filefield
      contents = crashreport.get(field)

      if not Buffer.isBuffer(contents)
        return res.status(404).send 'Crash report field is not a file'

      # Find appropriate downloadAs file name
      filename = config.get("customFields:filesById:#{field}:downloadAs") || field
      filename = filename.replace('{{id}}', req.params.id)

      res.setHeader('content-disposition', "attachment; filename=\"#{filename}\"")
      res.send(contents)

  breakpad.get '/api/crashreports', isLoggedIn, (req, res, next) ->
    # Query for a count of crash reports matching the requested query parameters
    # e.g. /api/crashreports?version=1.2.3
    where = {}
    for name, value of Crashreport.attributes
      unless value.type instanceof Sequelize.BLOB
        if req.query[name]
          where[name] = req.query[name]
    Crashreport.count({ where }).then (result) ->
      res.json
        count: result
    .error next


  breakpad.use(busboy())
  breakpad.post '/symfiles', (req, res, next) ->
    Symfile.createFromRequest req, res, (err, symfile) ->
      return next(err) if err?
      symfileJson = symfile.toJSON()
      delete symfileJson.contents
      res.json symfileJson

  app.listen port
  console.log "Listening on port #{port}"
