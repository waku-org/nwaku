import re
import socket
from src.node.wrappers_manager import WrapperManager
from src.node.wrapper_helpers import (
    EVENT_TOPIC_HEALTH_CHANGE,
    MESH_TOPIC_HEALTH,
    EventCollector,
    create_message_bindings,
    get_node_bound_ports,
    get_node_multiaddr,
    get_node_tcp_port,
    is_channel_error_event,
    unique_channel_id,
    wait_for_connected,
    wait_for_connection_change,
    wait_for_error,
    wait_for_event,
    wait_for_mesh,
    wait_for_topic_health,
)

NODE_NOT_STARTED_MSG = "node is not started"
STOPPED_SUBSCRIBE_CONTENT_TOPIC = "/test/1/stopped-subscribe/proto"

MESSAGING_SEND_NO_PROVIDER_RE = re.compile(r"messaging send failed: RequestBroker\(MessagingSend\): no provider registered for broker context \w+")
SEGMENTS_FAILED_MSG = "one or more segments failed"
STOPPED_CHANNEL_PREFIX = "stopped-channel"
STOPPED_CHANNEL_CONTENT_TOPIC = "/test/1/stopped-channel/proto"
STOPPED_CHANNEL_SENDER_ID = "stopped-channel-sender"
ERROR_TIMEOUT_S = 10.0

# The relay checks a shard's health as soon as it subscribes to the shard or its mesh changes.
TOPIC_HEALTH_WINDOW_S = 2.0


class TestLogosDeliveryLifecycle:
    def _create_start_node(self, node_config, event_cb=None):
        result = WrapperManager.create_and_start(config=node_config, event_cb=event_cb)
        assert result.is_ok(), f"Failed to create and start node: {result.err()}"
        return result.ok_value

    def _assert_channel_send_errors(self, collector, request_id, channel_id):
        error_event = wait_for_error(collector, request_id, ERROR_TIMEOUT_S)
        assert error_event is not None, f"no message_error for request {request_id}. Collected events: {collector.events}"
        assert MESSAGING_SEND_NO_PROVIDER_RE.fullmatch(error_event["error"]), error_event["error"]

        channel_error_event = wait_for_event(collector, request_id, is_channel_error_event, ERROR_TIMEOUT_S)
        assert channel_error_event is not None, f"no channel_message_error for request {request_id}. Collected events: {collector.events}"
        assert channel_error_event["channelId"] == channel_id, channel_error_event
        assert channel_error_event["error"] == SEGMENTS_FAILED_MSG, channel_error_event

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
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            send_result = node.send_message(create_message_bindings())
            assert send_result.is_err(), "send on a node never started succeeded"
            assert f"Send failed: {NODE_NOT_STARTED_MSG}" in send_result.err(), send_result.err()

    def test_subscribe_and_unsubscribe_on_node_never_started(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        result = WrapperManager.create(config=node_config)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            subscribe_result = node.subscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert subscribe_result.is_err(), "subscribe on a node never started succeeded"
            assert f"Subscribe failed: {NODE_NOT_STARTED_MSG}" in subscribe_result.err(), subscribe_result.err()

            unsubscribe_result = node.unsubscribe_content_topic(STOPPED_SUBSCRIBE_CONTENT_TOPIC)
            assert unsubscribe_result.is_err(), "unsubscribe on a node never started succeeded"
            assert f"Unsubscribe failed: {NODE_NOT_STARTED_MSG}" in unsubscribe_result.err(), unsubscribe_result.err()

    def test_channel_send_on_node_never_started(self, node_config):
        # TODO: calls-while-stopped
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        result = WrapperManager.create(config=node_config, event_cb=node_collector.event_callback)
        assert result.is_ok(), f"Failed to create node: {result.err()}"
        with result.ok_value as node:
            channel_id = unique_channel_id(STOPPED_CHANNEL_PREFIX)
            create_result = node.channel_create(channel_id, STOPPED_CHANNEL_CONTENT_TOPIC, STOPPED_CHANNEL_SENDER_ID)
            assert create_result.is_ok(), f"channel_create failed: {create_result.err()}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_ok(), f"channel_send on a node never started failed: {send_result.err()}"
            self._assert_channel_send_errors(node_collector, send_result.ok_value, channel_id)

    def test_channel_send_after_stop_node(self, node_config):
        # TODO: calls-while-stopped
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            channel_id = unique_channel_id(STOPPED_CHANNEL_PREFIX)
            create_result = node.channel_create(channel_id, STOPPED_CHANNEL_CONTENT_TOPIC, STOPPED_CHANNEL_SENDER_ID)
            assert create_result.is_ok(), f"channel_create after stop_node failed: {create_result.err()}"

            send_result = node.channel_send(channel_id, create_message_bindings())
            assert send_result.is_ok(), f"channel_send after stop_node failed: {send_result.err()}"
            self._assert_channel_send_errors(node_collector, send_result.ok_value, channel_id)

    def test_restart_node_with_rest(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "rest": True}) as node:
            rest_port = get_node_bound_ports(node)["rest"]
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                assert s.connect_ex(("127.0.0.1", rest_port)) != 0, "REST port accepted a connection after stop_node"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"
            assert get_node_bound_ports(node)["rest"] == rest_port, "REST bound another port after the restart"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

    def test_restart_node_with_metrics_server(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node({**node_config, "metricsServer": True, "metricsServerPort": 0}) as node:
            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

            start_result = node.start_node()
            assert start_result.is_ok(), f"Failed to restart node: {start_result.err()}"

            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the restarted node"

            stop_result = node.stop_node()
            assert stop_result.is_ok(), f"Failed to stop node: {stop_result.err()}"

    def test_peer_meshes_with_started_node(self, node_config):
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}, peer_collector.event_callback):
                assert wait_for_mesh(peer_collector), "peer never meshed with the node"

    def test_peer_never_meshes_with_node_at_dns4_localhost(self, node_config):
        # TODO: logos-delivery#1490
        node_config.update({"numShardsInNetwork": 1})
        with self._create_start_node(node_config) as node:
            peer_id_result = node.get_node_info("MyPeerId")
            assert peer_id_result.is_ok(), f"MyPeerId query failed: {peer_id_result.err()}"
            dns4_multiaddr = f"/dns4/localhost/tcp/{get_node_tcp_port(node)}/p2p/{peer_id_result.ok_value.strip()}"
            peer_collector = EventCollector()
            with self._create_start_node({**node_config, "staticnodes": [dns4_multiaddr]}, peer_collector.event_callback):
                assert not wait_for_mesh(peer_collector), "peer meshed with the node at a /dns4/localhost address"

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

    def test_topic_health_no_event_before_mesh(self, node_config):
        # TODO: topic-health-first-event
        # A node whose shard has no peer reports no topic health until a peer meshes.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            assert not wait_for_topic_health(node_collector, ("UnHealthy",), timeout_s=TOPIC_HEALTH_WINDOW_S), "node reported UnHealthy"

            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_mesh(node_collector), "node never meshed with the peer"
                topic_healths = [e["topicHealth"] for e in node_collector.snapshot() if e.get("eventType") == EVENT_TOPIC_HEALTH_CHANGE]
                assert topic_healths == ["MinimallyHealthy"], topic_healths

    def test_topic_health_no_event_for_listener_added_after_mesh(self, node_config):
        # TODO: topic-health-first-event
        # A listener added after the shard meshed gets no topic health.
        node_config.update({"numShardsInNetwork": 1})
        node_collector = EventCollector()
        with self._create_start_node(node_config, node_collector.event_callback) as node:
            with self._create_start_node({**node_config, "staticnodes": [get_node_multiaddr(node)]}):
                assert wait_for_mesh(node_collector), "node never meshed with the peer"
                connected_event = wait_for_connected(node_collector)
                assert connected_event, "node never reported PartiallyConnected or Connected"

                late_collector = EventCollector()
                listener_id = node.add_event_listener("onTopicHealthChange", late_collector.event_callback)
                assert listener_id != 0, "add_event_listener failed"
                assert not wait_for_topic_health(late_collector, ("UnHealthy",) + MESH_TOPIC_HEALTH, timeout_s=TOPIC_HEALTH_WINDOW_S), "listener added after the mesh formed got a topic health event"

                status_result = node.get_connection_status()
                assert status_result.is_ok(), f"get_connection_status failed: {status_result.err()}"
                assert status_result.ok_value == connected_event["connectionStatus"], status_result.ok_value

    def test_recreate_node_after_destroy(self, node_config):
        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"

        node = self._create_start_node(node_config)
        stop_result = node.stop_and_destroy()
        assert stop_result.is_ok(), f"Failed to stop and destroy node: {stop_result.err()}"
