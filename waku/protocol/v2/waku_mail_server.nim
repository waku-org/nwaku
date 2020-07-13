import sequtils, tables

## deprecated

type 
  MailServer* = ref object
    messages = Table[string, seq[seq[byte]]]

proc init*(T: type MailServer): T =
    T(messages: newTable[string, seq[seq[byte]]]())

proc archive*(mail: MailServer, topic: string, data: seq[byte]) =
    discard mail.messages.hasKeyOrPut(topic, newSeq[byte]())
    mail.messages[topic].add(data)
