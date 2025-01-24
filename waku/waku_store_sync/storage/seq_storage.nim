import std/[algorithm, sequtils, math, options], results, chronos, stew/arrayops

import
  ../../waku_core/time,
  ../../waku_core/message/digest,
  ../common,
  ./range_processing,
  ./storage

type SeqStorage* = ref object of SyncStorage
  elements: seq[SyncID]

  # Numer of parts a range will be splitted into.
  partitionCount: int

  # Number of element in a range for which item sets are used instead of fingerprints.
  lengthThreshold: int

method length*(self: SeqStorage): int =
  return self.elements.len

method insert*(self: SeqStorage, element: SyncID): Result[void, string] {.raises: [].} =
  let idx = self.elements.lowerBound(element, common.cmp)

  if idx < self.elements.len and self.elements[idx] == element:
    return err("duplicate element")

  self.elements.insert(element, idx)

  return ok()

method batchInsert*(
    self: SeqStorage, elements: seq[SyncID]
): Result[void, string] {.raises: [].} =
  ## Insert the sorted seq of new elements.

  if elements.len == 1:
    return self.insert(elements[0])

  #TODO custom impl. ???

  if not elements.isSorted(common.cmp):
    return err("seq not sorted")

  var merged = newSeqOfCap[SyncID](self.elements.len + elements.len)

  merged.merge(self.elements, elements, common.cmp)

  self.elements = merged.deduplicate(true)

  return ok()

method prune*(self: SeqStorage, timestamp: Timestamp): int {.raises: [].} =
  ## Remove all elements before the timestamp.
  ## Returns # of elements pruned.

  if self.elements.len == 0:
    return 0

  let bound = SyncID(time: timestamp, hash: EmptyWakuMessageHash)

  let idx = self.elements.lowerBound(bound, common.cmp)

  self.elements.delete(0 ..< idx)

  return idx

proc computefingerprintFromSlice(
    self: SeqStorage, sliceOpt: Option[Slice[int]]
): Fingerprint =
  ## XOR all hashes of a slice of the storage.

  var fingerprint = EmptyFingerprint

  if sliceOpt.isNone():
    return fingerprint

  let idxSlice = sliceOpt.get()

  for id in self.elements[idxSlice]:
    fingerprint = fingerprint xor id.hash

  return fingerprint

proc findIdxBounds(self: SeqStorage, slice: Slice[SyncID]): Option[Slice[int]] =
  ## Given bounds find the corresponding indices in this storage

  #TODO can thoses 2 binary search be combined for efficiency ???

  let lower = self.elements.lowerBound(slice.a, common.cmp)
  var upper = self.elements.upperBound(slice.b, common.cmp)

  if upper < 1:
    # entire range is before any of our elements
    return none(Slice[int])

  if lower >= self.elements.len:
    # entire range is after any of our elements
    return none(Slice[int])

  return some(lower ..< upper)

method computeFingerprint*(
    self: SeqStorage, bounds: Slice[SyncID]
): Fingerprint {.raises: [].} =
  let idxSliceOpt = self.findIdxBounds(bounds)
  return self.computefingerprintFromSlice(idxSliceOpt)

proc processFingerprintRange*(
    self: SeqStorage,
    inputBounds: Slice[SyncID],
    inputFingerprint: Fingerprint,
    output: var RangesData,
) {.raises: [].} =
  ## Compares fingerprints and partition new ranges.

  let idxSlice = self.findIdxBounds(inputBounds)
  let ourFingerprint = self.computeFingerprintFromSlice(idxSlice)

  if ourFingerprint == inputFingerprint:
    output.ranges.add((inputBounds, RangeType.Skip))
    return

  if idxSlice.isNone():
    output.ranges.add((inputBounds, RangeType.ItemSet))
    let state = ItemSet(elements: @[], reconciled: true)
    output.itemSets.add(state)
    return

  let slice = idxSlice.get()

  if slice.len <= self.lengthThreshold:
    output.ranges.add((inputBounds, RangeType.ItemSet))
    let state = ItemSet(elements: self.elements[slice], reconciled: false)
    output.itemSets.add(state)
    return

  let partitions = equalPartitioning(inputBounds, self.partitionCount)
  for partitionBounds in partitions:
    let sliceOpt = self.findIdxBounds(partitionBounds)

    if sliceOpt.isNone():
      output.ranges.add((partitionBounds, RangeType.ItemSet))
      let state = ItemSet(elements: @[], reconciled: true)
      output.itemSets.add(state)
      continue

    let slice = sliceOpt.get()

    if slice.len <= self.lengthThreshold:
      output.ranges.add((partitionBounds, RangeType.ItemSet))
      let state = ItemSet(elements: self.elements[slice], reconciled: false)
      output.itemSets.add(state)
      continue

    let fingerprint = self.computeFingerprintFromSlice(some(slice))
    output.ranges.add((partitionBounds, RangeType.Fingerprint))
    output.fingerprints.add(fingerprint)
    continue

proc processItemSetRange*(
    self: SeqStorage,
    inputBounds: Slice[SyncID],
    inputItemSet: ItemSet,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
    output: var RangesData,
) {.raises: [].} =
  ## Compares item sets and outputs differences

  let idxSlice = self.findIdxBounds(inputBounds)

  if idxSlice.isNone():
    if not inputItemSet.reconciled:
      output.ranges.add((inputBounds, RangeType.ItemSet))
      let state = ItemSet(elements: @[], reconciled: true)
      output.itemSets.add(state)
    else:
      output.ranges.add((inputBounds, RangeType.Skip))

    return

  let slice = idxSlice.get()

  var i = 0
  let n = inputItemSet.elements.len

  var j = slice.a
  let m = slice.b + 1

  while (j < m):
    let ourElement = self.elements[j]

    if i >= n:
      # in case we have more elements
      hashToSend.add(ourElement.hash)
      j.inc()
      continue

    let theirElement = inputItemSet.elements[i]

    if theirElement < ourElement:
      hashToRecv.add(theirElement.hash)
      i.inc()
    elif theirElement > ourElement:
      hashToSend.add(ourElement.hash)
      j.inc()
    else:
      i.inc()
      j.inc()

  while (i < n):
    # in case they have more elements
    let theirElement = inputItemSet.elements[i]
    i.inc()
    hashToRecv.add(theirElement.hash)

  if not inputItemSet.reconciled:
    output.ranges.add((inputBounds, RangeType.ItemSet))
    let state = ItemSet(elements: self.elements[slice], reconciled: true)
    output.itemSets.add(state)
  else:
    output.ranges.add((inputBounds, RangeType.Skip))

method processPayload*(
    self: SeqStorage,
    input: RangesData,
    hashToSend: var seq[Fingerprint],
    hashToRecv: var seq[Fingerprint],
): RangesData {.raises: [].} =
  var output = RangesData()

  var
    i = 0
    j = 0

  for (bounds, rangeType) in input.ranges:
    case rangeType
    of RangeType.Skip:
      output.ranges.add((bounds, RangeType.Skip))

      continue
    of RangeType.Fingerprint:
      let fingerprint = input.fingerprints[i]
      i.inc()

      self.processFingerprintRange(bounds, fingerprint, output)

      continue
    of RangeType.ItemSet:
      let itemSet = input.itemsets[j]
      j.inc()

      self.processItemSetRange(bounds, itemSet, hashToSend, hashToRecv, output)

      continue

  # merge consecutive skip ranges
  var allSkip = true
  i = output.ranges.len - 1
  while i >= 0:
    let currRange = output.ranges[i]

    if allSkip and currRange[1] != RangeType.Skip:
      allSkip = false

    if i <= 0:
      break

    let prevRange = output.ranges[i - 1]

    if currRange[1] != RangeType.Skip or prevRange[1] != RangeType.Skip:
      i.dec()
      continue

    let lb = prevRange[0].a
    let ub = currRange[0].b
    let newRange = (lb .. ub, RangeType.Skip)

    output.ranges.delete(i)
    output.ranges[i - 1] = newRange

    i.dec()

  if allSkip:
    output = RangesData()

  return output

proc new*(T: type SeqStorage, capacity: int, threshold = 100, partitions = 8): T =
  return SeqStorage(
    elements: newSeqOfCap[SyncID](capacity),
    lengthThreshold: threshold,
    partitionCount: partitions,
  )

proc new*(
    T: type SeqStorage, elements: seq[SyncID], threshold = 100, partitions = 8
): T =
  return SeqStorage(
    elements: elements, lengthThreshold: threshold, partitionCount: partitions
  )
