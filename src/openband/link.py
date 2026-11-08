"""Request/response over any byte transport, plus the Bluetooth LE transport (bleak).

The band answers each request with a message carrying the same service and command ids.
Anything else that arrives (battery changes, band-initiated requests) goes to listeners.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from typing import Callable, Protocol

from . import frame
from .commands import Request
from .session import RESULT_SUCCESS, TAG_RESULT, Session
from .tlv import TLV, TLVError

log = logging.getLogger("openband.link")

SERVICE_UUID = "0000fe86-0000-1000-8000-00805f9b34fb"
WRITE_UUID = "0000fe01-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000fe02-0000-1000-8000-00805f9b34fb"


class BandError(RuntimeError):
    pass


class BandRefused(BandError):
    def __init__(self, request: Request, code: int):
        super().__init__(f"band refused {request.service:02x}/{request.command:02x} with error {code}")
        self.code = code


class Transport(Protocol):
    async def write(self, data: bytes) -> None: ...

    @property
    def max_write(self) -> int: ...

    def set_receiver(self, receiver: Callable[[bytes], None]) -> None: ...


Listener = Callable[[int, int, TLV], None]


class Band:
    def __init__(self, transport: Transport, session: Session | None = None, timeout: float = 8.0):
        self.transport = transport
        self.session = session or Session()
        self.timeout = timeout
        self._reassembler = frame.Reassembler()
        self._waiting: dict[tuple[int, int], asyncio.Future[TLV]] = {}
        self._listeners: list[Listener] = []
        self._lock = asyncio.Lock()
        transport.set_receiver(self._on_bytes)

    def listen(self, listener: Listener) -> None:
        self._listeners.append(listener)

    # --- receiving -----------------------------------------------------------------------

    def _on_bytes(self, data: bytes) -> None:
        log.debug("<< %s", data.hex())
        try:
            messages = self._reassembler.feed(data)
        except frame.FrameError as e:
            log.warning("dropping bad frame: %s", e)
            return
        for m in messages:
            self._on_message(m)

    def _on_message(self, m: frame.Message) -> None:
        try:
            body = self.session.open(TLV.parse(m.body))
        except (TLVError, ValueError, RuntimeError) as e:
            log.warning("cannot read %02x/%02x: %s (%s)", m.service, m.command, e, m.body.hex())
            return
        log.debug("<< %02x/%02x %r", m.service, m.command, body)
        fut = self._waiting.pop((m.service, m.command), None)
        if fut is not None and not fut.done():
            fut.set_result(body)
            return
        for listener in self._listeners:
            listener(m.service, m.command, body)

    # --- sending -------------------------------------------------------------------------

    def _packets(self, req: Request) -> list[bytes]:
        body = self.session.seal(req.tlv) if req.encrypted else req.tlv
        slice_size = min(self.session.params.slice_size, self.transport.max_write)
        return frame.encode(req.service, req.command, body.serialize(), slice_size)

    async def send(self, req: Request) -> None:
        log.debug(">> %02x/%02x %r%s", req.service, req.command, req.tlv, " (sealed)" if req.encrypted else "")
        for p in self._packets(req):
            log.debug(">> %s", p.hex())
            await self.transport.write(p)

    async def request(self, req: Request, timeout: float | None = None) -> TLV:
        async with self._lock:
            fut: asyncio.Future[TLV] = asyncio.get_running_loop().create_future()
            self._waiting[req.key] = fut
            try:
                await self.send(req)
                body = await asyncio.wait_for(fut, timeout or self.timeout)
            except asyncio.TimeoutError:
                raise BandError(f"no answer to {req.service:02x}/{req.command:02x} within {timeout or self.timeout:.0f}s") from None
            finally:
                self._waiting.pop(req.key, None)
        if TAG_RESULT in body and len(body.items) == 1:
            code = body.uint(TAG_RESULT)
            if code != RESULT_SUCCESS:
                raise BandRefused(req, code)
        return body


# --- Bluetooth LE ---------------------------------------------------------------------------


class BleTransport:
    """bleak-backed transport. Use `async with BleTransport.connect(...)`."""

    def __init__(self, client) -> None:
        self.client = client
        self._receiver: Callable[[bytes], None] | None = None

    @property
    def max_write(self) -> int:
        char = self.client.services.get_characteristic(WRITE_UUID)
        size = getattr(char, "max_write_without_response_size", 0) or 0
        mtu = getattr(self.client, "mtu_size", 23) or 23
        return max(20, size, mtu - 3)

    def set_receiver(self, receiver: Callable[[bytes], None]) -> None:
        self._receiver = receiver

    def _on_notify(self, _sender, data: bytearray) -> None:
        if self._receiver:
            self._receiver(bytes(data))

    async def write(self, data: bytes) -> None:
        await self.client.write_gatt_char(WRITE_UUID, data, response=True)

    async def start(self) -> None:
        await self.client.start_notify(NOTIFY_UUID, self._on_notify)


async def find_band(name_hint: str | None = None, address: str | None = None, timeout: float = 15.0):
    from bleak import BleakScanner

    if address:
        quick = min(timeout, 8.0) if sys.platform == "darwin" else timeout
        dev = await BleakScanner.find_device_by_address(address, timeout=quick)
        if dev is None and sys.platform == "darwin":
            dev = await _known_peripheral(address)
        if dev is None:
            raise BandError(f"no device with address {address} nearby")
        return dev

    def match(d, adv) -> bool:
        name = (d.name or adv.local_name or "").lower()
        if name_hint:
            return name_hint.lower() in name
        return SERVICE_UUID in [u.lower() for u in adv.service_uuids] or name.startswith("huawei band")

    dev = await BleakScanner.find_device_by_filter(match, timeout=timeout)
    if dev is None:
        raise BandError("no Huawei band found. Is Bluetooth off on the phone it is paired with?")
    return dev


async def _known_peripheral(address: str):
    """A peripheral macOS already knows, without waiting for it to advertise.

    A paired band stops advertising openly soon after a disconnect, so a scan misses it. Connecting
    to the peripheral CoreBluetooth remembers leaves a pending connection in the Bluetooth
    controller, which completes the moment the band reaches out, the way the phone app reconnects.
    """
    try:
        from bleak.backends.corebluetooth.CentralManagerDelegate import CentralManagerDelegate
        from bleak.backends.device import BLEDevice
        from Foundation import NSUUID
    except ImportError as e:
        log.info("pending connection not available: %s", e)
        return None
    manager = CentralManagerDelegate()
    await manager.wait_until_ready()
    uuid = NSUUID.alloc().initWithUUIDString_(address)
    if uuid is None:
        return None
    peripherals = manager.central_manager.retrievePeripheralsWithIdentifiers_([uuid])
    log.info("macOS knows %d peripheral(s) for %s", len(peripherals or []), address)
    if not peripherals:
        return None
    peripheral = peripherals[0]
    log.info("band not advertising; waiting for it on a pending connection")
    return BLEDevice(address, peripheral.name(), (peripheral, manager))


class Connection:
    """`async with Connection(device) as band:` connects, subscribes and yields a Band."""

    def __init__(self, device, session: Session | None = None, timeout: float = 8.0, connect_timeout: float = 90.0):
        self.device = device
        self.session = session
        self.timeout = timeout
        self.connect_timeout = connect_timeout
        self.client = None

    async def __aenter__(self) -> Band:
        from bleak import BleakClient

        self.client = BleakClient(self.device, timeout=self.connect_timeout)
        await self.client.connect()
        transport = BleTransport(self.client)
        band = Band(transport, self.session, self.timeout)
        await transport.start()
        return band

    async def __aexit__(self, *exc) -> None:
        if self.client is not None:
            try:
                await self.client.disconnect()
            except Exception:  # noqa: BLE001 - already gone is fine
                pass

