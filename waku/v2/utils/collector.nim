import
    metrics

proc parseCollectorIntoF64*(collector: Collector): float64 = 
  var total = 0.float64
  for key in collector.metrics.keys():
    try:
      total = total + collector.value(key)
    except KeyError:
      discard
  return total