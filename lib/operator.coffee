# Refactoring status: 80%
_ = require 'underscore-plus'
{Point, Range, CompositeDisposable} = require 'atom'

{haveSomeSelection} = require './utils'
swrap = require './selection-wrapper'
settings = require './settings'
Base = require './base'

class OperatorError extends Base
  @extend(false)
  constructor: (@message) ->
    @name = 'Operator Error'

# General Operator
# -------------------------
class Operator extends Base
  @extend(false)
  recordable: true
  target: null
  flashTarget: true
  trackChange: false
  requireTarget: true

  activate: (mode, submode) ->
    @onDidOperationFinish =>
      @vimState.activate(mode, submode)

  setMarkForChange: ({start, end}) ->
    @vimState.mark.set('[', start)
    @vimState.mark.set(']', end)

  haveSomeSelection: ->
    haveSomeSelection(@editor.getSelections())

  isSameOperatorRepeated: ->
    if @vimState.isMode('operator-pending')
      @vimState.operationStack.peekTop().constructor is @constructor
    else
      false

  needFlash: ->
    @flashTarget and settings.get('flashOnOperate')

  needTrackChange: ->
    @trackChange

  needStay: ->
    param = if @instanceof('TransformString')
      "stayOnTransformString"
    else
      "stayOn#{@constructor.name}"
    settings.get(param) or (@stayOnLinewise and @target.isLinewise?())

  constructor: ->
    super
    # Guard when Repeated.
    return if @instanceof("Repeat")

    @setTarget @new(@target) if @target?
    #  To support, `dd`, `cc` and a like.
    if @isSameOperatorRepeated()
      @vimState.operationStack.run 'MoveToRelativeLine'
      @abort()
    @initialize?()

  observeSelectAction: ->
    if @needFlash()
      @onDidSelect =>
        @flash @editor.getSelectedBufferRanges()

    if @needTrackChange()
      changeMarker = null
      @onDidSelect =>
        range = @editor.getSelectedBufferRange()
        changeMarker = @editor.markBufferRange range,
          invalidate: 'never'
          persistent: false

      @onDidOperationFinish =>
        if newRange = changeMarker.getBufferRange()
          @setMarkForChange(newRange)

  # target - TextObject or Motion to operate on.
  setTarget: (@target) ->
    unless _.isFunction(@target.select)
      @vimState.emitter.emit('did-fail-to-set-target')
      targetName = @target.constructor.name
      operatorName = @constructor.name
      message = "Failed to set '#{targetName}' as target for Operator '#{operatorName}'"
      throw new OperatorError(message)

    if _.isFunction(@target.onDidComposeBy)
      @target.onDidComposeBy(this)

  selectTarget: (force=false) ->
    @observeSelectAction()
    @emitWillSelect()
    if @haveSomeSelection() and not force
      @emitDidSelect()
      true
    else
      @target.select()
      @haveSomeSelection()

  setTextToRegister: (text) ->
    if @target?.isLinewise?() and not text.endsWith('\n')
      text += "\n"
    if text
      @vimState.register.set({text})

  flash: (range) ->
    if @flashTarget and settings.get('flashOnOperate')
      @vimState.flasher.flash range,
        class: 'vim-mode-plus-flash'
        timeout: settings.get('flashOnOperateDuration')

  preservePoints: ({asMarker}={}) ->
    points = _.pluck(@editor.getSelectedBufferRanges(), 'start')
    asMarker ?= false
    if asMarker
      options = {invalidate: 'never', persistent: false}
      markers = @editor.getCursorBufferPositions().map (point) =>
        @editor.markBufferPosition point, options
      ({cursor}, i) ->
        point = markers[i].getStartBufferPosition()
        cursor.setBufferPosition(point)
    else
      ({cursor}, i) ->
        cursor.setBufferPosition(points[i])

  eachSelection: (fn) ->
    setPoint = null
    if @needStay()
      @onWillSelect => setPoint = @preservePoints(@stayOption)
    else
      @onDidSelect => setPoint = @preservePoints()
    return unless @selectTarget()
    @editor.transact =>
      for selection, i in @editor.getSelections()
        fn(selection, setPoint.bind(this, selection, i))

class Select extends Operator
  @extend(false)
  flashTarget: false
  execute: ->
    @selectTarget(true)

class Delete extends Operator
  @extend()
  hover: icon: ':delete:', emoji: ':scissors:'
  trackChange: true
  flashTarget: false
  execute: ->
    @eachSelection (s) =>
      @setTextToRegister s.getText() if s.isLastSelection()
      s.deleteSelectedText()
      s.cursor.skipLeadingWhitespace() if @target.isLinewise?()
    @activate('normal')

class DeleteRight extends Delete
  @extend()
  target: 'MoveRight'

class DeleteLeft extends Delete
  @extend()
  target: 'MoveLeft'

class DeleteToLastCharacterOfLine extends Delete
  @extend()
  target: 'MoveToLastCharacterOfLine'

class TransformString extends Operator
  @extend(false)
  trackChange: true
  stayOnLinewise: true
  setPoint: true

  execute: ->
    @eachSelection (s, setPoint) =>
      @mutate(s, setPoint)
    @activate('normal')

  mutate: (s, setPoint) ->
    text = @getNewText(s.getText())
    s.insertText(text)
    setPoint() if @setPoint

class ToggleCase extends TransformString
  @extend()
  hover: icon: ':toggle-case:', emoji: ':clap:'
  toggleCase: (char) ->
    if (charLower = char.toLowerCase()) is char
      char.toUpperCase()
    else
      charLower

  getNewText: (text) ->
    text.split('').map(@toggleCase).join('')

class ToggleCaseAndMoveRight extends ToggleCase
  @extend()
  hover: null
  setPoint: false
  target: 'MoveRight'

class UpperCase extends TransformString
  @extend()
  hover: icon: ':upper-case:', emoji: ':point_up:'
  getNewText: (text) ->
    text.toUpperCase()

class LowerCase extends TransformString
  @extend()
  hover: icon: ':lower-case:', emoji: ':point_down:'
  getNewText: (text) ->
    text.toLowerCase()

class CamelCase extends TransformString
  @extend()
  hover: icon: ':camel-case:', emoji: ':camel:'
  getNewText: (text) ->
    _.camelize text

class SnakeCase extends TransformString
  @extend()
  hover: icon: ':snake-case:', emoji: ':snake:'
  getNewText: (text) ->
    _.underscore text

class DashCase extends TransformString
  @extend()
  hover: icon: ':dash-case:', emoji: ':dash:'
  getNewText: (text) ->
    _.dasherize text

class ReplaceWithRegister extends TransformString
  @extend()
  hover: icon: ':replace-with-register:', emoji: ':pencil:'
  getNewText: (text) ->
    @vimState.register.getText()

class Indent extends TransformString
  @extend()
  hover: icon: ':indent:', emoji: ':point_right:'
  stayOnLinewise: false

  mutate: (s, setPoint) ->
    @indent(s)
    setPoint()
    unless @needStay()
      s.cursor.moveToFirstCharacterOfLine()

  indent: (s) ->
    s.indentSelectedRows()

class Outdent extends Indent
  @extend()
  hover: icon: ':outdent:', emoji: ':point_left:'
  indent: (s) ->
    s.outdentSelectedRows()

class AutoIndent extends Indent
  @extend()
  hover: icon: ':auto-indent:', emoji: ':open_hands:'
  indent: (s) ->
    s.autoIndentSelectedRows()

class ToggleLineComments extends TransformString
  @extend()
  hover: icon: ':toggle-line-comment:', emoji: ':mute:'
  stayOption: {asMarker: true}
  mutate: (s, setPoint) ->
    s.toggleLineComments()
    setPoint()

class Surround extends TransformString
  @extend()
  pairs: ['[]', '()', '{}', '<>']
  input: null
  charsMax: 1
  hover: icon: ':surround:', emoji: ':two_women_holding_hands:'
  requireInput: true

  initialize: ->
    return unless @requireInput
    @onDidConfirmInput (input) => @onConfirm(input)
    @onDidChangeInput (input) => @vimState.hover.add(input)
    @onDidCancelInput => @vimState.operationStack.cancel()
    @vimState.input.focus({@charsMax})

  onConfirm: (@input) ->
    @vimState.operationStack.process()

  getPair: (input) ->
    pair = _.detect @pairs, (pair) -> input in pair
    pair ?= input + input

  surround: (text, pair) ->
    [open, close] = pair.split('')
    open + text + close

  getNewText: (text) ->
    @surround text, @getPair(@input)

class SurroundWord extends Surround
  @extend()
  target: 'Word'

class DeleteSurround extends Surround
  @extend()
  pairChars: ['[]', '()', '{}'].join('')

  onConfirm: (@input) ->
    # FIXME: dont manage allowNextLine independently. Each Pair text-object can handle by themselvs.
    target = @new 'Pair',
      pair: @getPair(@input)
      inclusive: true
      allowNextLine: @input in @pairChars
    @setTarget(target)
    @vimState.operationStack.process()

  getNewText: (text) ->
    text[1...-1]

class DeleteSurroundAnyPair extends DeleteSurround
  @extend()
  requireInput: false
  target: 'AAnyPair'

class ChangeSurround extends DeleteSurround
  @extend()
  charsMax: 2
  char: null

  onConfirm: (input) ->
    return unless input
    [from, @char] = input.split('')
    super(from)

  getNewText: (text) ->
    @surround super(text), @getPair(@char)

class ChangeSurroundAnyPair extends ChangeSurround
  @extend()
  charsMax: 1
  target: "AAnyPair"

  initialize: ->
    @restore = @preservePoints()
    @target.select()
    unless @haveSomeSelection()
      @vimState.reset()
      @abort()
    @vimState.hover.add(@editor.getSelectedText()[0])
    super

  onConfirm: (@char) ->
    # Clear pre-selected selection to start @eachSelection from non-selection.
    @restore(s, i) for s, i in @editor.getSelections()
    @input = @char
    @vimState.operationStack.process()

class Yank extends Operator
  @extend()
  hover: icon: ':yank:', emoji: ':clipboard:'
  trackChange: true
  stayOnLinewise: true

  execute: ->
    @eachSelection (s, setPoint) =>
      @setTextToRegister s.getText() if s.isLastSelection()
      setPoint()
    @activate('normal')

class YankLine extends Yank
  @extend()
  target: 'MoveToRelativeLine'

# FIXME
# Currently native editor.joinLines() is better for cursor position setting
# So I use native methods for a meanwhile.
class Join extends Operator
  @extend()
  requireTarget: false
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        @editor.joinLines()
    @activate('normal')

class JoinWithKeepingSpace extends TransformString
  @extend()
  input: ''
  requireTarget: false
  trim: false
  initialize: ->
    @setTarget @new("MoveToRelativeLineWithMinimum", {min: 1})

  mutate: (s) ->
    [startRow, endRow] = s.getBufferRowRange()
    swrap(s).expandOverLine()
    rows = for row in [startRow..endRow]
      text = @editor.lineTextForBufferRow(row)
      if @trim and row isnt startRow
        text.trimLeft()
      else
        text
    s.insertText @join(rows) + "\n"

  join: (rows) ->
    rows.join(@input)

class JoinByInput extends JoinWithKeepingSpace
  @extend()
  hover: icon: ':join:', emoji: ':couple:'
  requireInput: true
  input: null
  trim: true
  initialize: ->
    @onDidChangeInput (input) =>
      @vimState.hover.add(input[-1..])
    @focusInput(charsMax: 10)

  join: (rows) ->
    rows.join(" #{@input} ")

class JoinByInputWithKeepingSpace extends JoinByInput
  @extend()
  trim: false
  join: (rows) ->
    rows.join(@input)

class Split extends TransformString
  @extend()
  hover: icon: ':split:', emoji: ':hocho:'
  requireInput: true
  input: null
  initialize: ->
    @onDidChangeInput (input) =>
      @vimState.hover.add(input[-1..])
    @focusInput(charsMax: 10)

  isComplete: ->
    @input = "\\n" if @input is ''
    super

  getNewText: (text) ->
    regex = ///#{_.escapeRegExp(@input)}///g
    text.split(regex).join("\n")

class Repeat extends Operator
  @extend()
  requireTarget: false
  recordable: false
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        if op = @vimState.operationStack.getRecorded()
          op.setRepeated()
          op.execute()

class Mark extends Operator
  @extend()
  hover: icon: ':mark:', emoji: ':round_pushpin:'
  requireInput: true
  requireTarget: false
  initialize: ->
    @focusInput()

  execute: ->
    @vimState.mark.set(@input, @editor.getCursorBufferPosition())
    @activate('normal')

# [FIXME?]: inconsistent behavior from normal operator
# Since its support visual-mode but not use setTarget() convension.
# Maybe separating complete/in-complete version like IncreaseNow and Increase?
class Increase extends Operator
  @extend()
  requireTarget: false
  step: 1

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g

    newRanges = []
    @editor.transact =>
      for c in @editor.getCursors()
        scanRange = if @vimState.isMode('visual')
          c.selection.getBufferRange()
        else
          c.getCurrentLineBufferRange()
        ranges = @increaseNumber(c, scanRange, pattern)
        if not @vimState.isMode('visual') and ranges.length
          c.setBufferPosition ranges[0].end.translate([0, -1])
        newRanges.push ranges

    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()

  increaseNumber: (cursor, scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, range, stop, replace}) =>
      newText = String(parseInt(matchText, 10) + @step * @getCount())
      if @vimState.isMode('visual')
        newRanges.push replace(newText)
      else
        return unless range.end.isGreaterThan cursor.getBufferPosition()
        newRanges.push replace(newText)
        stop()
    newRanges

class Decrease extends Increase
  @extend()
  step: -1

class IncrementNumber extends Operator
  @extend()
  step: 1
  baseNumber: null

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g
    newRanges = null
    @selectTarget()
    @editor.transact =>
      newRanges = for s in @editor.getSelectionsOrderedByBufferPosition()
        @replaceNumber(s.getBufferRange(), pattern)
    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()
    # Reverseing selection put cursor on start position of selection.
    # This allow increment/decrement works in same target range when repeated.
    swrap.setReversedState(@editor, true)
    @activate('normal')

  replaceNumber: (scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, replace}) =>
      newRanges.push replace(@getNewText(matchText))
    newRanges

  getNewText: (text) ->
    @baseNumber = if @baseNumber?
      @baseNumber + @step * @getCount()
    else
      parseInt(text, 10)
    String(@baseNumber)

class DecrementNumber extends IncrementNumber
  @extend()
  step: -1

# Put
# -------------------------
class PutBefore extends Operator
  @extend()
  requireTarget: false
  location: 'before'

  execute: ->
    {text, type} = @vimState.register.get()
    return unless text
    text = _.multiplyString(text, @getCount())
    isLinewise = type is 'linewise' or @vimState.isMode('visual', 'linewise')

    @editor.transact =>
      for s in @editor.getSelections()
        {cursor} = s
        if isLinewise
          newRange = @pasteLinewise(s, text)
          cursor.setBufferPosition(newRange.start)
          cursor.moveToFirstCharacterOfLine()
        else
          newRange = @pasteCharacterwise(s, text)
          cursor.setBufferPosition(newRange.end.translate([0, -1]))
        @setMarkForChange(newRange)
        @flash newRange
    @activate('normal')

  # Return newRange
  pasteLinewise: (selection, text) ->
    {cursor} = selection
    if selection.isEmpty()
      text = text.replace(/\n$/, '')
      if @location is 'before'
        @insertTextAbove(selection, text)
      else
        @insertTextBelow(selection, text)
    else
      if @vimState.isMode('visual', 'linewise')
        text += '\n' unless text.endsWith('\n')
      else
        selection.insertText("\n")
      selection.insertText(text)

  pasteCharacterwise: (selection, text) ->
    if @location is 'after' and selection.isEmpty()
      selection.cursor.moveRight()
    selection.insertText(text)

  insertTextAbove: (selection, text) ->
    selection.cursor.moveToBeginningOfLine()
    selection.insertText("\n")
    selection.cursor.moveUp()
    selection.insertText(text)

  insertTextBelow: (selection, text) ->
    selection.cursor.moveToEndOfLine()
    selection.insertText("\n")
    selection.insertText(text)

class PutAfter extends PutBefore
  @extend()
  location: 'after'

# Replace
# -------------------------
# [FIXME] need rewrite
class Replace extends Operator
  @extend()
  input: null
  hover: icon: ':replace:', emoji: ':tractor:'
  trackChange: true
  requireInput: true
  requireTarget: false

  initialize: ->
    @focusInput()

  isComplete: ->
    @input = "\n" if @input is ''
    super

  execute: ->
    count = @getCount()

    @editor.transact =>
      if @target?
        if @selectTarget()
          @editor.replaceSelectedText null, (text) =>
            text.replace(/./g, @input)
          for selection in @editor.getSelections()
            point = selection.getBufferRange().start
            selection.setBufferRange(Range.fromPointWithDelta(point, 0, 0))
      else
        for cursor in @editor.getCursors()
          pos = cursor.getBufferPosition()
          currentRowLength = @editor.lineTextForBufferRow(pos.row).length
          continue unless currentRowLength - pos.column >= count

          _.times count, =>
            point = cursor.getBufferPosition()
            @editor.setTextInBufferRange(Range.fromPointWithDelta(point, 0, 1), @input)
            cursor.moveRight()
          cursor.setBufferPosition(pos)

        # Special case: when replaced with a newline move to the start of the
        # next row.
        if @input is "\n"
          _.times count, =>
            @editor.moveDown()
          @editor.moveToFirstCharacterOfLine()

    @activate('normal')

# Insert entering operation
# -------------------------
class ActivateInsertMode extends Operator
  @extend()
  requireTarget: false
  flashTarget: false
  checkpoint: null
  submode: null

  initialize: ->
    @checkpoint = {}
    @setCheckpoint('undo') unless @isRepeated()

  # we have to manage two separate checkpoint for different purpose(timing is different)
  # - one for undo(handled by modeManager)
  # - one for preserve last inserted text
  setCheckpoint: (purpose) ->
    @checkpoint[purpose] = @editor.createCheckpoint()

  getCheckpoint: ->
    @checkpoint

  getText: ->
    @vimState.register.getText('.')

  # called when repeated
  repeatInsert: (selection, text) ->
    selection.insertText(text, autoIndent: true)

  execute: ->
    if @isRepeated()
      return unless text = @getText()
      @flashTarget = @trackChange = true
      @observeSelectAction()
      @emitDidSelect()
      @editor.transact =>
        for s in @editor.getSelections()
          @repeatInsert(s, text)
          s.cursor.moveLeft() unless s.cursor.isAtBeginningOfLine()
    else
      @setCheckpoint('insert')
      @vimState.activate('insert', @submode)

class InsertAtLastInsert extends ActivateInsertMode
  @extend()
  execute: ->
    if (point = @vimState.mark.get('^'))
      @editor.setCursorBufferPosition(point)
      @editor.scrollToCursorPosition({center: true})
    super

class ActivateReplaceMode extends ActivateInsertMode
  @extend()
  submode: 'replace'

  repeatInsert: (selection, text) ->
    for char in text when char isnt "\n"
      break if selection.cursor.isAtEndOfLine()
      selection.selectRight()
    selection.insertText(text, autoIndent: false)

class InsertAfter extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveRight() unless @editor.getLastCursor().isAtEndOfLine()
    super

class InsertAfterEndOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToEndOfLine()
    super

class InsertAtBeginningOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToFirstCharacterOfLine()
    super

# FIXME need support count
class InsertAboveWithNewline extends ActivateInsertMode
  @extend()
  execute: ->
    @insertNewline()
    super

  insertNewline: ->
    @editor.insertNewlineAbove()

  repeatInsert: (selection, text) ->
    selection.insertText(text.trimLeft(), autoIndent: true)

class InsertBelowWithNewline extends InsertAboveWithNewline
  @extend()
  insertNewline: ->
    @editor.insertNewlineBelow()

class Change extends ActivateInsertMode
  @extend()
  requireTarget: true
  trackChange: true

  execute: ->
    @target.setOptions?(excludeWhitespace: true)
    if @selectTarget()
      @setTextToRegister @editor.getSelectedText()
      text = if @target.isLinewise?() then "\n" else ""
      for s in @editor.getSelections()
        range = s.insertText(text, autoIndent: true)
        s.cursor.moveLeft() unless range.isEmpty()
    super

class Substitute extends Change
  @extend()
  target: 'MoveRight'

class SubstituteLine extends Change
  @extend()
  target: 'MoveToRelativeLine'

class ChangeToLastCharacterOfLine extends Change
  @extend()
  target: 'MoveToLastCharacterOfLine'
