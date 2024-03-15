when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import options, json, strutils, sequtils, std/[tables, os]

import ./keyfile, ./conversion_utils, ./protocol_types, ./utils

# This proc creates an empty keystore (i.e. with no credentials)
proc createAppKeystore*(
    path: string, appInfo: AppInfo, separator: string = "\n"
): KeystoreResult[void] =
  let keystore = AppKeystore(
    application: appInfo.application,
    appIdentifier: appInfo.appIdentifier,
    version: appInfo.version,
    credentials: initTable[string, KeystoreMembership](),
  )

  var jsonKeystore: string
  jsonKeystore.toUgly(%keystore)

  var f: File
  if not f.open(path, fmWrite):
    return
      err(AppKeystoreError(kind: KeystoreOsError, msg: "Cannot open file for writing"))

  try:
    # To avoid other users/attackers to be able to read keyfiles, we make the file readable/writable only by the running user
    setFilePermissions(path, {fpUserWrite, fpUserRead})
    f.write(jsonKeystore)
    # We separate keystores with separator
    f.write(separator)
    ok()
  except CatchableError:
    err(AppKeystoreError(kind: KeystoreOsError, msg: getCurrentExceptionMsg()))
  finally:
    f.close()

# This proc load a keystore based on the application, appIdentifier and version filters.
# If none is found, it automatically creates an empty keystore for the passed parameters
proc loadAppKeystore*(
    path: string, appInfo: AppInfo, separator: string = "\n"
): KeystoreResult[JsonNode] =
  ## Load and decode JSON keystore from pathname
  var data: JsonNode
  var matchingAppKeystore: JsonNode

  # If no keystore exists at path we create a new empty one with passed keystore parameters
  if fileExists(path) == false:
    let newKeystoreRes = createAppKeystore(path, appInfo, separator)
    if newKeystoreRes.isErr():
      return err(newKeystoreRes.error)

  try:
    # We read all the file contents
    var f: File
    if not f.open(path, fmRead):
      return err(
        AppKeystoreError(kind: KeystoreOsError, msg: "Cannot open file for reading")
      )
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
        return
          err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))
      except ValueError:
        return
          err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))
      except OSError:
        return
          err(AppKeystoreError(kind: KeystoreOsError, msg: getCurrentExceptionMsg()))
      except Exception: #parseJson raises Exception
        return
          err(AppKeystoreError(kind: KeystoreOsError, msg: getCurrentExceptionMsg()))
  except IOError:
    return err(AppKeystoreError(kind: KeystoreIoError, msg: getCurrentExceptionMsg()))

  return ok(matchingAppKeystore)

# Adds a membership credential to the keystore matching the application, appIdentifier and version filters.
proc addMembershipCredentials*(
    path: string,
    membership: KeystoreMembership,
    password: string,
    appInfo: AppInfo,
    separator: string = "\n",
): KeystoreResult[void] =
  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields
  let jsonKeystoreRes = loadAppKeystore(path, appInfo, separator)

  if jsonKeystoreRes.isErr():
    return err(jsonKeystoreRes.error)

  # We load the JSON node corresponding to the app keystore
  var jsonKeystore = jsonKeystoreRes.get()

  try:
    if jsonKeystore.hasKey("credentials"):
      # We get all credentials in keystore
      let keystoreCredentials = jsonKeystore["credentials"]
      let key = membership.hash()
      if keystoreCredentials.hasKey(key):
        # noop
        return ok()

      let encodedMembershipCredential = membership.encode()
      let keyfileRes = createKeyFileJson(encodedMembershipCredential, password)
      if keyfileRes.isErr():
        return err(
          AppKeystoreError(kind: KeystoreCreateKeyfileError, msg: $keyfileRes.error)
        )

      # We add it to the credentials field of the keystore
      jsonKeystore["credentials"][key] = keyfileRes.get()
  except CatchableError:
    return err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))

  # We save to disk the (updated) keystore.
  let saveRes = save(jsonKeystore, path, separator)
  if saveRes.isErr():
    return err(saveRes.error)

  return ok()

# Returns the membership credentials in the keystore matching the application, appIdentifier and version filters, further filtered by the input
# identity credentials and membership contracts
proc getMembershipCredentials*(
    path: string, password: string, query: KeystoreMembership, appInfo: AppInfo
): KeystoreResult[KeystoreMembership] =
  # We load the keystore corresponding to the desired parameters
  # This call ensures that JSON has all required fields
  let jsonKeystoreRes = loadAppKeystore(path, appInfo)

  if jsonKeystoreRes.isErr():
    return err(jsonKeystoreRes.error)

  # We load the JSON node corresponding to the app keystore
  var jsonKeystore = jsonKeystoreRes.get()

  try:
    if jsonKeystore.hasKey("credentials"):
      # We get all credentials in keystore
      var keystoreCredentials = jsonKeystore["credentials"]
      if keystoreCredentials.len == 0:
        # error
        return err(
          AppKeystoreError(
            kind: KeystoreCredentialNotFoundError,
            msg: "No credentials found in keystore",
          )
        )
      var keystoreCredential: JsonNode
      if keystoreCredentials.len == 1:
        keystoreCredential = keystoreCredentials.getFields().values().toSeq()[0]
      else:
        let key = query.hash()
        if not keystoreCredentials.hasKey(key):
          # error
          return err(
            AppKeystoreError(
              kind: KeystoreCredentialNotFoundError,
              msg: "Credential not found in keystore",
            )
          )
        keystoreCredential = keystoreCredentials[key]

      let decodedKeyfileRes = decodeKeyFileJson(keystoreCredential, password)
      if decodedKeyfileRes.isErr():
        return err(
          AppKeystoreError(
            kind: KeystoreReadKeyfileError, msg: $decodedKeyfileRes.error
          )
        )
      # we parse the json decrypted keystoreCredential
      let decodedCredentialRes = decode(decodedKeyfileRes.get())
      let keyfileMembershipCredential = decodedCredentialRes.get()
      return ok(keyfileMembershipCredential)
  except CatchableError:
    return err(AppKeystoreError(kind: KeystoreJsonError, msg: getCurrentExceptionMsg()))
