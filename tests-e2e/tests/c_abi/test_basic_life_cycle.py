import re
import socket
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    get_node_bound_ports,
    get_node_multiaddr,
    wait_for_connected,
    wait_for_mesh,
)

NO_PROVIDER_REGISTERED_RE = re.compile(
    r"send_message: callback failed \(ret=1\): Send failed: MessagingClient\.send: Failed to create delivery task: Failed create DeliveryTask: "
    r"RequestBroker\(RequestRelayShard\): no provider registered for broker context (\w+)"
)
STOPPED_SUBSCRIBE_CONTENT_TOPIC = "/test/1/stopped-subscribe/proto"


class TestLogosDeliveryLifecycle:
    def _create_start_node(self, node_config, event_cb=None):
        result = WrapperManager.create_and_start(config=node_config, event_cb=event_cb)
        assert result.is_ok(), f"Failed to create and start node: {result.err()}"
        return result.ok_value

    def test_create_start_and_stop_node(self, node_config):
        node = self._create_start_node(node_config)

        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_stop_node_without_destroy(self, node_config):
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

    def test_restart_node(self, node_config):
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

    def test_send_on_node_never_started(self, node_config):
        # TODO: logos-delivery#4540
        # Each node names its own broker context in the error.
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            send_result = node.send_message(create_message_bindings())
            assert send_result.is_err(), "send on a node never started succeeded"
            match = NO_PROVIDER_REGISTERED_RE.search(send_result.err())
            assert match, send_result.err()

            other_result = WrapperManager.create(config=node_config)
            assert other_result.is_ok(), f"Failed to create node: {other_result.err()}"
            with other_result.ok_value as other_node:
                other_send_result = other_node.send_message(create_message_bindings())
                assert other_send_result.is_err(), "send on a node never started succeeded"
                other_match = NO_PROVIDER_REGISTERED_RE.search(other_send_result.err())
                assert other_match, other_send_result.err()
                assert other_match.group(1) != match.group(1), f"two nodes named the same broker context {match.group(1)}"

    def test_subscribe_and_unsubscribe_on_node_never_started(self, node_config):
        # TODO: logos-delivery#4540
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            subscribe_result = node.subscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert subscribe_result.is_ok(), f"subscribe on a node never started failed: {subscribe_result.err()}"

            unsubscribe_result = node.unsubscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert unsubscribe_result.is_ok(), f"unsubscribe on a node never started failed: {unsubscribe_result.err()}"

    def test_restart_node_with_rest(self, node_config):
        # TODO: logos-delivery#4522
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "rest": True}) as node:
            rest_port = get_node_bound_ports(node)["rest"]
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                assert s.connect_ex(("127.0.0.1", rest_port)) == 0, "REST port refused a connection after stop_node"

            start_result = node.start_node()
            assert start_result.is_err(), "restart with REST on succeeded"
            assert "failed to start REST: could not start the essential REST server" in start_result.err(), start_result.err()
            assert "Address already in use" in start_result.err(), start_result.err()

            start_result = node.start_node()
            assert start_result.is_err(), "second restart with REST on succeeded"
            assert "failed to start REST: could not start the essential REST server" in start_result.err(), start_result.err()
            assert "Address already in use" in start_result.err(), start_result.err()

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert not wait_for_mesh(peer_collector), "peer meshed with the node whose restart failed"

    def test_restart_node_with_metrics_server(self, node_config):
        # TODO: logos-delivery#4522
        # The restart fails but the node keeps running, and stop_node cannot stop it.
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "metricsServer": True, "metricsServerPort": 0}) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_err(), "restart with the metrics server on succeeded"
            assert "Starting metrics server failed" in start_result.err(), start_result.err()
            assert "Address already in use" in start_result.err(), start_result.err()

            stop_result = node.stop_node()
            assert stop_result.is_err(), "stop after the failed restart succeeded"
            assert "Metrics server returns an error: HTTP server is already stopped" in stop_result.err(), stop_result.err()

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the node whose stop failed"

    def test_peer_meshes_with_started_node(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"

    def test_peer_meshes_with_restarted_node(self, node_config):
        # A restarted node accepts the peers that connect after the restart.
        # nim-libp2p before 2.4.0 kept the connection manager closed after a stop,
        # so a restarted node dropped every inbound stream (nim-libp2p PR 3068).
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

    def test_listener_receives_events_after_restart(self, node_config):
        # TODO: logos-delivery#4523
        # The binding registers event_cb only when it creates the node.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_connected(node_collector), "listener added at create got no event after stop_node and start_node"

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"
