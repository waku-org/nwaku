{.used.}

import testutils/unittests, chronos
import
  logos_delivery/waku/waku_archive/driver/postgres_driver/partitions_manager,
  logos_delivery/waku/waku_core/time

suite "Partition Manager":
  test "Calculate end partition time":
    # 1717372850 == Mon Jun 03 2024 00:00:50 GMT+0000
    # 1717376400 == Mon Jun 03 2024 01:00:00 GMT+0000
    check 1717376400 == partitions_manager.calcEndPartitionTime(Timestamp(1717372850))

    # 1717372800 == Mon Jun 03 2024 00:00:00 GMT+0000
    # 1717376400 == Mon Jun 03 2024 01:00:00 GMT+0000
    check 1717376400 == partitions_manager.calcEndPartitionTime(Timestamp(1717372800))

  test "Remove the oldest partition only when it is the expected one":
    let manager = PartitionManager.new()
    manager.addPartitionInfo("messages_1717372800_1717376400", 1717372800, 1717376400)
    manager.addPartitionInfo("messages_1717376400_1717380000", 1717376400, 1717380000)

    ## The partitions queue may be refreshed while the caller is awaiting the
    ## queries that drop the partition it chose, so a stale name must not remove
    ## whatever ended up being the oldest one.
    manager.removeOldestPartitionName("messages_1717369200_1717372800")
    check manager.getOldestPartition().get().getName() ==
      "messages_1717372800_1717376400"

    manager.removeOldestPartitionName("messages_1717372800_1717376400")
    check manager.getOldestPartition().get().getName() ==
      "messages_1717376400_1717380000"

  test "Remove a partition from an empty manager":
    let manager = PartitionManager.new()

    ## Must not raise, even though the queue is empty
    manager.removeOldestPartitionName("messages_1717372800_1717376400")
    check manager.isEmpty()

  test "Floor a moment to the hour":
    # 1717372850 == Mon Jun 03 2024 00:00:50 GMT+0000
    # 1717372800 == Mon Jun 03 2024 00:00:00 GMT+0000
    check 1717372800 == floorToHour(1717372850)
    check 1717372800 == floorToHour(1717372800)

    # 1717372799 == Sun Jun 02 2024 23:59:59 GMT+0000
    # 1717369200 == Sun Jun 02 2024 23:00:00 GMT+0000
    check 1717369200 == floorToHour(1717372799)

  test "A slot overlaps the tracked partitions":
    let manager = PartitionManager.new()

    ## Nothing tracked, nothing overlaps
    check not manager.overlapsTracked(1717372800, 1717376400)

    # [00:00, 01:00) tracked
    manager.addPartitionInfo("messages_1717372800_1717376400", 1717372800, 1717376400)
    check:
      manager.overlapsTracked(1717372800, 1717376400) # the same slot
      not manager.overlapsTracked(1717376400, 1717380000)
        # [01:00, 02:00), adjacent after
      not manager.overlapsTracked(1717369200, 1717372800)
        # [23:00, 00:00), adjacent before

    # A legacy partition that starts within the hour, [23:28, 00:00)
    manager.addPartitionInfo("messages_1717370880_1717372800", 1717370880, 1717372800)
    check manager.overlapsTracked(1717369200, 1717372800) # the [23:00, 00:00) slot
