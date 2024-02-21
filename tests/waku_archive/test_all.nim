{.used.}

import
  ./test_driver_queue_index,
  ./test_driver_queue_pagination,
  ./test_driver_queue_query,
  ./test_driver_queue,
  ./test_driver_sqlite_query,
  ./test_driver_sqlite,
  ./test_retention_policy,
  ./test_waku_archive

const os* {.strdefine.} = ""
when os == "Linux" and defined(postgres):
  # GitHub only supports container actions on Linux
  # and we need to start a postgress database in a docker container
  import ./test_driver_postgres_query, ./test_driver_postgres
