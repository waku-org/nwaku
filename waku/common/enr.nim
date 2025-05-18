## An extension wrapper around nim-eth's ENR module

import eth/p2p/discoveryv5/enr
import ./enr/builder, ./enr/typed_record

export
  enr.Record,
  enr.EnrResult,
  enr.get,
  enr.tryGet,
  enr.toBase64,
  enr.toURI,
  enr.FieldPair,
  enr.toFieldPair,
  enr.init, # TODO: Delete after removing the deprecated procs
  builder,
  typed_record
