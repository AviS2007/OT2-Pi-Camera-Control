#!/usr/bin/env python3
"""
Headless recorder: record every attached Pi camera to .mp4 at once.

  record.py                 record until Ctrl-C
  record.py -d 60           record for 60 seconds
  record.py -d 60 -n run7   files named <ts>_run7_cam<n>_<model>.mp4
  record.py --size 1280x720 --fps 30 --bitrate 6000000   (default: --size auto, --quality very_high)

Files land in ~/recordings by default. Use camserver.py instead if you also want a live view.
"""
import argparse
import datetime as dt
import os
import shutil
import signal
import sys
import time
from pathlib import Path

from libcamera import Transform
from picamera2 import Picamera2
from picamera2.encoders import H264Encoder, Quality
from picamera2.outputs import FfmpegOutput, FileOutput

MODEL_NAMES = {"imx219": "CamV2", "imx708": "CamV3Wide", "imx477": "HQ", "ov5647": "CamV1"}


def pick_size(picam, size, fps):
    """size=None: largest full-field-of-view sensor mode that can run at fps (no cropped modes)."""
    if size is not None:
        return size, None
    modes = picam.sensor_modes
    fw, fh = max(m["crop_limits"][2] for m in modes), max(m["crop_limits"][3] for m in modes)
    full = [m for m in modes if tuple(m["crop_limits"]) == (0, 0, fw, fh)]
    ok = [m for m in full if m["fps"] >= fps] or full
    best = max(ok, key=lambda m: m["size"][0] * m["size"][1])
    return tuple(best["size"]), {"output_size": tuple(best["size"]), "bit_depth": best["bit_depth"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-d", "--duration", type=float, default=0, help="seconds (0 = until Ctrl-C)")
    ap.add_argument("-n", "--name", default="", help="tag to put in the filename")
    ap.add_argument("--size", default="auto", help="WxH, or auto = largest full-view sensor mode at --fps")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--quality", default="very_high", choices=[q.name.lower() for q in Quality])
    ap.add_argument("--bitrate", type=int, default=0, help="fixed bitrate (0 = derive from --quality)")
    ap.add_argument("--outdir", default=os.path.expanduser("~/recordings"))
    ap.add_argument("--cams", default="", help="comma list of camera indexes (default: all)")
    ap.add_argument("--rotate180", default="0,1", help="comma list of camera indexes mounted upside down (default: 0,1)")
    a = ap.parse_args()
    flipped = {int(x) for x in a.rotate180.split(",") if x.strip()}

    size = None if a.size.lower() == "auto" else tuple(int(x) for x in a.size.lower().split("x"))
    quality = Quality[a.quality.upper()]
    outdir = Path(a.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    infos = Picamera2.global_camera_info()
    if not infos:
        print("No cameras detected (try: rpicam-hello --list-cameras)", file=sys.stderr)
        sys.exit(1)
    wanted = {int(x) for x in a.cams.split(",") if x.strip()} or {i["Num"] for i in infos}
    have_ffmpeg = shutil.which("ffmpeg") is not None
    if not have_ffmpeg:
        print("ffmpeg not installed: writing raw .h264 (sudo apt install ffmpeg for .mp4)", file=sys.stderr)

    ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    tag = f"_{a.name}" if a.name else ""
    cams = []
    for info in infos:
        n = info["Num"]
        if n not in wanted:
            continue
        model = info.get("Model", "unknown")
        base = outdir / f"{ts}{tag}_cam{n}_{MODEL_NAMES.get(model, model)}"
        if have_ffmpeg:
            path, out = base.with_suffix(".mp4"), FfmpegOutput(str(base.with_suffix(".mp4")))
        else:
            path, out = base.with_suffix(".h264"), FileOutput(str(base.with_suffix(".h264")))
        cam = Picamera2(camera_num=n)
        rot = n in flipped
        wh, sensor = pick_size(cam, size, a.fps)
        cam.configure(cam.create_video_configuration(main={"size": wh, "format": "YUV420"}, sensor=sensor,
                                                     controls={"FrameRate": a.fps},
                                                     transform=Transform(hflip=rot, vflip=rot)))
        cam.start_recording(H264Encoder(bitrate=a.bitrate or None), out, quality=quality)
        print(f"cam{n} ({model}) {wh[0]}x{wh[1]}@{a.fps} {a.quality} -> {path}")
        cams.append(cam)

    stop = False

    def _sig(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    t0 = time.monotonic()
    while not stop and (a.duration <= 0 or time.monotonic() - t0 < a.duration):
        time.sleep(0.2)

    for cam in cams:
        cam.stop_recording()
        cam.close()
    print(f"done after {time.monotonic() - t0:.1f}s")


if __name__ == "__main__":
    main()
