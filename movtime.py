"""Dump every time field in a QuickTime/MP4 file.

Answers two separate questions that are easy to conflate:

  1. What absolute wall-clock time does the file claim it was recorded at,
     and at what resolution?
  2. How precise is the frame-to-frame timing?

Pure stdlib -- no ffmpeg, no exiftool.

Usage:  python3 movtime.py IMG_3692.MOV
"""

import re
import struct
import sys

# QuickTime counts seconds from 1904-01-01 UTC; Unix counts from 1970-01-01.
QT_EPOCH_TO_UNIX = 2_082_844_800

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl", b"udta"}


def walk(data, start, end, depth=0):
    """Yield (atom_type, payload_start, payload_end, depth) depth-first."""
    pos = start
    while pos + 8 <= end:
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        atom = data[pos + 4:pos + 8]
        header = 8
        if size == 1:
            if pos + 16 > end:
                return
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return

        payload_start = pos + header
        payload_end = min(pos + size, end)
        yield atom, payload_start, payload_end, depth

        if atom in CONTAINERS:
            for found in walk(data, payload_start, payload_end, depth + 1):
                yield found

        pos += size


def parse_mvhd(data, start):
    version = data[start]
    if version == 1:
        created, modified = struct.unpack(">QQ", data[start + 4:start + 20])
        timescale = struct.unpack(">I", data[start + 20:start + 24])[0]
        duration = struct.unpack(">Q", data[start + 24:start + 32])[0]
    else:
        created, modified = struct.unpack(">II", data[start + 4:start + 12])
        timescale, duration = struct.unpack(">II", data[start + 12:start + 20])
    return created, modified, timescale, duration


def parse_mdhd(data, start):
    version = data[start]
    if version == 1:
        timescale = struct.unpack(">I", data[start + 20:start + 24])[0]
        duration = struct.unpack(">Q", data[start + 24:start + 32])[0]
    else:
        timescale, duration = struct.unpack(">II", data[start + 12:start + 20])
    return timescale, duration


def parse_stts(data, start):
    """Return [(sample_count, sample_delta), ...] from a time-to-sample atom."""
    count = struct.unpack(">I", data[start + 4:start + 8])[0]
    entries = []
    pos = start + 8
    for _ in range(count):
        n, delta = struct.unpack(">II", data[pos:pos + 8])
        entries.append((n, delta))
        pos += 8
    return entries


def parse_hdlr(data, start, end):
    """Return the handler subtype, e.g. b'vide' or b'soun'."""
    return data[start + 8:start + 12] if start + 12 <= end else b"????"


def qt_to_utc(seconds):
    import datetime
    unix = seconds - QT_EPOCH_TO_UNIX
    return datetime.datetime.fromtimestamp(unix, datetime.timezone.utc)


def main(path):
    with open(path, "rb") as handle:
        data = handle.read()

    print("file: %s (%.1f MB)\n" % (path, len(data) / 1e6))

    mvhd = None
    tracks = []
    current = None

    for atom, start, end, _ in walk(data, 0, len(data)):
        if atom == b"mvhd":
            mvhd = parse_mvhd(data, start)
        elif atom == b"trak":
            current = {"kind": None, "timescale": None, "stts": None}
            tracks.append(current)
        elif atom == b"hdlr" and current is not None:
            if current["kind"] is None:
                current["kind"] = parse_hdlr(data, start, end)
        elif atom == b"mdhd" and current is not None:
            current["timescale"], current["duration"] = parse_mdhd(data, start)
        elif atom == b"stts" and current is not None:
            current["stts"] = parse_stts(data, start)

    print("=" * 62)
    print("ABSOLUTE TIME  (when the file says it was recorded)")
    print("=" * 62)

    if mvhd:
        created, _, timescale, duration = mvhd
        print("  mvhd creation_time : %s" % qt_to_utc(created).strftime("%Y-%m-%d %H:%M:%S"))
        print("                       stored as a whole number of seconds")
        print("  movie duration     : %.3f s" % (duration / timescale))

    # Apple writes an ISO-8601 string into the metadata; find it directly.
    iso = re.findall(rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}", data[:2_000_000])
    iso += re.findall(rb"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}", data[-2_000_000:])
    for value in dict.fromkeys(iso):
        print("  quicktime.creationdate : %s" % value.decode())
    if iso:
        print("                           ^ note: no decimal point, no milliseconds")

    print()
    print("=" * 62)
    print("RELATIVE TIME  (frame-to-frame precision)")
    print("=" * 62)

    for track in tracks:
        if track["kind"] != b"vide" or not track["stts"]:
            continue
        timescale = track["timescale"]
        entries = track["stts"]
        frames = sum(n for n, _ in entries)
        total = sum(n * d for n, d in entries)

        print("  video track timescale : %d ticks/second" % timescale)
        print("  tick resolution       : %.4f ms" % (1000.0 / timescale))
        print("  frames                : %d" % frames)
        print("  track duration        : %.4f s" % (total / timescale))
        print("  average frame rate    : %.4f fps" % (frames / (total / timescale)))

        deltas = sorted({d for _, d in entries})
        if len(deltas) == 1:
            d = deltas[0]
            print("  frame spacing         : constant, %d ticks = %.4f ms"
                  % (d, d * 1000.0 / timescale))
        else:
            print("  frame spacing         : VARIABLE across %d distinct values" % len(deltas))
            print("                          %.4f ms min, %.4f ms max"
                  % (deltas[0] * 1000.0 / timescale, deltas[-1] * 1000.0 / timescale))

        print()
        print("  first 5 frame presentation times, relative to clip start:")
        shown = 0
        elapsed = 0
        for n, d in entries:
            for _ in range(n):
                if shown >= 5:
                    break
                print("    frame %-3d  %9.4f ms" % (shown, elapsed * 1000.0 / timescale))
                elapsed += d
                shown += 1
            if shown >= 5:
                break
        print()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
