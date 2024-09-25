import metrics

declarePublicGauge query_time_secs,
  "query time measured in nanoseconds", labels = ["query", "phase"]

declarePublicCounter query_count,
  "number of times a query is being performed", labels = ["query"]
