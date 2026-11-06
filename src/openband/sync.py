"""Pull history off the band: per-minute activity (steps, heart rate, SpO2) and sleep.

Both use the same pattern: ask how many records cover [start, end], then fetch them one by one.
Nothing is acknowledged or deleted on the band.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

from . import commands as cmd
from .link import Band, BandRefused

log = logging.getLogger("openband.sync")


@dataclass
class History:
    minutes: list[cmd.MinuteSample] = field(default_factory=list)
    sleep: list[cmd.SleepSpan] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


async def _records(band: Band, count_cmd: int, data_cmd: int, start: int, end: int, parse):
    try:
        count = cmd.parse_message_count(await band.request(cmd.message_count(count_cmd, start, end)))
    except BandRefused as e:
        log.info("no records for %02x: %s", count_cmd, e)
        return
    log.info("%d records for %02x", count, count_cmd)
    for i in range(count):
        number, items = parse(await band.request(cmd.message_data(data_cmd, i)))
        if number != i:
            log.warning("asked for record %d, got %d", i, number)
        yield items


async def fetch_history(band: Band, start: int, end: int, progress=None) -> History:
    h = History()
    async for items in _records(band, cmd.STEP_COUNT, cmd.STEP_DATA, start, end, cmd.parse_step_data):
        h.minutes.extend(items)
        if progress:
            progress("activity", len(h.minutes))
    async for items in _records(band, cmd.SLEEP_COUNT, cmd.SLEEP_DATA, start, end, cmd.parse_sleep_data):
        h.sleep.extend(items)
        if progress:
            progress("sleep", len(h.sleep))
    h.minutes.sort(key=lambda m: m.timestamp)
    h.sleep.sort(key=lambda s: s.start)
    return h
