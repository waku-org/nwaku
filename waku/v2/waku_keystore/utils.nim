when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  json,
  std/[options, os, sequtils],
  ./keyfile,
  ./protocol_types

# Checks if a JsonNode has all keys contained in "keys"
proc hasKeys*(data: JsonNode, keys: openArray[string]): bool =
  return all(keys, proc (key: string): bool = return data.hasKey(key))

# Defines how to sort membership groups
proc sortMembershipGroup*(a,b: MembershipGroup): int =
  return cmp(a.membershipContract.address, b.membershipContract.address)

# Safely saves a Keystore's JsonNode to disk.
# If exists, the destination file is renamed with extension .bkp; the file is written at its destination and the .bkp file is removed if write is successful, otherwise is restored
proc save*(json: JsonNode, path: string, separator: string): KeystoreResult[void] =

  # We first backup the current keystore
  if fileExists(path):
    try:
      moveFile(path, path & ".bkp")
    except:  # TODO: Fix "BareExcept" warning
      return err(KeystoreOsError)

  # We save the updated json
  var f: File
  if not f.open(path, fmAppend):
    return err(KeystoreOsError)
  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(path, {fpUserWrite, fpUserRead})
    f.write($json)
    # We store a keyfile per line
    f.write(separator)
  except CatchableError:
    # We got some KeystoreOsError writing to disk. We attempt to restore the previous keystore backup
    if fileExists(path & ".bkp"):
      try:
        f.close()
        removeFile(path)
        moveFile(path & ".bkp", path)
      except:  # TODO: Fix "BareExcept" warning
        # Unlucky, we just fail
        return err(KeystoreOsError)
    return err(KeystoreOsError)
  finally:
    f.close()

  # The write went fine, so we can remove the backup keystore
  if fileExists(path & ".bkp"):
    try:
      removeFile(path & ".bkp")
    except CatchableError:
      return err(KeystoreOsError)

  return ok()

# Filters a membership credential based on either input identity credential's value, membership contracts or both
proc filterCredential*(credential: MembershipCredentials,
                       filterIdentityCredentials: seq[IdentityCredential],
                       filterMembershipContracts: seq[MembershipContract]): Option[MembershipCredentials] =

  # We filter by identity credentials
  if filterIdentityCredentials.len() != 0:
    if (credential.identityCredential in filterIdentityCredentials) == false:
      return none(MembershipCredentials)

  # We filter by membership groups credentials
  if filterMembershipContracts.len() != 0:
    # Here we keep only groups that match a contract in the filter
    var membershipGroupsIntersection: seq[MembershipGroup] = @[]
    # We check if we have a group in the input credential matching any contract in the filter
    for membershipGroup in credential.membershipGroups:
      if membershipGroup.membershipContract in filterMembershipContracts:
        membershipGroupsIntersection.add(membershipGroup)

    if membershipGroupsIntersection.len() != 0:
      # If we have a match on some groups, we return the credential with filtered groups
      return some(MembershipCredentials(identityCredential: credential.identityCredential,
                                        membershipGroups: membershipGroupsIntersection))

    else:
      return none(MembershipCredentials)

  # We hit this return only if
  # - filterIdentityCredentials.len() == 0 and filterMembershipContracts.len() == 0 (no filter)
  # - filterIdentityCredentials.len() != 0 and filterMembershipContracts.len() == 0 (filter only on identity credential)
  # Indeed, filterMembershipContracts.len() != 0 will have its exclusive return based on all values of membershipGroupsIntersection.len()
  return some(credential)
