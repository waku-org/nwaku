## RequestBroker
## --------------------
## RequestBroker represents a proactive decoupling pattern, that
## allows defining request-response style interactions between modules without
## need for direct dependencies in between.
## Worth considering using it in a single provider, many requester scenario.
##
## Provides a declarative way to define an immutable value type together with a
## thread-local broker that can register an asynchronous provider, dispatch typed
## requests and clear provider.
##
## Usage:
## Declare your desired request type inside a `RequestBroker` macro, add any number of fields.
## Define the provider signature, that is enforced at compile time.
##
## ```nim
## RequestBroker:
##   type TypeName = object
##     field1*: FieldType
##     field2*: AnotherFieldType
##
##   proc signature*(): Future[Result[TypeName, string]]
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(arg1: ArgType, arg2: AnotherArgType): Future[Result[TypeName, string]]
##
## ```
## The 'TypeName' object defines the requestable data (but also can be seen as request for action with return value).
## The 'signature' proc defines the provider(s) signature, that is enforced at compile time.
## One signature can be with no arguments, another with any number of arguments - where the input arguments are
## not related to the request type - but alternative inputs for the request to be processed.
##
## After this, you can register a provider anywhere in your code with
## `TypeName.setProvider(...)`, which returns error if already having a provider.
## Providers are async procs or lambdas that take no arguments and return a Future[Result[TypeName, string]].
## Only one provider can be registered at a time per signature type (zero arg and/or multi arg).
##
## Requests can be made from anywhere with no direct dependency on the provider by
## calling `TypeName.request()` - with arguments respecting the signature(s).
## This will asynchronously call the registered provider and return a Future[Result[TypeName, string]].
##
## Whenever you no want to process requests (or your object instance that provides the request goes out of scope),
## you can remove it from the broker with `TypeName.clearProvider()`.
##
##
## Example:
## ```nim
## RequestBroker:
##   type Greeting = object
##     text*: string
##
##   ## Define the request and provider signature, that is enforced at compile time.
##   proc signature*(): Future[Result[Greeting, string]]
##
##   ## Also possible to define signature with arbitrary input arguments.
##   proc signature*(lang: string): Future[Result[Greeting, string]]
##
## ...
## Greeting.setProvider(
##   proc(): Future[Result[Greeting, string]] {.async.} =
##     ok(Greeting(text: "hello"))
## )
## let res = await Greeting.request()
## ```
## If no `signature` proc is declared, a zero-argument form is generated
## automatically, so the caller only needs to provide the type definition.

import std/[macros, strutils]
import chronos
import results
import ./helper/broker_utils

export results, chronos

proc errorFuture[T](message: string): Future[Result[T, string]] {.inline.} =
  ## Build a future that is already completed with an error result.
  let fut = newFuture[Result[T, string]]("request_broker.errorFuture")
  fut.complete(err(Result[T, string], message))
  fut

proc isReturnTypeValid(returnType, typeIdent: NimNode): bool =
  ## Accept Future[Result[TypeIdent, string]] as the contract.
  if returnType.kind != nnkBracketExpr or returnType.len != 2:
    return false
  if returnType[0].kind != nnkIdent or not returnType[0].eqIdent("Future"):
    return false
  let inner = returnType[1]
  if inner.kind != nnkBracketExpr or inner.len != 3:
    return false
  if inner[0].kind != nnkIdent or not inner[0].eqIdent("Result"):
    return false
  if inner[1].kind != nnkIdent or not inner[1].eqIdent($typeIdent):
    return false
  inner[2].kind == nnkIdent and inner[2].eqIdent("string")

proc cloneParams(params: seq[NimNode]): seq[NimNode] =
  ## Deep copy parameter definitions so they can be inserted in multiple places.
  result = @[]
  for param in params:
    result.add(copyNimTree(param))

proc collectParamNames(params: seq[NimNode]): seq[NimNode] =
  ## Extract all identifier symbols declared across IdentDefs nodes.
  result = @[]
  for param in params:
    assert param.kind == nnkIdentDefs
    for i in 0 ..< param.len - 2:
      let nameNode = param[i]
      if nameNode.kind == nnkEmpty:
        continue
      result.add(ident($nameNode))

proc makeProcType(returnType: NimNode, params: seq[NimNode]): NimNode =
  var formal = newTree(nnkFormalParams)
  formal.add(returnType)
  for param in params:
    formal.add(param)
  let pragmas = newTree(nnkPragma, ident("async"))
  newTree(nnkProcTy, formal, pragmas)

macro RequestBroker*(body: untyped): untyped =
  when defined(requestBrokerDebug):
    echo body.treeRepr
  var typeIdent: NimNode = nil
  var objectDef: NimNode = nil
  var isRefObject = false
  for stmt in body:
    if stmt.kind == nnkTypeSection:
      for def in stmt:
        if def.kind != nnkTypeDef:
          continue
        let rhs = def[2]
        var objectType: NimNode
        case rhs.kind
        of nnkObjectTy:
          objectType = rhs
        of nnkRefTy:
          isRefObject = true
          if rhs.len != 1 or rhs[0].kind != nnkObjectTy:
            error(
              "RequestBroker ref object must wrap a concrete object definition", rhs
            )
          objectType = rhs[0]
        else:
          continue
        if not typeIdent.isNil():
          error("Only one object type may be declared inside RequestBroker", def)
        typeIdent = baseTypeIdent(def[0])
        let recList = objectType[2]
        if recList.kind != nnkRecList:
          error("RequestBroker object must declare a standard field list", objectType)
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
              "RequestBroker object definition only supports simple field declarations",
              field,
            )
        let exportedObjectType = newTree(
          nnkObjectTy,
          copyNimTree(objectType[0]),
          copyNimTree(objectType[1]),
          exportedRecList,
        )
        if isRefObject:
          objectDef = newTree(nnkRefTy, exportedObjectType)
        else:
          objectDef = exportedObjectType
  if typeIdent.isNil():
    error("RequestBroker body must declare exactly one object type", body)

  when defined(requestBrokerDebug):
    echo "RequestBroker generating type: ", $typeIdent

  let exportedTypeIdent = postfix(copyNimTree(typeIdent), "*")
  let typeDisplayName = sanitizeIdentName(typeIdent)
  let typeNameLit = newLit(typeDisplayName)
  let isRefObjectLit = newLit(isRefObject)
  var zeroArgSig: NimNode = nil
  var zeroArgProviderName: NimNode = nil
  var zeroArgFieldName: NimNode = nil
  var argSig: NimNode = nil
  var argParams: seq[NimNode] = @[]
  var argProviderName: NimNode = nil
  var argFieldName: NimNode = nil

  for stmt in body:
    case stmt.kind
    of nnkProcDef:
      let procName = stmt[0]
      let procNameIdent =
        case procName.kind
        of nnkIdent:
          procName
        of nnkPostfix:
          procName[1]
        else:
          procName
      let procNameStr = $procNameIdent
      if not procNameStr.startsWith("signature"):
        error("Signature proc names must start with `signature`", procName)
      let params = stmt.params
      if params.len == 0:
        error("Signature must declare a return type", stmt)
      let returnType = params[0]
      if not isReturnTypeValid(returnType, typeIdent):
        error(
          "Signature must return Future[Result[`" & $typeIdent & "`, string]]", stmt
        )
      let paramCount = params.len - 1
      if paramCount == 0:
        if zeroArgSig != nil:
          error("Only one zero-argument signature is allowed", stmt)
        zeroArgSig = stmt
        zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
        zeroArgFieldName = ident("providerNoArgs")
      elif paramCount >= 1:
        if argSig != nil:
          error("Only one argument-based signature is allowed", stmt)
        argSig = stmt
        argParams = @[]
        for idx in 1 ..< params.len:
          let paramDef = params[idx]
          if paramDef.kind != nnkIdentDefs:
            error(
              "Signature parameter must be a standard identifier declaration", paramDef
            )
          let paramTypeNode = paramDef[paramDef.len - 2]
          if paramTypeNode.kind == nnkEmpty:
            error("Signature parameter must declare a type", paramDef)
          var hasName = false
          for i in 0 ..< paramDef.len - 2:
            if paramDef[i].kind != nnkEmpty:
              hasName = true
          if not hasName:
            error("Signature parameter must declare a name", paramDef)
          argParams.add(copyNimTree(paramDef))
        argProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderWithArgs")
        argFieldName = ident("providerWithArgs")
    of nnkTypeSection, nnkEmpty:
      discard
    else:
      error("Unsupported statement inside RequestBroker definition", stmt)

  if zeroArgSig.isNil() and argSig.isNil():
    zeroArgSig = newEmptyNode()
    zeroArgProviderName = ident(sanitizeIdentName(typeIdent) & "ProviderNoArgs")
    zeroArgFieldName = ident("providerNoArgs")

  var typeSection = newTree(nnkTypeSection)
  typeSection.add(newTree(nnkTypeDef, exportedTypeIdent, newEmptyNode(), objectDef))

  let returnType = quote:
    Future[Result[`typeIdent`, string]]

  if not zeroArgSig.isNil():
    let procType = makeProcType(returnType, @[])
    typeSection.add(newTree(nnkTypeDef, zeroArgProviderName, newEmptyNode(), procType))
  if not argSig.isNil():
    let procType = makeProcType(returnType, cloneParams(argParams))
    typeSection.add(newTree(nnkTypeDef, argProviderName, newEmptyNode(), procType))

  var brokerRecList = newTree(nnkRecList)
  if not zeroArgSig.isNil():
    brokerRecList.add(
      newTree(nnkIdentDefs, zeroArgFieldName, zeroArgProviderName, newEmptyNode())
    )
  if not argSig.isNil():
    brokerRecList.add(
      newTree(nnkIdentDefs, argFieldName, argProviderName, newEmptyNode())
    )
  let brokerTypeIdent = ident(sanitizeIdentName(typeIdent) & "Broker")
  let brokerTypeDef = newTree(
    nnkTypeDef,
    brokerTypeIdent,
    newEmptyNode(),
    newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), brokerRecList),
  )
  typeSection.add(brokerTypeDef)
  result = newStmtList()
  result.add(typeSection)

  let globalVarIdent = ident("g" & sanitizeIdentName(typeIdent) & "Broker")
  let accessProcIdent = ident("access" & sanitizeIdentName(typeIdent) & "Broker")
  result.add(
    quote do:
      var `globalVarIdent` {.threadvar.}: `brokerTypeIdent`

      proc `accessProcIdent`(): var `brokerTypeIdent` =
        `globalVarIdent`

  )

  var clearBody = newStmtList()
  if not zeroArgSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `zeroArgProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`zeroArgFieldName`.isNil():
            return err("Zero-arg provider already set")
          `accessProcIdent`().`zeroArgFieldName` = handler
          return ok()

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`zeroArgFieldName` = nil
    )
    result.add(
      quote do:
        proc request*(
            _: typedesc[`typeIdent`]
        ): Future[Result[`typeIdent`, string]] {.async: (raises: []).} =
          let provider = `accessProcIdent`().`zeroArgFieldName`
          if provider.isNil():
            return err(
              "RequestBroker(" & `typeNameLit` & "): no zero-arg provider registered"
            )
          let catchedRes = catch:
            await provider()

          if catchedRes.isErr():
            return err("Request failed:" & catchedRes.error.msg)

          let providerRes = catchedRes.get()
          when `isRefObjectLit`:
            if providerRes.isOk():
              let resultValue = providerRes.get()
              if resultValue.isNil():
                return err(
                  "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
                )
          return providerRes

    )
  if not argSig.isNil():
    result.add(
      quote do:
        proc setProvider*(
            _: typedesc[`typeIdent`], handler: `argProviderName`
        ): Result[void, string] =
          if not `accessProcIdent`().`argFieldName`.isNil():
            return err("Provider already set")
          `accessProcIdent`().`argFieldName` = handler
          return ok()

    )
    clearBody.add(
      quote do:
        `accessProcIdent`().`argFieldName` = nil
    )
    let requestParamDefs = cloneParams(argParams)
    let argNameIdents = collectParamNames(requestParamDefs)
    let providerSym = genSym(nskLet, "provider")
    var formalParams = newTree(nnkFormalParams)
    formalParams.add(
      quote do:
        Future[Result[`typeIdent`, string]]
    )
    formalParams.add(
      newTree(
        nnkIdentDefs,
        ident("_"),
        newTree(nnkBracketExpr, ident("typedesc"), copyNimTree(typeIdent)),
        newEmptyNode(),
      )
    )
    for paramDef in requestParamDefs:
      formalParams.add(paramDef)

    let requestPragmas = quote:
      {.async: (raises: []), gcsafe.}
    var providerCall = newCall(providerSym)
    for argName in argNameIdents:
      providerCall.add(argName)
    var requestBody = newStmtList()
    requestBody.add(
      quote do:
        let `providerSym` = `accessProcIdent`().`argFieldName`
    )
    requestBody.add(
      quote do:
        if `providerSym`.isNil():
          return err(
            "RequestBroker(" & `typeNameLit` &
              "): no provider registered for input signature"
          )
    )
    requestBody.add(
      quote do:
        let catchedRes = catch:
          await `providerCall`
        if catchedRes.isErr():
          return err("Request failed:" & catchedRes.error.msg)

        let providerRes = catchedRes.get()
        when `isRefObjectLit`:
          if providerRes.isOk():
            let resultValue = providerRes.get()
            if resultValue.isNil():
              return err(
                "RequestBroker(" & `typeNameLit` & "): provider returned nil result"
              )
        return providerRes
    )
    # requestBody.add(providerCall)
    result.add(
      newTree(
        nnkProcDef,
        postfix(ident("request"), "*"),
        newEmptyNode(),
        newEmptyNode(),
        formalParams,
        requestPragmas,
        newEmptyNode(),
        requestBody,
      )
    )

  result.add(
    quote do:
      proc clearProvider*(_: typedesc[`typeIdent`]) =
        `clearBody`

  )

  when defined(requestBrokerDebug):
    echo result.repr
