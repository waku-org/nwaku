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

template parseAndAccumulate*(collector: Collector, cumulativeValue: float64): float64 =
  ## This template is used to get metrics in a window 
  ## according to a cumulative value passed in
  let total = parseCollectorIntoF64(collector)
  let freshCount = total - cumulativeValue
  cumulativeValue = total
  freshCount