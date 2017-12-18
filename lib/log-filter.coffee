{CompositeDisposable, Point} = require 'atom'
{Emitter} = require 'atom'

moment = require 'moment'
moment.createFromInputFallback = (config) ->
  config._d = new Date(config._i)

module.exports =
class LogFilter
  constructor: (@textEditor) ->
    @disposables = new CompositeDisposable
    @emitter = new Emitter

    @results =
      text: []
      levels: []
      times: []
      linesWithTimestamp: []

  onDidFinishFilter: (cb) -> @emitter.on 'did-finish-filter', cb

  destroy: ->
    @disposables.dispose()
    @removeFilter()
    @detach()

  getFilteredLines: (type) ->
    return res if res = @results[type]

    res = [@results.text..., @results.levels...]
    output = {}
    output[res[key]] = res[key] for key in [0...res.length]
    value for key, value of output

  getFilteredCount: ->
    @results.text.length + @results.levels.length

  performTextFilter: (text, scopes) ->
    return unless regexStage = @getRegexFromText('Log from branch')
    return unless regexFailures = @getRegexFromText('Failures\:')
    # return unless regexError = @getRegexFromText('\[[3][1]') #any red ansi color
    return unless regexError = @getRegexFromText('Error')
    return unless regexERROR = @getRegexFromText('ERROR:')
    return unless regexFailed = @getRegexFromText('Failed')
    return unless regexAt = @getRegexFromText('    at ')
    return unless regexNodeModules = @getRegexFromText('node_modules')
    return unless regexDomain = @getRegexFromText(atom.config.get 'language-log.stackTraceDomain')
    return unless buffer = @textEditor.getBuffer()

    if scopes?.length>0
      @results.text = for line, i in buffer.getLines()
        if  ('definition.log.log-verbose' not in scopes and (\
                regexStage.test(line) \
              ) \
            ) \
            or ('definition.log.log-debug' not in scopes and (\
                regexAt.test(line) \
                and regexDomain.test(line) \
                and not regexNodeModules.test(line) \
              ) \
            ) \
            or ('definition.log.log-info' not in scopes and (\
                regexFailed.test(line) \
              ) \
            ) \
            or ('definition.log.log-warning' not in scopes and (\
                regexFailures.test(line) or regexError.test(line) \
              ) \
            ) \
            or ('definition.log.log-error' not in scopes and (\
                regexERROR.test(line) \
              ) \
            ) \
            then else i

    else
      @results.text = for line, i in buffer.getLines()
          if regexStage.test(line) or regexFailures.test(line)  or regexERROR.test(line) or regexError.test(line) or regexFailed.test(line) or (regexAt.test(line) and not regexNodeModules.test(line) and regexDomain.test(line)) then else i

    # @results.text = @addAdjacentLines(@results.text)
    @filterLines()

  addAdjacentLines: (textResults) ->
    if adjLines = atom.config.get('language-log.adjacentLines')
      total = @textEditor.getLineCount()
      temp = []

      for lineNumber, lineIndex in textResults
        if (lineIndex + adjLines < textResults.length and lineNumber + adjLines >= textResults[lineIndex + adjLines]) or
           (lineIndex + adjLines >= textResults.length and (textResults.length - lineIndex) - (total - lineNumber) == 0)
          temp.push lineNumber

      textResults = temp.reverse()
      temp = []

      for lineNumber, lineIndex in textResults
        if (lineIndex + adjLines < textResults.length and lineNumber - adjLines <= textResults[lineIndex + adjLines]) or
           (lineIndex + adjLines >= textResults.length and 0 == (textResults.length - lineIndex) - (lineNumber + 1))
          temp.push lineNumber

      return temp.reverse()
    textResults

  performLevelFilter: (scopes) ->
    return unless buffer = @textEditor.getBuffer()

    return unless scopes
    grammar = @textEditor.getGrammar()

    @results.levels = for line, i in buffer.getLines()
      tokens = grammar.tokenizeLine(line)
      if @shouldFilterScopes(tokens, scopes) then i else
    @filterLines()

  # XXX: Based on experimental code for log line timestamp extraction
  performLinesWithTimestampFilter: ->
    return unless buffer = @textEditor.getBuffer()

    @results.linesWithTimestamp = for line, i in buffer.getLines()
      if !timestamp = @getLineTimestamp(i) then else i

  # XXX: Experimental log line timestamp extraction
  #      Not used in production
  performTimestampFilter: ->
    return unless buffer = @textEditor.getBuffer()

    for line, i in buffer.getLines()
      if timestamp = @getLineTimestamp(i)
        @results.times[i] = timestamp

  filterLines: ->
    lines = @getFilteredLines()

    @removeFilter()

    for line, i in lines
      if lines[i+1] isnt line + 1
        @foldLineRange(start or lines[0], line)
        start = lines[i+1]

    @emitter.emit 'did-finish-filter'

  foldLineRange: (start, end) ->
    return unless start? and end?

    # By default,as fallback case, we keep the safest possibility,
    # the fold start at the first character of the first line to fold
    actualStartLine = start
    actualStartColumn = 0
    foldPositionConfig = atom.config.get('language-log.foldPosition')
    if 'end-of-line' == foldPositionConfig
      # We fold at the end of the last filtered line
      # except if the first line to fold is the first line in the text editor
      actualStartLine = start-1
      actualStartColumn = 0
      if actualStartLine <= 0
        actualStartLine = 0
        actualStartColumn = 0
      else
        actualStartColumn = @textEditor.getBuffer().lineLengthForRow(actualStartLine)
    else if 'between-lines' == foldPositionConfig
      # The fold start at the first character of the first line to fold
      actualStartLine = start
      actualStartColumn = 0

    # We fold until the end of the last line to fold
    start = [actualStartLine, actualStartColumn]
    end = [end, @textEditor.getBuffer().lineLengthForRow(end)]
    @textEditor.setSelectedBufferRange([start, end])
    @textEditor.getSelections()[0].fold()

  shouldFilterScopes: (tokens, filterScopes) ->
    for tag in tokens.tags
      if scope = tokens.registry.scopeForId(tag)
        return true if filterScopes.indexOf(scope) isnt -1
    return false

  getRegexFromText: (text, ignoreCase) ->
    try
      regexpPattern = text
      regexpFlags = ''
      if text[0] is '!'
        regexpPattern = "^((?!#{text.substr(1)}).)*$"
      if atom.config.get('language-log.caseInsensitive') or ignoreCase
        regexpFlags += 'i'

      if regexpFlags
        return new RegExp(regexpPattern, regexpFlags)
      else
        return new RegExp(regexpPattern)

    catch error
      atom.notifications.addWarning('Log Language', detail: 'Invalid filter regex')
      return false

  removeFilter: ->
    @textEditor.unfoldAll()

  getLineTimestamp: (lineNumber) ->
    for pos in [0..30] by 10
      point = new Point(lineNumber, pos)
      # DEPRECATED
      # range = @textEditor.displayBuffer.bufferRangeForScopeAtPosition('timestamp', point)
      # REPLACEMENT
      @textEditor.setCursorBufferPosition(point)
      range = @textEditor.bufferRangeForScopeAtCursor('timestamp')

      if range and timestamp = @textEditor.getTextInRange(range)
        return @parseTimestamp(timestamp)

  parseTimestamp: (timestamp) ->
    regexes = [
      /^\d{6}[-\s]/
      /[0-9]{4}:[0-9]{2}/
      /[0-9]T[0-9]/
    ]

    # Remove invalid timestamp characters
    timestamp = timestamp.replace(/[\[\]]?/g, '')
    timestamp = timestamp.replace(/\,/g, '.')
    timestamp = timestamp.replace(/([A-Za-z]*|[-+][0-9]{4}|[-+][0-9]{2}:[0-9]{2})$/, '')

    # Rearrange string to valid timestamp format
    if part = timestamp.match(regexes[0])?[0]
      part = "20#{part.substr(0,2)}-#{part.substr(2,2)}-#{part.substr(4,2)} "
      timestamp = timestamp.replace(regexes[0], part)
    if timestamp.match(regexes[1])
      timestamp = timestamp.replace(':', ' ')
    if index = timestamp.indexOf(regexes[2]) isnt -1
      timestamp[index+1] = ' '

    # Very small matches are often false positive numbers
    return false if timestamp.length < 8

    time = moment(timestamp)
    # Timestamps without year defaults to 2001 - set to current year
    time.year(moment().year()) if time.year() is 2001
    time
