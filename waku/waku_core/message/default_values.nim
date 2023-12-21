
const
  ## https://rfc.vac.dev/spec/64/#message-size
  MaxWakuMessageSize* = 150 * 1024 # Remember that 1 MiB is the PubSub default

  DefaultMaxWakuMessageSizeStr* = "150KiB"
  DefaultSafetyBufferProtocolOverhead* = 64 * 1024 # overhead measured in bytes
