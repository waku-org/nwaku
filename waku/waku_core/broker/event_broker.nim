## EventBroker
## -------------------
## EventBroker represents a reactive decoupling pattern, that
## allows event-driven development without
## need for direct dependencies in between emitters and listeners.
## Worth considering using it in a single or many emitters to many listeners scenario.
##
## Generates a standalone, type-safe event broker for the declared object type.
## The macro exports the value type itself plus a broker companion that manages
## listeners via thread-local storage.
##
## Usage:
## Declare your desired event type inside an `EventBroker` macro, add any number of fields.:
## ```nim
## EventBroker:
##   type TypeName = object
##     field1*: FieldType
##     field2*: AnotherFieldType
## ```
##
## After this, you can register async listeners anywhere in your code with
## `TypeName.listen(...)`, which returns a handle to the registered listener.
## Listeners are async procs or lambdas that take a single argument of the event type.
## Any number of listeners can be registered in different modules.
##
## Events can be emitted from anywhere with no direct dependency on the listeners by
## calling `TypeName.emit(...)` with an instance of the event type.
## This will asynchronously notify all registered listeners with the emitted event.
##
## Whenever you no longer need a listener (or your object instance that listen to the event goes out of scope),
## you can remove it from the broker with the handle returned by `listen`.
## This is done by calling `TypeName.dropListener(handle)`.
## Alternatively, you can remove all registered listeners through `TypeName.dropAllListeners()`.
##
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
## GreetingEvent.dropListener(handle)
## ```

import std/[macros, tables]
import chronos, chronicles, results
import ./helper/broker_utils

export chronicles, results, chronos

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
        if not typeIdent.isNil():
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
  if typeIdent.isNil():
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
  let dropListenerImplIdent = ident("drop" & sanitized & "Listener")
  let dropAllListenersImplIdent = ident("dropAll" & sanitized & "Listeners")
  let emitImplIdent = ident("emit" & sanitized & "Value")
  let listenerTaskIdent = ident("notify" & sanitized & "Listener")

  result = newStmtList()

  result.add(
    quote do:
      type
        `exportedTypeIdent` = `objectDef`
        `exportedListenerHandleIdent` = object
          id*: uint64

        `exportedHandlerProcIdent` =
          proc(event: `typeIdent`): Future[void] {.async: (raises: []), gcsafe.}
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
        if `globalVarIdent`.isNil():
          new(`globalVarIdent`)
          `globalVarIdent`.listeners = initTable[uint64, `handlerProcIdent`]()
        `globalVarIdent`

  )

  result.add(
    quote do:
      proc `listenImplIdent`(
          handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        if handler.isNil():
          return err("Must provide a non-nil event handler")
        var broker = `accessProcIdent`()
        if broker.nextId == 0'u64:
          broker.nextId = 1'u64
        if broker.nextId == high(uint64):
          error "Cannot add more listeners: ID space exhausted", nextId = $broker.nextId
          return err("Cannot add more listeners, listener ID space exhausted")
        let newId = broker.nextId
        inc broker.nextId
        broker.listeners[newId] = handler
        return ok(`listenerHandleIdent`(id: newId))

  )

  result.add(
    quote do:
      proc `dropListenerImplIdent`(handle: `listenerHandleIdent`) =
        if handle.id == 0'u64:
          return
        var broker = `accessProcIdent`()
        if broker.listeners.len == 0:
          return
        broker.listeners.del(handle.id)

  )

  result.add(
    quote do:
      proc `dropAllListenersImplIdent`() =
        var broker = `accessProcIdent`()
        if broker.listeners.len > 0:
          broker.listeners.clear()

  )

  result.add(
    quote do:
      proc listen*(
          _: typedesc[`typeIdent`], handler: `handlerProcIdent`
      ): Result[`listenerHandleIdent`, string] =
        return `listenImplIdent`(handler)

  )

  result.add(
    quote do:
      proc dropListener*(_: typedesc[`typeIdent`], handle: `listenerHandleIdent`) =
        `dropListenerImplIdent`(handle)

      proc dropAllListeners*(_: typedesc[`typeIdent`]) =
        `dropAllListenersImplIdent`()

  )

  result.add(
    quote do:
      proc `listenerTaskIdent`(
          callback: `handlerProcIdent`, event: `typeIdent`
      ) {.async: (raises: []), gcsafe.} =
        if callback.isNil():
          return
        try:
          await callback(event)
        except Exception:
          error "Failed to execute event listener", error = getCurrentExceptionMsg()

      proc `emitImplIdent`(
          event: `typeIdent`
      ): Future[void] {.async: (raises: []), gcsafe.} =
        let broker = `accessProcIdent`()
        if broker.listeners.len == 0:
          # nothing to do as nobody is listening
          return
        var callbacks: seq[`handlerProcIdent`] = @[]
        for cb in broker.listeners.values:
          callbacks.add(cb)
        for cb in callbacks:
          asyncSpawn `listenerTaskIdent`(cb, event)

      proc emit*(event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(event)

      proc emit*(_: typedesc[`typeIdent`], event: `typeIdent`) =
        asyncSpawn `emitImplIdent`(event)

      template emit*(_: typedesc[`typeIdent`], args: untyped): untyped =
        asyncSpawn `emitImplIdent`(`typeIdent`(args))

  )

  when defined(eventBrokerDebug):
    echo result.repr
