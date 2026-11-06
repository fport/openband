"""The handshake: LinkParams, (security negotiation, PIN), Auth, BondParams, Bond.

Two paths, picked by what the band reports in LinkParams:

* normal mode (support type 0): the challenge uses a fixed digest secret, and the bond wraps
  our key with a key derived from the band's Bluetooth MAC.
* HiChain Lite (support type 1-4, negotiated auth type 1 or 2): the challenge is keyed with a
  PIN the band hands over (or our secret key on auth version 2), and the bond wraps our key with
  the first 16 bytes of that challenge.

Full HiChain (SPEKE) is not implemented; we stop with a clear error if a band asks for it.
"""

from __future__ import annotations

import hmac
import logging
from dataclasses import dataclass

from . import commands as cmd
from . import crypto
from .link import Band, BandError
from .session import LinkParams
from .store import BandRecord

log = logging.getLogger("openband.auth")


class AuthError(BandError):
    pass


class NeedsBond(AuthError):
    pass


@dataclass
class AuthReport:
    params: LinkParams
    auth_mode: int
    negotiated_auth_type: int | None
    bond_status: int | None
    bonded_now: bool


async def read_link_params(band: Band) -> LinkParams:
    t = await band.request(cmd.link_params())
    params = LinkParams.from_tlv(t)
    band.session.params = params
    return params


def describe(params: LinkParams) -> dict:
    return {
        "protocol_version": params.protocol_version,
        "auth_version": params.auth_version,
        "device_support_type": params.device_support_type,
        "auth_algo": params.auth_algo,
        "encrypt_method": params.encrypt_method,
        "bond_state": params.bond_state,
        "slice_size": params.slice_size,
        "mtu": params.mtu,
        "path": "hichain" if params.uses_hichain else "normal",
    }


async def authenticate(band: Band, rec: BandRecord, *, allow_bond: bool) -> AuthReport:
    """Run the whole handshake. With allow_bond=False we refuse to write a new key to the band."""
    s = band.session
    params = await read_link_params(band)
    s.secret_key = rec.key
    negotiated = None

    if params.uses_hichain:
        s.auth_mode = crypto.AUTH_MODE_HICHAIN3 if params.device_support_type == 0x04 else crypto.AUTH_MODE_HICHAIN_LITE
        t = await band.request(cmd.security_negotiation(s.auth_mode, rec.device_uuid.encode(), params.encrypt_method))
        negotiated = cmd.parse_security_negotiation(t)
        log.info("security negotiation: auth type %s (%r)", negotiated, t)
        if negotiated == cmd.HICHAIN_FULL or cmd.is_hichain3(negotiated):
            raise AuthError(
                f"the band wants full HiChain pairing (auth type {negotiated:#x}), which Openband does not speak yet"
            )
        if negotiated not in (0x01, 0x02):
            raise AuthError(f"unexpected security negotiation answer: {t!r}")
        s.auth_mode = crypto.AUTH_MODE_HICHAIN_LITE
    else:
        s.auth_mode = crypto.AUTH_MODE_NORMAL

    # Challenge key: HiChain Lite uses the band's PIN, or our own key on auth version 2.
    key: bytes | None = None
    if s.auth_mode == crypto.AUTH_MODE_HICHAIN_LITE:
        if params.auth_version == 0x02:
            key = rec.key
        else:
            t = await band.request(cmd.pin_code())
            key = crypto.decrypt(
                params.encrypt_method == 0x01,
                t.get(0x01),
                crypto.digest_secret(params.auth_version),
                t.get(0x02),
            )
            log.info("got the band's PIN")

    client_nonce = crypto.nonce16()
    double_nonce = params.server_nonce + client_nonce
    kw = dict(auth_version=params.auth_version, auth_mode=s.auth_mode, auth_algo=params.auth_algo, key=key)
    challenge = crypto.digest_challenge(double_nonce, **kw)
    first_key = challenge[:16]
    t = await band.request(cmd.auth(challenge[:32], params.auth_version, client_nonce, s.auth_mode, params.auth_algo))
    expected = crypto.digest_response(double_nonce, **kw)[:32]
    if not hmac.compare_digest(t.get(0x01, b""), expected):
        raise AuthError("the band's answer to our challenge does not check out")
    log.info("challenge passed")

    t = await band.request(cmd.bond_params(rec.client_serial, rec.client_mac.encode()))
    bond_status = t.byte(0x01, 0)
    s.counter = t.uint(0x09, 0)

    skip_bond = s.auth_mode == crypto.AUTH_MODE_NORMAL and bond_status == 1 and rec.bonded
    bonded_now = False
    if not skip_bond:
        if not rec.bonded and not allow_bond:
            raise NeedsBond("this band has not been paired with Openband yet; run `openband pair` first")
        if s.auth_mode == crypto.AUTH_MODE_HICHAIN_LITE:
            wrap_key = first_key
        else:
            if not rec.band_mac:
                raise NeedsBond(
                    "this band uses normal-mode bonding, which needs its Bluetooth MAC. "
                    "Find it on the band under Settings > About, then pass --band-mac AA:BB:CC:DD:EE:FF"
                )
            wrap_key = crypto.mac_bond_key(rec.band_mac, params.auth_version)
        iv = s.iv()
        wrapped = crypto.encrypt(params.encrypt_method == 0x01, rec.key, wrap_key, iv)
        try:
            await band.request(cmd.bond(rec.client_serial, wrapped, iv), timeout=min(5.0, band.timeout))
        except BandError as e:
            # Some bands do not answer the bond message; the next encrypted request tells.
            log.info("no answer to bond (%s); carrying on", e)
        bonded_now = not rec.bonded
    s.authenticated = True
    return AuthReport(params, s.auth_mode, negotiated, bond_status, bonded_now)
