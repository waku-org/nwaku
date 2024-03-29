when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[times, tables, options], chronicles, chronos, stew/results

import ./raw_bindings

logScope:
  topics = "waku sync"

type WakuSyncStorageManager* = ref object
  storages: OrderedTable[string, Storage]
    # Map of dateTime and Storage objects. DateTime is of the format YYYYMMDDHH
  maxHours: int64

proc new*(
    T: type WakuSyncStorageManager,
    hoursToStore: times.Duration = initDuration(minutes = 120),
): T =
  return WakuSyncStorageManager(maxHours: hoursToStore.inHours)

proc getRecentStorage*(self: WakuSyncStorageManager): Result[Option[Storage], string] =
  if self.storages.len() == 0:
    return ok(none(Storage))
  var storageToFetch: Storage
  #is there a more effective way to fetch last element?
  for k, storage in self.storages:
    storageToFetch = storage

  return ok(some(storageToFetch))

proc deleteStorage*(self: WakuSyncStorageManager, time: string) =
  var storageToDelete: Storage

  if self.storages.pop(time, storageToDelete):
    delete(storageToDelete)

proc deleteOldestStorage*(self: WakuSyncStorageManager) =
  var storageToDelete: Storage
  var time: string
  #is there a more effective way to fetch first element?
  for k, storage in self.storages:
    storageToDelete = storage
    time = k
    break

  if self.storages.pop(time, storageToDelete):
    delete(storageToDelete)

proc retrieveStorage*(
    self: WakuSyncStorageManager, time: int64
): Result[Option[Storage], string] =
  let unixf = times.fromUnixFloat(float(time))

  let dateTime = times.format(unixf, "yyyyMMddHH")
  var storage: Storage = self.storages.getOrDefault(dateTime)
  if storage == nil:
    #create a new storage
    # TODO: May need synchronization??
    # Limit number of storages to configured duration
    let hours = self.storages.len()
    if hours == self.maxHours:
      #Need to delete oldest storage at this point, but what if that is being synced?
      self.deleteOldestStorage()
      info "number of storages reached, deleting the oldest"
    storage = Storage.new().valueOr:
      error "storage creation failed"
      return err(error)
    self.storages[dateTime] = storage

  return ok(some(storage))
