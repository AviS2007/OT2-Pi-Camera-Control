#!/usr/bin/env python3
"""
Dual Pi Camera server for the OT-2 Pi 5.

- Opens every attached CSI camera (Camera Module 2 / IMX219 and Camera Module 3 Wide / IMX708).
- Serves live MJPEG previews over HTTP and records H.264 -> .mp4 on demand.
- Recording and streaming run at the same time: recording uses the full-res "main"
  stream, the preview uses the small "lores" stream, so streaming never degrades the file.

HTTP API (default port 8080):
  GET /                      index page with both live previews + record buttons
  GET /cam/<n>.mjpg          MJPEG stream for camera n (0 or 1)
  GET /cam/<n>.jpg           single JPEG snapshot
  GET /status                JSON status (cameras, recording state, files)
  GET /record/start[?name=x] start recording ALL cameras to <outdir>/<ts>_<name>_cam<n>_<model>.mp4
  GET /record/stop           stop recording
  GET /files                 JSON list of recordings

Usage:  camserver.py [--port 8080] [--size auto|1280x720] [--fps 30] [--quality very_high]
                     [--bitrate N] [--rotate180 0,1] [--outdir ~/recordings] [--autorecord]
"""
import argparse
import datetime as dt
import io
import json
import logging
import os
import shutil
import signal
import socketserver
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from http import server
from pathlib import Path
from urllib.parse import urlparse, parse_qs

from libcamera import Transform
from picamera2 import Picamera2
from picamera2.encoders import H264Encoder, MJPEGEncoder, Quality
from picamera2.outputs import FfmpegOutput, FileOutput

log = logging.getLogger("camserver")
HAVE_FFMPEG = shutil.which("ffmpeg") is not None

MODEL_NAMES = {
    "imx219": "CamV2",
    "imx708": "CamV3Wide",
    "imx477": "HQ",
    "ov5647": "CamV1",
}


class StreamingOutput(io.BufferedIOBase):
    """Holds the latest MJPEG frame; wakes HTTP clients when a new one arrives."""

    def __init__(self):
        self.frame = None
        self.condition = threading.Condition()

    def write(self, buf):
        with self.condition:
            self.frame = buf
            self.condition.notify_all()


class Cam:
    """One camera. start/stop_recording are safe to call from any thread.

    picamera2's FfmpegOutput spawns ffmpeg with PR_SET_PDEATHSIG, which Linux ties to the
    *thread* that forked it. A per-request HTTP handler thread exits right after replying and
    ffmpeg would be killed instantly (no file written). So all encoder start/stop calls are
    funnelled through one long-lived worker thread.
    """

    def __init__(self, index, info, size, fps, lores, outdir, bitrate, quality, preview_quality, rotate180=False):
        self.index = index
        self.model = info.get("Model", "unknown")
        self.name = MODEL_NAMES.get(self.model, self.model)
        self.outdir = Path(outdir)
        self.bitrate = bitrate or None          # None -> derive from quality
        self.quality = quality
        self.preview_quality = preview_quality
        self.rotate180 = rotate180
        self.recording_file = None
        self.lock = threading.Lock()
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix=f"cam{index}-ctl")

        self.picam = Picamera2(camera_num=index)
        size, sensor = pick_size(self.picam, size, fps)
        if lores is None:   # same aspect as the recording, 640 wide
            lores = (640, (640 * size[1] // size[0]) & ~1)
        self.size, self.lores, self.fps = size, lores, fps
        cfg = self.picam.create_video_configuration(
            main={"size": size, "format": "YUV420"},
            lores={"size": lores, "format": "YUV420"},
            sensor=sensor,
            controls={"FrameRate": fps},
            transform=Transform(hflip=rotate180, vflip=rotate180),   # 180 deg for upside-down mounting
        )
        self.picam.configure(cfg)

        self.preview = StreamingOutput()
        self.mjpeg = MJPEGEncoder()
        self.h264 = None
        self.picam.start()
        # MJPEG preview runs for the whole life of the server, from the small stream.
        self.picam.start_encoder(self.mjpeg, FileOutput(self.preview), quality=preview_quality, name="lores")
        log.info("cam%d: %s (%s) main=%s sensor=%s lores=%s fps=%s quality=%s preview=%s rotate180=%s", index,
                 self.model, self.name, size, (sensor or {}).get("output_size"), lores, fps, quality.name,
                 preview_quality.name, rotate180)

    def start_recording(self, tag):
        return self.worker.submit(self._start_recording, tag).result()

    def stop_recording(self):
        return self.worker.submit(self._stop_recording).result()

    def _start_recording(self, tag):
        with self.lock:
            if self.h264:
                return self.recording_file
            self.outdir.mkdir(parents=True, exist_ok=True)
            ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            tag = f"_{tag}" if tag else ""
            base = self.outdir / f"{ts}{tag}_cam{self.index}_{self.name}"
            self.h264 = H264Encoder(bitrate=self.bitrate)
            if HAVE_FFMPEG:
                path, out = base.with_suffix(".mp4"), FfmpegOutput(str(base.with_suffix(".mp4")))
            else:  # no ffmpeg (Pi OS Lite): raw H.264 elementary stream, remux later on the PC
                path, out = base.with_suffix(".h264"), FileOutput(str(base.with_suffix(".h264")))
            self.picam.start_encoder(self.h264, out, quality=self.quality, name="main")
            self.recording_file = str(path)
            log.info("cam%d: recording -> %s", self.index, path)
            return self.recording_file

    def _stop_recording(self):
        with self.lock:
            if not self.h264:
                return None
            self.picam.stop_encoder(self.h264)
            path, self.h264, self.recording_file = self.recording_file, None, None
            log.info("cam%d: stopped %s", self.index, path)
            return path

    def snapshot(self):
        with self.preview.condition:
            self.preview.condition.wait(timeout=2)
            return self.preview.frame or b""

    def close(self):
        self.stop_recording()
        try:
            self.picam.stop_encoder(self.mjpeg)
        except Exception:
            pass
        self.picam.stop()
        self.picam.close()
        self.worker.shutdown(wait=False)


INDEX_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>OT-2 Pi Cameras</title>
<style>body{font-family:system-ui;background:#111;color:#eee;margin:16px}
.row{display:flex;flex-wrap:wrap;gap:16px}.cam{flex:1 1 480px}img{width:100%%;background:#000;border-radius:6px}
button{font-size:16px;padding:8px 16px;margin:4px;border-radius:6px;border:0;cursor:pointer}
#rec{background:#c33;color:#fff}#stop{background:#555;color:#fff}pre{background:#222;padding:8px;border-radius:6px;white-space:pre-wrap}</style>
</head><body><h2>OT-2 Pi Cameras</h2>
<div><button id="rec" onclick="go('/record/start')">&#9679; Record all</button>
<button id="stop" onclick="go('/record/stop')">&#9632; Stop</button>
<button onclick="refresh()">Refresh status</button></div>
<div class="row">%s</div><pre id="status"></pre>
<script>
async function go(u){await fetch(u);refresh();}
async function refresh(){const r=await fetch('/status');document.getElementById('status').textContent=JSON.stringify(await r.json(),null,2);}
refresh();setInterval(refresh,3000);
</script></body></html>"""


def make_handler(cams, outdir):
    class Handler(server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, fmt, *args):
            log.debug(fmt, *args)

        def _json(self, obj, code=200):
            body = json.dumps(obj, indent=1).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _status(self):
            out = Path(outdir)
            files = sorted(p.name for p in out.iterdir() if p.suffix in (".mp4", ".h264")) if out.exists() else []
            return {
                "cameras": [{"index": c.index, "model": c.model, "name": c.name,
                             "size": list(c.size), "fps": c.fps, "quality": c.quality.name,
                             "rotate180": c.rotate180, "recording": c.recording_file} for c in cams],
                "recording": any(c.recording_file for c in cams),
                "outdir": str(outdir),
                "files": files[-20:],
                "time": dt.datetime.now().isoformat(timespec="seconds"),
            }

        def do_GET(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            path = u.path

            if path == "/":
                tiles = "".join(
                    f'<div class="cam"><h3>cam{c.index}: {c.name} ({c.model})</h3>'
                    f'<img src="/cam/{c.index}.mjpg"></div>' for c in cams)
                body = (INDEX_HTML % tiles).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

            if path == "/status":
                return self._json(self._status())

            if path == "/files":
                return self._json(self._status()["files"])

            if path == "/record/start":
                tag = q.get("name", [""])[0].replace("/", "_")
                return self._json({"started": [c.start_recording(tag) for c in cams]})

            if path == "/record/stop":
                return self._json({"stopped": [c.stop_recording() for c in cams]})

            if path.startswith("/cam/"):
                try:
                    n = int(path[5:].split(".")[0])
                    cam = cams[n]
                except (ValueError, IndexError):
                    return self._json({"error": "no such camera"}, 404)

                if path.endswith(".jpg"):
                    frame = cam.snapshot()
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(frame)))
                    self.end_headers()
                    self.wfile.write(frame)
                    return

                if path.endswith(".mjpg"):
                    self.send_response(200)
                    self.send_header("Age", "0")
                    self.send_header("Cache-Control", "no-cache, private")
                    self.send_header("Pragma", "no-cache")
                    self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=FRAME")
                    self.end_headers()
                    try:
                        while True:
                            with cam.preview.condition:
                                cam.preview.condition.wait()
                                frame = cam.preview.frame
                            self.wfile.write(b"--FRAME\r\n")
                            self.send_header("Content-Type", "image/jpeg")
                            self.send_header("Content-Length", str(len(frame)))
                            self.end_headers()
                            self.wfile.write(frame)
                            self.wfile.write(b"\r\n")
                    except Exception as e:
                        log.debug("stream client %s left: %s", self.client_address, e)
                    return

            self._json({"error": "not found"}, 404)

    return Handler


class ThreadedServer(socketserver.ThreadingMixIn, server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def parse_size(s):
    if s.lower() == "auto":
        return None
    w, h = s.lower().split("x")
    return int(w), int(h)


def pick_size(picam, size, fps):
    """Recording size and sensor mode. size=None ("auto"): the largest sensor mode that keeps the
    full field of view (no crop) and can run at `fps`; e.g. V2 -> 1640x1232, Module 3 -> 2304x1296.
    Cropped modes like the V2's 1920x1080 are skipped: they throw away most of the view."""
    modes = picam.sensor_modes
    full_w = max(m["crop_limits"][2] for m in modes)
    full_h = max(m["crop_limits"][3] for m in modes)
    full = [m for m in modes if tuple(m["crop_limits"]) == (0, 0, full_w, full_h)]
    if size is not None:
        return size, None
    ok = [m for m in full if m["fps"] >= fps] or full
    best = max(ok, key=lambda m: m["size"][0] * m["size"][1])
    return tuple(best["size"]), {"output_size": tuple(best["size"]), "bit_depth": best["bit_depth"]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--size", default="auto", help="recording resolution, WxH or auto = largest full-view "
                    "sensor mode that reaches --fps (default auto)")
    ap.add_argument("--lores", default="auto", help="preview resolution (default auto: 640 wide, same aspect)")
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--quality", default="very_high", choices=[q.name.lower() for q in Quality],
                    help="encoder quality tier for recording and preview (default very_high)")
    ap.add_argument("--bitrate", type=int, default=0, help="fixed H.264 bitrate in bit/s (0 = derive from --quality)")
    ap.add_argument("--preview-quality", default="medium", choices=[q.name.lower() for q in Quality],
                    help="MJPEG live-preview quality (default medium; very_high is ~8 Mbit/s per camera over Wi-Fi)")
    ap.add_argument("--outdir", default=os.path.expanduser("~/recordings"))
    ap.add_argument("--autorecord", action="store_true", help="start recording as soon as the server starts")
    ap.add_argument("--rotate180", default="", help="comma list of camera indexes mounted upside down, e.g. 1")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    infos = Picamera2.global_camera_info()
    if not infos:
        log.error("No cameras detected. Check ribbon cables and `rpicam-hello --list-cameras`.")
        sys.exit(1)
    for i in infos:
        log.info("detected camera %s: %s", i.get("Num"), i.get("Model"))
    if not HAVE_FFMPEG:
        log.warning("ffmpeg not installed: recordings will be raw .h264 (sudo apt install ffmpeg for .mp4)")

    flipped = {int(x) for x in a.rotate180.split(",") if x.strip()}
    quality, pquality = Quality[a.quality.upper()], Quality[a.preview_quality.upper()]
    cams = [Cam(i.get("Num", n), i, parse_size(a.size), a.fps, parse_size(a.lores), a.outdir, a.bitrate, quality,
                pquality, rotate180=i.get("Num", n) in flipped)
            for n, i in enumerate(infos)]

    if a.autorecord:
        for c in cams:
            c.start_recording("auto")

    httpd = ThreadedServer(("", a.port), make_handler(cams, a.outdir))

    def shutdown(*_):
        log.info("shutting down")
        for c in cams:
            c.close()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    log.info("serving on http://0.0.0.0:%d/", a.port)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
