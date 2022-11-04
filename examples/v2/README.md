# basic2

TODO

# publisher/subscriber

Within `examples/v2` you can find a `publisher` and a `subscriber`. The first one publises messages to the default pubsub topic to a given content topic, and the second one runs forever listening to that pubsub topic and printing the content it receives.

**Some notes:**
* These examples are meant to work even in if you are behind a firewall and you can't be discovered by discv5.
* You only need to provide a reachable bootstrap peer (see our [fleets](https://fleets.status.im/))
* The examples are meant to work out of the box.
* Note that both services wait for some time until a given minimum amount of connections are reached. This is to ensure messages are gossiped.

**Compile:**

Make all examples.
```console
make example2
```

**Run:**

Wait until the subscriber is ready.
```console
./build/subscriber
```

And run a publisher
```console
./build/publisher
```

See how the subscriber received the messages published by the publisher. Feel free to experiment from different machines in different locations.