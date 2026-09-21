"""Measure how far TimestampCam's burned-in timestamp is from a filmed clock.

Point TimestampCam at msclock.py running on a screen, record, then:

    python3 frame_offsets.py TimestampCam-1790017099.MOV

Or compare against a timestampcap (Mac) recording of the same clock:

    python3 frame_offsets.py TimestampCam-1790021118.MOV Terminal-...-1790021097.mov

Every frame is read with macOS's built-in text recognition (Vision, via pyobjc):
the burned-in label from the black box in the top-right corner, the filmed
clock from everywhere else. Positive offset means the app's label is ahead of
the filmed clock.

Readings are cached next to the clip as <clip>.offsets.csv; pass --redo to
re-read the video. The plot is written to <clip>.offsets.png, or
<phone clip>.comparison.png when comparing.

Needs:  pip install -r requirements.txt
"""

import argparse
import csv
import re
from pathlib import Path

import numpy as np

# HH:MM:SS:MMM, tolerating the recogniser reading a colon as a period.
TIME = re.compile(r"(\d{2})[:.](\d{2})[:.](\d{2})[:.](\d{3})")

# A reading further than this from the median is a misread digit, not timing.
# Real timing error is tens of ms; a misread second digit is ~1000 ms.
MISREAD_MS = 150

# A phone frame and a Mac frame whose filmed clock values are this close count
# as the same moment. The pairing corrects for the gap between them, so this
# only bounds how much drift can creep in.
PAIR_WINDOW_MS = 250

# How much of a clip to sample before committing to reading all of it.
PROBE_FRAMES, PROBE_EVERY = 300, 10


def timestamps(text):
    """Milliseconds since midnight for every well-formed timestamp in text."""
    found = []
    for h, m, s, ms in TIME.findall(text):
        h, m, s, ms = int(h), int(m), int(s), int(ms)
        if h < 24 and m < 60 and s < 60:
            found.append(((h * 60 + m) * 60 + s) * 1000 + ms)
    return found


def read_frame(pixels, Vision):
    """Return (burned_in_ms, filmed_ms) for one frame, or None if unreadable."""
    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(False)
    handler = Vision.VNImageRequestHandler.alloc().initWithCVPixelBuffer_options_(pixels, None)
    handler.performRequests_error_([request], None)

    burned_in, filmed = [], []
    for observation in request.results() or []:
        text = observation.topCandidates_(1)[0].string()
        box = observation.boundingBox()
        # Vision boxes are normalised with the origin at the bottom left, so the
        # overlay is anything centred in the top tenth, right half of the frame.
        mid_x = box.origin.x + box.size.width / 2
        mid_y = box.origin.y + box.size.height / 2
        in_overlay = mid_y > 0.90 and mid_x > 0.5
        (burned_in if in_overlay else filmed).extend(timestamps(text))

    # Local and UTC differ by hours, so the closest pair is local vs local.
    pairs = [(b, f) for b in burned_in for f in filmed]
    if not pairs:
        return None
    b, f = min(pairs, key=lambda p: abs(p[0] - p[1]))
    return (b, f) if abs(b - f) < 5000 else None


def read_offsets(clip, every=1, max_frames=None):
    """Decode the clip and read both timestamps from every `every`-th frame,
    stopping after `max_frames` frames if given.

    Returns (rows, unreadable) where rows are (frame, clip_seconds, burned_in_ms,
    filmed_ms).
    """
    import objc
    import AVFoundation
    import CoreMedia
    import Quartz
    import Vision
    from Foundation import NSURL

    asset = AVFoundation.AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(str(clip)), None)
    track = asset.tracksWithMediaType_(AVFoundation.AVMediaTypeVideo)[0]
    reader, error = AVFoundation.AVAssetReader.assetReaderWithAsset_error_(asset, None)
    if reader is None:
        raise RuntimeError(f"could not open {clip}: {error}")
    output = AVFoundation.AVAssetReaderTrackOutput.assetReaderTrackOutputWithTrack_outputSettings_(
        track, {Quartz.kCVPixelBufferPixelFormatTypeKey: Quartz.kCVPixelFormatType_32BGRA})
    reader.addOutput_(output)
    reader.startReading()

    rows, unreadable, frame = [], 0, -1
    while max_frames is None or frame + 1 < max_frames:
        with objc.autorelease_pool():
            sample = output.copyNextSampleBuffer()
            if sample is None:
                break
            frame += 1
            if frame % every:
                continue
            seconds = CoreMedia.CMTimeGetSeconds(CoreMedia.CMSampleBufferGetPresentationTimeStamp(sample))
            reading = read_frame(CoreMedia.CMSampleBufferGetImageBuffer(sample), Vision)
            if reading is None:
                unreadable += 1
            else:
                rows.append((frame, seconds, *reading))
        if frame % 100 == 0:
            print(f"  frame {frame}: {len(rows)} read, {unreadable} unreadable")
    return rows, unreadable


def summarize(rows):
    """The measurement: median offset, spread, drift, and misreads."""
    t = np.array([r[1] for r in rows])
    offset = np.array([r[2] - r[3] for r in rows], dtype=float)

    median = np.median(offset)
    good = np.abs(offset - median) <= MISREAD_MS
    t_good, off_good = t[good], offset[good]
    slope_per_s, intercept = np.polyfit(t_good, off_good, 1) if good.sum() > 2 else (float("nan"),) * 2

    return {
        "t": t,
        "offset": offset,
        "good": good,
        "n": len(offset),
        "misread": int((~good).sum()),
        "median_ms": float(np.median(off_good)),
        "mean_ms": float(off_good.mean()),
        "std_ms": float(off_good.std()),
        "p5_ms": float(np.percentile(off_good, 5)),
        "p95_ms": float(np.percentile(off_good, 95)),
        "drift_ms_per_min": float(slope_per_s * 60),
        "fit": (float(slope_per_s), float(intercept)),
    }


def compare(phone_rows, mac_rows):
    """The three deltas on one timeline: seconds since the first reading.

    Returns [(label, summary)] for the phone timestamp minus the clock the phone
    filmed, the Mac timestamp minus the clock the Mac recorded, and the phone
    timestamp minus the Mac timestamp at the same moment. The recordings start
    at different times and run at different frame rates, so "the same moment"
    is found by matching the msclock.py value each one shows.
    """
    # Every frame shows the time twice, LOCAL and UTC, and the reader pairs
    # whichever lines match, so some rows come out in UTC. Local and UTC differ
    # by whole quarter hours: shift every row onto the same clock as the first
    # reading. The app's time and the clock's time move together, so no offset
    # changes -- only where the point sits on the time axis.
    reference, quarter_hour = (phone_rows + mac_rows)[0][2], 15 * 60 * 1000

    def on_one_clock(rows):
        shifted = []
        for frame, seconds, label, clock in rows:
            shift = round((reference - label) / quarter_hour) * quarter_hour
            shifted.append((frame, seconds, label + shift, clock + shift))
        return shifted

    phone_rows, mac_rows = on_one_clock(phone_rows), on_one_clock(mac_rows)
    origin = min(r[2] for r in phone_rows + mac_rows)

    def on_timeline(rows):
        return [(frame, (label - origin) / 1000, label, clock) for frame, _, label, clock in rows]

    # For each phone frame, find the Mac frame showing the nearest msclock.py
    # value, then shift the Mac timestamp by the small remaining clock gap
    # (both advance 1:1) to get the Mac timestamp for exactly the clock value
    # the phone saw.
    mac_clocks = np.array([r[3] for r in mac_rows])
    phone_vs_mac = []
    for frame, _, phone_label, phone_clock in phone_rows:
        _, _, mac_label, mac_clock = mac_rows[int(np.argmin(np.abs(mac_clocks - phone_clock)))]
        if abs(mac_clock - phone_clock) <= PAIR_WINDOW_MS:
            mac_label_at_phone_clock = mac_label + (phone_clock - mac_clock)
            phone_vs_mac.append((frame, (phone_label - origin) / 1000, phone_label, mac_label_at_phone_clock))

    if len(phone_vs_mac) < 3:
        raise SystemExit(f"Only {len(phone_vs_mac)} phone frames show a clock value within {PAIR_WINDOW_MS} ms "
                         "of one in the Mac recording. Were the two recordings made at the same time? "
                         "(Readings are cached, so re-running is instant.)")

    return [
        ("Phone timestamp − clock the phone filmed", summarize(on_timeline(phone_rows))),
        ("Mac timestamp − clock the Mac recorded", summarize(on_timeline(mac_rows))),
        ("Phone timestamp − Mac timestamp, matched on the clock value both show", summarize(phone_vs_mac)),
    ]


def plot_offsets(series, title, path):
    """Scatter each (label, summary) series with its line of best fit.

    All numbers come from the summaries; this only draws them.
    """
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    surface, ink, ink_secondary, grid = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e0"
    colors = ["#2a78d6", "#eb6834", "#1baf7a"]

    fig, ax = plt.subplots(figsize=(11, 5.5), dpi=150)
    fig.patch.set_facecolor(surface)
    ax.set_facecolor(surface)
    ax.axhline(0, color=grid, linewidth=1.2, zorder=1)

    for (label, s), color in zip(series, colors):
        good = s["good"]
        t, offset = s["t"][good], s["offset"][good]
        ax.scatter(t, offset, s=9, color=color, linewidths=0, alpha=0.7, zorder=3,
                   label=f"{label}:  median {s['median_ms']:.0f} ms, sd {s['std_ms']:.0f} ms, "
                         f"drift {s['drift_ms_per_min']:+.1f} ms/min, n={s['n'] - s['misread']}")
        slope, intercept = s["fit"]
        ends = np.array([t.min(), t.max()])
        ax.plot(ends, slope * ends + intercept, color=color, linewidth=2, zorder=4)

    ax.set_xlabel("Seconds since first reading", color=ink_secondary)
    ax.set_ylabel("Delta (ms)", color=ink_secondary)
    ax.grid(axis="y", color=grid, linewidth=0.8, zorder=0)
    ax.tick_params(colors=ink_secondary, length=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(grid)
    ax.legend(loc="upper left", bbox_to_anchor=(0, -0.14), frameon=False, fontsize=9,
              labelcolor=ink, markerscale=2.5)

    fig.suptitle(title, x=0.01, ha="left", color=ink, fontsize=13, fontweight="bold")
    fig.tight_layout()
    fig.savefig(path, facecolor=surface)
    plt.close(fig)


def load_cache(path):
    with open(path) as handle:
        return [(int(r["frame"]), float(r["clip_seconds"]), int(r["burned_in_ms"]), int(r["filmed_ms"]))
                for r in csv.DictReader(handle)]


def save_cache(path, rows):
    with open(path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["frame", "clip_seconds", "burned_in_ms", "filmed_ms"])
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("clip", type=Path, help="TimestampCam (phone) recording")
    parser.add_argument("mac_clip", type=Path, nargs="?", help="timestampcap (Mac) recording of the same clock")
    parser.add_argument("--every", type=int, default=1, help="read every Nth frame (default: all)")
    parser.add_argument("--redo", action="store_true", help="re-read the video even if a cache exists")
    args = parser.parse_args()

    # Fail fast: check everything cheap before minutes of text recognition.
    clips = [c for c in (args.clip, args.mac_clip) if c]
    for clip in clips:
        if not clip.is_file():
            raise SystemExit(f"not found: {clip}")
    import matplotlib  # noqa: F401  -- plotting is the last step; don't discover it's missing then
    caches = {clip: clip.with_suffix(".offsets.csv") for clip in clips}
    to_read = [clip for clip in clips if args.redo or not caches[clip].exists()]

    for clip in to_read:
        print(f"probing {clip.name} ...")
        probe, _ = read_offsets(clip, PROBE_EVERY, PROBE_FRAMES)
        if not probe:
            raise SystemExit(f"{clip.name}: none of the first {PROBE_FRAMES} frames had both a burned-in "
                             "and a filmed timestamp, so the full read would fail too. Stopping.")
        print(f"  ok: {len(probe)} readable, first offset {probe[0][2] - probe[0][3]} ms")

    readings = []
    for clip in clips:
        if clip in to_read:
            print(f"reading {clip.name} ...")
            rows, unreadable = read_offsets(clip, args.every)
            save_cache(caches[clip], rows)
            print(f"{len(rows)} frames read, {unreadable} unreadable -> {caches[clip]}")
        else:
            rows = load_cache(caches[clip])
            print(f"using cached readings from {caches[clip]}")
        if len(rows) < 3:
            raise SystemExit(f"{clip.name}: only {len(rows)} readable frames; need at least 3.")
        readings.append(rows)

    if args.mac_clip:
        series = compare(*readings)
        title = "Phone and Mac timestamps against the same msclock.py"
        plot_path = args.clip.with_suffix(".comparison.png")
    else:
        series = [("Burned-in − filmed clock", summarize(readings[0]))]
        title = "TimestampCam label vs filmed msclock.py"
        plot_path = args.clip.with_suffix(".offsets.png")

    print()
    for label, s in series:
        print(f"{label}: median {s['median_ms']:.1f} ms, sd {s['std_ms']:.1f} ms, "
              f"drift {s['drift_ms_per_min']:+.2f} ms/min, "
              f"{s['n'] - s['misread']} used ({s['misread']} misreads > {MISREAD_MS} ms from median)")

    plot_offsets(series, title, plot_path)
    print(f"\nplot -> {plot_path}")


if __name__ == "__main__":
    main()
