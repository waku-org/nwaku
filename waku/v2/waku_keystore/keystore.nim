when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  options, json, strutils,
  std/[algorithm, os, sequtils, sets]

import
  ./keyfile,
  ./conversion_utils,
  ./protocol_types,
  ./utils

# This proc creates an empty keystore (i.e. with no credentials)
proc createAppKeystore*(path: string,
                        appInfo: AppInfo,
                        separator: string = "\n"): KeystoreResult[void] =

  let keystore = AppKeystore(application: appInfo.application,
                             appIdentifier: appInfo.appIdentifier,
                             credentials: @[],
                             version: appInfo.version)

  var jsonKeystore: string
  jsonKeystore.toUgly(%keystore)

  var f: File
  if not f.open(path, fmWrite):
    return err(KeystoreOsError)

  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(path, {fpUserWrite, fpUserRead})
    f.write(jsonKeystore)
    # We separate keystores with separator
    f.write(separator)
    ok()
  except CatchableError:
    err(KeystoreOsError)
  finally:
    f.close()

# This proc load a keystore based on the application, appIdentifier and version filters.
# If none is found, it automatically creates an empty keystore for the passed parameters
proc loadAppKeystore*(path: string,
                      appInfo: AppInfo,
                      separator: string = "\n"): KeystoreResult[JsonNode] =

  ## Load and decode JSON keystore from pathname
  var data: JsonNode
  var matchingAppKeystore: JsonNode

  # If no keystore exists at path we create a new empty one with passed keystore parameters
  if fileExists(path) == false:
    let newKeystore = createAppKeystore(path, appInfo, separator)
    if newKeystore.isErr():
        return err(KeystoreCreateKeystoreError)

  try:

    # We read all the file contents
    var f: File
    if not f.open(path, fmRead):
      return err(KeystoreOsError)
    let fileContents = readAll(f)

    # We iterate over each substring split by separator (which we expect to correspond to a single keystore json)
    for keystore in fileContents.split(separator):

      # We skip if read line is empty
      if keystore.len == 0:
        continue
      # We skip all lines that don't seem to define a json
      if not keystore.startsWith("{") or not keystore.endsWith("}"):
        continue

      try:
        # We parse the json
        data = json.parseJson(keystore)

        # We check if parsed json contains the relevant keystore credentials fields and if these are set to the passed parameters
        # (note that "if" is lazy, so if one of the .contains() fails, the json fields contents will not be checked and no ResultDefect will be raised due to accessing unavailable fields)
        if data.hasKeys(["application", "appIdentifier", "credentials", "version"]) and
           data["application"].getStr() == appInfo.application and
           data["appIdentifier"].getStr() == appInfo.appIdentifier and
           data["version"].getStr() == appInfo.version:
          # We return the first json keystore that matches the passed app parameters
          # We assume a unique kesytore with such parameters is present in the file
          matchingAppKeystore = data
          break
      # TODO: we might continue rather than return for some of these errors
      except JsonParsingError:
        return err(KeystoreJsonError)
      except ValueError:
        return err(KeystoreJsonError)
      except OSError:
        return err(KeystoreOsError)
      except Exception: #parseJson raises Exception
        return err(KeystoreOsError)

  except IOError:
    return err(KeystoreIoError)

  return ok(matchingAppKeystore)


# Adds a sequence of membership credential to the keystore matching the application, appIdentifier and version filters.
proc addMembershipCredentials*(path: string,
                               credentials: seq[MembershipCredentials],
                               password: string,
                               appInfo: AppInfo,
                               separator: string = "\n"): KeystoreResult[void] =

  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields
  let jsonKeystoreRes = loadAppKeystore(path, appInfo, separator)

  if jsonKeystoreRes.isErr():
    return err(KeystoreLoadKeystoreError)

  # We load the JSON node corresponding to the app keystore
  var jsonKeystore = jsonKeystoreRes.get()

  try:

    if jsonKeystore.hasKey("credentials"):

      # We get all credentials in keystore
      var keystoreCredentials = jsonKeystore["credentials"]
      var found: bool

      for membershipCredential in credentials:

        # A flag to tell us if the keystore contains a credential associated to the input identity credential, i.e. membershipCredential
        found = false

        for keystoreCredential in keystoreCredentials.mitems():
          # keystoreCredential is encrypted. We decrypt it
          let decodedKeyfileRes = decodeKeyFileJson(keystoreCredential, password)
          if decodedKeyfileRes.isOk():

            # we parse the json decrypted keystoreCredential
            let decodedCredentialRes = decode(decodedKeyfileRes.get())

            if decodedCredentialRes.isOk():
              let keyfileMembershipCredential = decodedCredentialRes.get()

              # We check if the decrypted credential has its identityCredential field equal to the input credential
              if keyfileMembershipCredential.identityCredential == membershipCredential.identityCredential:
                # idCredential is present in keystore. We add the input credential membership group to the one contained in the decrypted keystore credential (we deduplicate groups using sets)
                var allMemberships = toSeq(toHashSet(keyfileMembershipCredential.membershipGroups) + toHashSet(membershipCredential.membershipGroups))

                # We sort membership groups, otherwise we will not have deterministic results in tests
                allMemberships.sort(sortMembershipGroup)

                # we define the updated credential with the updated membership sets
                let updatedCredential = MembershipCredentials(identityCredential: keyfileMembershipCredential.identityCredential, membershipGroups: allMemberships)

                # we re-encrypt creating a new keyfile
                let encodedUpdatedCredential = updatedCredential.encode()
                let updatedCredentialKeyfileRes = createKeyFileJson(encodedUpdatedCredential, password)
                if updatedCredentialKeyfileRes.isErr():
                  return err(KeystoreCreateKeyfileError)

                # we update the original credential field in keystoreCredentials
                keystoreCredential = updatedCredentialKeyfileRes.get()

                found = true

                # We stop decrypting other credentials in the keystore
                break

        # If no credential in keystore with same input identityCredential value is found, we add it
        if found == false:

          let encodedMembershipCredential = membershipCredential.encode()
          let keyfileRes = createKeyFileJson(encodedMembershipCredential, password)
          if keyfileRes.isErr():
            return err(KeystoreCreateKeyfileError)

          # We add it to the credentials field of the keystore
          jsonKeystore["credentials"].add(keyfileRes.get())

  except CatchableError:
    return err(KeystoreJsonError)

  # We save to disk the (updated) keystore.
  if save(jsonKeystore, path, separator).isErr():
    return err(KeystoreOsError)

  return ok()

# Returns the membership credentials in the keystore matching the application, appIdentifier and version filters, further filtered by the input
# identity credentials and membership contracts
proc getMembershipCredentials*(path: string,
                               password: string,
                               filterIdentityCredentials: seq[IdentityCredential] = @[],
                               filterMembershipContracts: seq[MembershipContract] = @[],
                               appInfo: AppInfo): KeystoreResult[seq[MembershipCredentials]] =

  var outputMembershipCredentials: seq[MembershipCredentials] = @[]

  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields
  let jsonKeystoreRes = loadAppKeystore(path, appInfo)

  if jsonKeystoreRes.isErr():
    return err(KeystoreLoadKeystoreError)

  # We load the JSON node corresponding to the app keystore
  var jsonKeystore = jsonKeystoreRes.get()

  try:

    if jsonKeystore.hasKey("credentials"):

      # We get all credentials in keystore
      var keystoreCredentials = jsonKeystore["credentials"]

      for keystoreCredential in keystoreCredentials.mitems():

        # keystoreCredential is encrypted. We decrypt it
        let decodedKeyfileRes = decodeKeyFileJson(keystoreCredential, password)
        if decodedKeyfileRes.isOk():
            # we parse the json decrypted keystoreCredential
            let decodedCredentialRes = decode(decodedKeyfileRes.get())

            if decodedCredentialRes.isOk():
              let keyfileMembershipCredential = decodedCredentialRes.get()

              let filteredCredentialOpt = filterCredential(keyfileMembershipCredential, filterIdentityCredentials, filterMembershipContracts)

              if filteredCredentialOpt.isSome():
                outputMembershipCredentials.add(filteredCredentialOpt.get())

  except CatchableError:
    return err(KeystoreJsonError)

  return ok(outputMembershipCredentials)
