import re
import socket
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EventCollector,
    create_message_bindings,
    get_node_bound_ports,
    get_node_multiaddr,
    wait_for_connected,
    wait_for_connection_change,
    wait_for_mesh,
    wait_for_topic_health,
)
from tests.c_abi.test_channel_delivery import DELIVERY_TIMEOUT_S, NO_CHANNEL_DELIVERY_WINDOW_S, wait_for_message_received

NO_PROVIDER_REGISTERED_RE = re.compile(
    r"Send failed: MessagingClient\.send: Failed to create delivery task: Failed create DeliveryTask: "
    r"RequestBroker\(RequestRelayShard\): no provider registered for broker context (\w+)"
)
STOPPED_SEND_CONTENT_TOPIC = "/test/1/stopped-send/proto"
OTHER_CONTENT_TOPIC = "/test/1/stopped-send-other/proto"


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

    def test_send_after_stop_node(self, node_config):
        # TODO: logos-delivery#4540
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            send_result = node.send_message(create_message_bindings())
            assert send_result.is_err(), "send after stop_node succeeded"
            assert NO_PROVIDER_REGISTERED_RE.search(send_result.err()), send_result.err()

    def test_failed_send_after_stop_node_subscribes_content_topic(self, node_config):
        # TODO: logos-delivery#4540
        # A send after stop_node fails but still subscribes its content topic, so the restarted node delivers messages on it.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            send_result = node.send_message(create_message_bindings(contentTopic=STOPPED_SEND_CONTENT_TOPIC))
            assert send_result.is_err(), "send after stop_node succeeded"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback) as peer:
                assert wait_for_mesh(node_collector), "node never meshed with the peer"
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"

                other_send_result = peer.send_message(create_message_bindings(contentTopic=OTHER_CONTENT_TOPIC))
                assert other_send_result.is_ok(), f"peer send failed: {other_send_result.err()}"
                peer_send_result = peer.send_message(create_message_bindings(contentTopic=STOPPED_SEND_CONTENT_TOPIC))
                assert peer_send_result.is_ok(), f"peer send failed: {peer_send_result.err()}"

                assert wait_for_message_received(node_collector, STOPPED_SEND_CONTENT_TOPIC, DELIVERY_TIMEOUT_S), "node delivered no message on the content topic of its failed send"
                assert wait_for_message_received(node_collector, OTHER_CONTENT_TOPIC, timeout_s=NO_CHANNEL_DELIVERY_WINDOW_S) is None, "node delivered a message on a content topic it never sent to"

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

    def test_restart_node_with_rest_after_failed_start(self, node_config):
        # TODO: logos-delivery#4522
        node_config.update({"rest": True})
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("", 0))
            s.listen()
            result = WrapperManager.create(config={**node_config, "tcpPort": s.getsockname()[1]})
            assert result.is_ok(), f"Failed to create node: {result.err()}"
            with result.ok_value as node:
                start_result = node.start_node()
                assert start_result.is_err(), "start on a TCP port in use succeeded"
                assert "TcpTransport start" in start_result.err(), start_result.err()
                s.close()

                start_result = node.start_node()
                assert start_result.is_err(), "start after the TCP port was freed succeeded"
                assert "failed to start REST: could not start the essential REST server" in start_result.err(), start_result.err()
                assert "Address already in use" in start_result.err(), start_result.err()

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

    def test_topic_health_unhealthy_when_mesh_peer_leaves(self, node_config):
        # TODO: logos-delivery#4541
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_mesh(node_collector), "node never meshed with the peer"

            assert wait_for_topic_health(node_collector, ("UnHealthy",)), "node reported no UnHealthy after its only mesh peer left"

    def test_topic_health_never_unhealthy_after_restart(self, node_config):
        # TODO: logos-delivery#4541
        # The restarted node reports no UnHealthy after its only mesh peer leaves.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_mesh(node_collector), "node never meshed with the peer"

            assert wait_for_connection_change(node_collector, "EventDisconnected"), "restarted node never saw the peer leave"
            assert not wait_for_topic_health(node_collector, ("UnHealthy",), timeout_s=2), "restarted node reported UnHealthy"

    def test_topic_health_unchanged_at_stop_node(self, node_config):
        # TODO: logos-delivery#4541
        # The stopped node reports no UnHealthy, while its peer does for the same mesh.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(node_collector), "node never meshed with the peer"
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"

                stop_result = node.stop_node()
                assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

                assert wait_for_topic_health(peer_collector, ("UnHealthy",)), "peer reported no UnHealthy after the node stopped"
                assert wait_for_connection_change(node_collector, "EventDisconnected"), "stopped node never saw the peer leave"
                assert not wait_for_topic_health(node_collector, ("UnHealthy",), timeout_s=0), "stopped node reported UnHealthy"

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

    def test_recreate_node_with_rest_after_destroy(self, node_config):
        # TODO: logos-delivery#4522
        node_config.update({"rest": True})
        with self._create_start_node(node_config) as node:
            rest_port = get_node_bound_ports(node)["rest"]
            stop_result = node.stop_and_destroy()
            assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        result = WrapperManager.create_and_start(config={**node_config, "restPort": rest_port})
        assert result.is_err(), "a node on the REST port of a destroyed node started"
        assert "failed to start REST: could not start the essential REST server" in result.err(), result.err()
        assert "Address already in use" in result.err(), result.err()
