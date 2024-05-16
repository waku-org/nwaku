when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import metrics

proc parseCollectorIntoF64(collector: SimpleCollector): float64 {.gcsafe, raises: [].} =
  {.gcsafe.}:
    var total = 0.float64
    for metrics in collector.metrics:
      for metric in metrics:
        try:
          total = total + metric.value
        except KeyError:
          discard
    return total

template parseAndAccumulate*(collector: Collector, cumulativeValue: float64): float64 =
  ## This template is used to get metrics in a window 
  ## according to a cumulative value passed in
  {.gcsafe.}:
    let total = parseCollectorIntoF64(collector)
    let freshCount = total - cumulativeValue
    cumulativeValue = total
    freshCount

template collectorAsF64*(collector: Collector): float64 =
  ## This template is used to get metrics from 0
  ## Serves as a wrapper for parseCollectorIntoF64 which is gcsafe
  {.gcsafe.}:
    let total = parseCollectorIntoF64(collector)
    total
