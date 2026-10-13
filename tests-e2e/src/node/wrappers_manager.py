import sys
from pathlib import Path
from result import Result, Ok, Err

_BINDINGS_PATH = Path(__file__).resolve().parents[2] / "vendor" / "logos-delivery-python-bindings" / "logosdelivery"
if str(_BINDINGS_PATH) not in sys.path:
    sys.path.insert(0, str(_BINDINGS_PATH))

from wrapper import NodeWrapper as _NodeWrapper, ffi, lib  # type: ignore[import]
from wrapper import _event_callback, _global_set, _new_handle  # type: ignore[import]

ffi.cdef("int waku_is_online(void *ctx, FFICallback callback, void *userData, const uint8_t *reqCbor, size_t reqCborLen);")

""""
thin manager/wrapper layer around NodeWrapper from the bindings.
It simplifies  create, start, and interaction with a Waku node while returning consistent Result objects (Ok / Err).
"""


class WrapperManager:
    def __init__(self, node: _NodeWrapper):
        self._node = node
        self._event_cb_handlers = []

    @classmethod
    def create(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["WrapperManager", str]:
        result = _NodeWrapper.create_node(config, event_cb, timeout_s=timeout_s)
        if result.is_err():
            return Err(result.err())
        return Ok(cls(result.ok_value))

    @classmethod
    def create_and_start(
        cls,
        config: dict,
        event_cb=None,
        *,
        timeout_s: float = 20.0,
    ) -> Result["WrapperManager", str]:
        result = _NodeWrapper.create_and_start(config, event_cb, timeout_s=timeout_s)
        if result.is_err():
            return Err(result.err())
        return Ok(cls(result.ok_value))

    def __enter__(self) -> "WrapperManager":
        return self

    def __exit__(self, *_) -> None:
        self.stop_and_destroy()

    def start_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.start_node(timeout_s=timeout_s)

    def stop_node(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.stop_node(timeout_s=timeout_s)

    def destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        result = self._node.destroy(timeout_s=timeout_s)
        self._release_event_cb_handlers()
        return result

    def stop_and_destroy(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        result = self._node.stop_and_destroy(timeout_s=timeout_s)
        self._release_event_cb_handlers()
        return result

    def _release_event_cb_handlers(self) -> None:
        # The library calls back with these handlers until it destroys the node.
        if self._node.ctx == ffi.NULL:
            for handler in self._event_cb_handlers:
                _global_set.discard(handler)
            self._event_cb_handlers = []

    def destroy_keep_ctx(self, *, timeout_s: float = 20.0) -> Result[int, str]:
        """Pass-through for NodeWrapper.destroy_keep_ctx — see that method."""
        return self._node.destroy_keep_ctx(timeout_s=timeout_s)

    def subscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.subscribe_content_topic(content_topic, timeout_s=timeout_s)

    def unsubscribe_content_topic(self, content_topic: str, *, timeout_s: float = 20.0) -> Result[int, str]:
        return self._node.unsubscribe_content_topic(content_topic, timeout_s=timeout_s)

    def send_message(self, message: dict, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.send_message(message, timeout_s=timeout_s)

    def channel_create(
        self,
        channel_id: str,
        content_topic: str,
        sender_id: str,
        *,
        timeout_s: float = 20.0,
    ) -> Result[str, str]:
        return self._node.channel_create(channel_id, content_topic, sender_id, timeout_s=timeout_s)

    def channel_send(self, channel_id: str, message: dict, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.channel_send(channel_id, message, timeout_s=timeout_s)

    def channel_close(self, channel_id: str, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.channel_close(channel_id, timeout_s=timeout_s)

    def get_available_node_info_ids(self, *, timeout_s: float = 20.0) -> Result[list[str], str]:
        return self._node.get_available_node_info_ids(timeout_s=timeout_s)

    def get_node_info(self, node_info_id: str, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.get_node_info(node_info_id, timeout_s=timeout_s)

    def get_available_configs(self, *, timeout_s: float = 20.0) -> Result[dict, str]:
        return self._node.get_available_configs(timeout_s=timeout_s)

    def waku_is_online(self, *, timeout_s: float = 20.0) -> Result[bool, str]:
        return self._node._request(lib.waku_is_online, "waku_is_online", {}, timeout_s).map(lambda text: text == "true")

    def get_connection_status(self, *, timeout_s: float = 20.0) -> Result[str, str]:
        return self._node.get_connection_status(timeout_s=timeout_s)

    def add_event_listener(self, event_name: str, event_cb) -> int:
        """Registers event_cb for event_name after create; destroy removes it with the listeners added at create."""
        handler = _new_handle(event_cb)
        listener_id = lib.logosdelivery_add_event_listener(self._node.ctx, event_name.encode("utf-8"), _event_callback, handler)
        if listener_id == 0:
            _global_set.discard(handler)
            return 0
        self._node._listener_ids += (listener_id,)
        self._event_cb_handlers.append(handler)
        return listener_id
