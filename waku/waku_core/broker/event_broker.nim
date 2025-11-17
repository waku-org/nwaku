## EventBroker
## -------------------
## EventBroker represents a reactive decoupling pattern, that
## allows defining event driven development without
## need of direct dependencies in between emitters and listeners.
## Worth consider using it in a single or many emitters to many listeners scenario.
##
## Generates a standalone, type-safe event broker for the declared object type.
## The macro exports the value type itself plus a broker companion that manages
## listeners via thread-local storage. Users can register async listeners with
## `TypeName.listen`, emit events with `TypeName.emit(...)`, and remove
## listeners through `forget`/`forgetAll` helpers on either the value type or the
## broker companion.
##
## Example:
## ```nim
## EventBroker:
##   type GreetingEvent = object
##     text*: string
##
## let handle = GreetingEvent.listen(
##   proc(evt: GreetingEvent): Future[void] {.async.} =
##     echo evt.text
## )
## GreetingEvent.emit(text: "hi")
## GreetingEvent.forget(handle)
## ```

import std/[macros, tables]
import chronos

proc sanitizeIdentName(node: NimNode): string =
  var raw = $node
  result = newStringOfCap(raw.len)
  for ch in raw:
    case ch
    of 'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_':
      result.add(ch)
    else:
      result.add('_')

proc ensureFieldDef(node: NimNode) =
  if node.kind != nnkIdentDefs or node.len < 3:
    error("Expected field definition of the form `name: Type`", node)
  let typeSlot = node.len - 2
  if node[typeSlot].kind == nnkEmpty:
    error("Field `" & $node[0] & "` must declare a type", node)

proc exportIdentNode(node: NimNode): NimNode =
  case node.kind
  of nnkIdent:
    postfix(copyNimTree(node), "*")
  of nnkPostfix:
    node
  else:
    error("Unsupported identifier form in field definition", node)

proc baseTypeIdent(defName: NimNode): NimNode =
  case defName.kind
  of nnkIdent:
    defName
  of nnkAccQuoted:
    if defName.len != 1:
      error("Unsupported quoted identifier", defName)
    defName[0]
  of nnkPostfix:
    baseTypeIdent(defName[1])
  of nnkPragmaExpr:
    baseTypeIdent(defName[0])
  else:
    error("Unsupported type name in EventBroker", defName)

macro EventBroker*(body: untyped): untyped =
  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        let rhs = def[2]
        if rhs.kind != nnkObjectTy:
          continue
        if not typeIdent.isNil:
          error("Only one object type may be declared inside EventBroker", def)
        typeIdent = baseTypeIdent(def[0])
        let recList = rhs[2]
        if recList.kind != nnkRecList:
          error("EventBroker object must declare a standard field list", rhs)
        var exportedRecList = newTree(nnkRecList)
        for field in recList:
          case field.kind
          of nnkIdentDefs:
            ensureFieldDef(field)
            var cloned = copyNimTree(field)
            for i in 0 ..< cloned.len - 2:
              cloned[i] = exportIdentNode(cloned[i])
            exportedRecList.add(cloned)
          of nnkEmpty:
            discard
          else:
            error(
              "EventBroker object definition only supports simple field declarations",
              field,
            )
        objectDef = newTree(
          nnkObjectTy, copyNimTree(rhs[0]), copyNimTree(rhs[1]), exportedRecList
        )
  if typeIdent.isNil:
    error("EventBroker body must declare exactly one object type", body)

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let sanitized = sanitizeIdentName(typeIdent)
  let handlerProcIdent = ident(sanitized & "ListenerProc")
  let listenerHandleIdent = ident(sanitized & "Listener")
  let brokerTypeIdent = ident(sanitized & "Broker")
  let exportedHandlerProcIdent = postfix(copyNimTree(handlerProcIdent), "*")
  let exportedListenerHandleIdent = postfix(copyNimTree(listenerHandleIdent), "*")
  let exportedBrokerTypeIdent = postfix(copyNimTree(brokerTypeIdent), "*")
  let accessProcIdent = ident("access" & sanitized & "Broker")
  let globalVarIdent = ident("g" & sanitized & "Broker")
  let listenImplIdent = ident("register" & sanitized & "Listener")
  let forgetImplIdent = ident("forget" & sanitized & "Listener")
  let forgetAllImplIdent = ident("forgetAll" & sanitized & "Listeners")
  let emitImplIdent = ident("emit" & sanitized & "Value")
  let listenerTaskIdent = ident("notify" & sanitized & "Listener")

  result = newStmtList()

  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedListenerHandleIdent` = object
          id*: uint64

        `exportedHandlerProcIdent` = proc(event: `typeIdent`): Future[void] {.gcsafe.}
        `exportedBrokerTypeIdent` = ref object
          listeners: Table[uint64, `handlerProcIdent`]
          nextId: uint64

  )

  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`
  )

  result.add(
    quote do:
      proc `accessProcIdent`(): `brokerTypeIdent` =
        if `globalVarIdent`.isNil:
          new(`globalVarIdent`)
          `globalVarIdent`.listeners = initTable[uint64, `handlerProcIdent`]()
        `globalVarIdent`

  )

  result.add(
    quote do:
      proc `listenImplIdent`(handler: `handlerProcIdent`): `listenerHandleIdent` =
        if handler.isNil:
          return `listenerHandleIdent`()
        var broker = `accessProcIdent`()
        if broker.nextId == 0'u64:
          broker.nextId = 1'u64
        let newId = broker.nextId
        inc broker.nextId
        broker.listeners[newId] = handler
        `listenerHandleIdent`(id: newId)

  )

  result.add(
    quote do:
      proc `forgetImplIdent`(handle: `listenerHandleIdent`) =
        if handle.id == 0'u64:
          return
        var broker = `accessProcIdent`()
        if broker.listeners.len == 0:
          return
        broker.listeners.del(handle.id)

  )

  result.add(
    quote do:
      proc `forgetAllImplIdent`() =
        var broker = `accessProcIdent`()
        if broker.listeners.len > 0:
          broker.listeners.clear()

  )

  result.add(
    quote do:
      proc listen*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): `listenerHandleIdent` =
        `listenImplIdent`(handler)

      proc listen*(
          _: typedesc[`brokerTypeIdent`], handler: `handlerProcIdent`
      ): `listenerHandleIdent` =
        `listenImplIdent`(handler)

  )

  result.add(
    quote do:
      proc forget*(_: typedesc[`typeIdent`], handle: `listenerHandleIdent`) =
        `forgetImplIdent`(handle)

      proc forget*(_: typedesc[`brokerTypeIdent`], handle: `listenerHandleIdent`) =
        `forgetImplIdent`(handle)

      proc forgetAll*(_: typedesc[`typeIdent`]) =
        `forgetAllImplIdent`()

      proc forgetAll*(_: typedesc[`brokerTypeIdent`]) =
        `forgetAllImplIdent`()

  )

  result.add(
    quote do:
      proc `listenerTaskIdent`(
          callback: `handlerProcIdent`, event: `typeIdent`
      ) {.async: (raises: [Exception]), gcsafe.} =
        if callback.isNil:
          return
        try:
          await callback(event)
        except CatchableError:
          discard

      proc `emitImplIdent`(
          event: `typeIdent`
      ): Future[void] {.async: (raises: [Exception]), gcsafe.} =
        let broker = `accessProcIdent`()
        if broker.listeners.len == 0:
          return
        var callbacks: seq[`handlerProcIdent`] = @[]
        for cb in broker.listeners.values:
          callbacks.add(cb)
        if callbacks.len == 0:
          return
        for cb in callbacks:
          asyncSpawn `listenerTaskIdent`(cb, event)

      proc emit*(event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(event)

      proc emit*(_: typedesc[`typeIdent`], event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(event)

      proc emit*(_: typedesc[`brokerTypeIdent`], event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(event)

      template emit*(_: typedesc[`typeIdent`], args: untyped): untyped =
        asyncSpawn `emitImplIdent`(`typeIdent`(args))

      template emit*(_: typedesc[`brokerTypeIdent`], args: untyped): untyped =
        asyncSpawn `emitImplIdent`(`typeIdent`(args))

  )

  when defined(eventBrokerDebug):
    echo result.repr
