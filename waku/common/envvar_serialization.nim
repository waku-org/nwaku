{.push raises: [].}

import stew/shims/macros, serialization
import ./envvar_serialization/reader, ./envvar_serialization/writer

export serialization, reader, writer

serializationFormat Envvar

Envvar.setReader EnvvarReader
Envvar.setWriter EnvvarWriter, PreferredOutput = void

template supports*(_: type Envvar, T: type): bool =
  # The Envvar format should support every type
  true

template decode*(
    _: type Envvar, prefix: string, RecordType: distinct type, params: varargs[untyped]
): auto =
  mixin init, ReaderType

  {.noSideEffect.}:
    var reader = unpackArgs(init, [EnvvarReader, prefix, params])
    reader.readValue(RecordType)

template encode*(
    _: type Envvar, prefix: string, value: auto, params: varargs[untyped]
) =
  mixin init, WriterType, writeValue

  {.noSideEffect.}:
    var writer = unpackArgs(init, [EnvvarWriter, prefix, params])
    writeValue writer, value

template loadFile*(
    _: type Envvar, prefix: string, RecordType: distinct type, params: varargs[untyped]
): auto =
  mixin init, ReaderType, readValue

  var reader = unpackArgs(init, [EnvvarReader, prefix, params])
  reader.readValue(RecordType)

template saveFile*(
    _: type Envvar, prefix: string, value: auto, params: varargs[untyped]
) =
  mixin init, WriterType, writeValue

  var writer = unpackArgs(init, [EnvvarWriter, prefix, params])
  writer.writeValue(value)
