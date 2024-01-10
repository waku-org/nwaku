import std/tables,
       stew/objects,
       stew/templateutils

template keepItIf*[A, B](tableParam: var Table[A, B], itPredicate: untyped) =
  bind evalTemplateParamOnce
  evalTemplateParamOnce(tableParam, t):
    var itemsToDelete: seq[A]
    var key {.inject.} : A
    var val {.inject.} : B

    for key, val in t:
      if not itPredicate:
        itemsToDelete.add(key)

    for item in itemsToDelete:
      t.del(item)

template keepItIf*[A, B](tableParam: var TableRef[A, B], itPredicate: untyped) =
  bind evalTemplateParamOnce
  evalTemplateParamOnce(tableParam, t):
    var itemsToDelete: seq[A]
    let key {.inject.} : A
    let val {.inject.} : B

    for key, val in t[]:
      if not itPredicate:
        itemsToDelete.add(key)

    for item in itemsToDelete:
      t[].del(item)
