import nimcrypto


proc cfbEncode*(key: string, iv: string, data: string): seq[byte] =
  var context: CFB[aes256]
  var pKey: array[aes256.sizeKey, byte]
  var pIv: array[aes256.sizeBlock, byte]
  var pData = newSeq[byte](len(data))
  var encodedData = newSeq[byte](len(data))

  copyMem(addr pData[0], unsafeAddr data[0], len(data))
  # WARNING! Do not use 0 byte padding in applications, this is done as example.
  copyMem(addr pKey[0], unsafeAddr key[0], len(key))
  copyMem(addr pIv[0], unsafeAddr iv[0], len(iv))

  # Initialization of CFB[aes256] context with encryption key
  context.init(pKey, pIv)
  # Encryption process
  context.encrypt(pData, encodedData)
  # Clear context of CFB[aes256]
  context.clear()

  return encodedData


proc cfbDecode*(key: string, iv: string, encodedData: seq[byte]): seq[byte] =
  var context: CFB[aes256]
  var pKey: array[aes256.sizeKey, byte]
  var pIv: array[aes256.sizeBlock, byte]
  var decodedData = newSeq[byte](len(encodedData))

  # copyMem(addr _data[0], addr data[0], len(data))
  # WARNING! Do not use 0 byte padding in applications, this is done as example.
  copyMem(addr pKey[0], unsafeAddr key[0], len(key))
  copyMem(addr pIv[0], unsafeAddr iv[0], len(iv))

  # Initialization of CFB[aes256] context with encryption key
  context.init(pKey, pIv)
  # Decryption process
  context.decrypt(encodedData, decodedData)
  # Clear context of CFB[aes256]
  context.clear()
  
  return decodedData
