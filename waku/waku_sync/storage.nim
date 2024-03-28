when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[times, tables], chronicles, chronos, stew/results

import ./raw_bindings

logScope:
  topics = "waku sync"

type WakuSyncStorageManager* = object
  storages: OrderedTable[string, Storage]  # Map of dateTime and Storage objects. DateTime is of the format YYYYMMDDHH
  maxHours: times.Duration

proc new*(T: type WakuSyncStorageManager, hoursToStore: times.Duration = initDuration(minutes=120)): T =
  return WakuSyncStorageManager(maxHours:hoursToStore.inHours)

#Time should be in YYYYMMDDHH format.
proc createStorage(
    self: WakuSyncStorageManager, time: string
): Result[Storage, string] =
  let storage:Storage = Storage.new().valueOr:
    error "storage creation failed"
    return err("storage creation failed")
  self.storages[time] = storage
  return storage

proc getRecentStorage(): Result[Storage, string]=


#Time should be in YYYYMMDDHH format.
proc getStorage(self: WakuSyncStorageManager, time: string): Result[Storage, string] =
    if self.storages.hasKey(time):
        return self.storages[time]
  return err("no storage found for given dateTime")

proc retrieveStorage*(
    self: WakuSyncStorageManager, time: int64
): Result[Storage, string] =
  let unixf = times.fromUnixFloat(float(time))

  let dateTime = times.format(unixf, "YYYYMMDDHH")
  let storage = self.getStorage(dateTime).valueOr:
    #create a new storage
    # TODO: May need synchronization??
    # Limit number of storages to configured duration
    if initDuration(hours = self.storages.len()) == self.maxHours:
      #TODO: Need to delete oldest storage at this point, but what if that is being synced?
      error "number of storages reached, need to purge oldest"
      return err("number of storages reached, need to purge oldest")
    return self.createStorage(dateTime)

  return storage

proc deleteStorage*(time:string)=
  if self.storages.hasKey(time):
    self.storages.del(time)
