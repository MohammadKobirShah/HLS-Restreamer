"""
FFmpeg Process Manager with async control
Handles thousands of concurrent streams
"""

import asyncio
import subprocess
import signal
import time
import logging
from pathlib import Path
from typing import Optional
from dataclasses import dataclass
from datetime import datetime
from collections import defaultdict

logger = logging.getLogger("ffmpeg")

@dataclass
class FFmpegInstance:
    """Single ffmpeg process instance"""
    channel_id: str
    channel_name: str
    url: str
    pid: Optional[int] = None
    process: Optional[asyncio.subprocess.Process] = None
    started_at: Optional[datetime] = None
    restart_count: int = 0
    bitrate: str = "N/A"

class FFmpegManager:
    """
    Manages multiple ffmpeg processes for restreaming.
    Features:
    - Async process control
    - Automatic restart on failure
    - Per-channel logging
    - Resource limits
    """

    def __init__(
        self,
        max_concurrent: int = 100,
        log_dir: Path = Path("/var/log/ffmpeg"),
        hls_base: str = "rtmp://127.0.0.1:1935/mylive"
    ):
        self.max_concurrent = max_concurrent
        self.log_dir = log_dir
        self.hls_base = hls_base

        self.instances: dict[str, FFmpegInstance] = {}
        self.restart_queue: asyncio.Queue = asyncio.Queue()
        self._running = True

        # Ensure log directory exists
        self.log_dir.mkdir(parents=True, exist_ok=True)

    async def start(self, channel: dict) -> bool:
        """Start ffmpeg for a channel"""
        channel_id = channel["id"]
        url = channel["url"]
        name = channel["name"]

        if len(self.instances) >= self.max_concurrent:
            logger.warning(f"Max concurrent reached ({self.max_concurrent}), skipping {name}")
            return False

        if channel_id in self.instances:
            logger.debug(f"Channel {name} already running")
            return True

        instance = FFmpegInstance(
            channel_id=channel_id,
            channel_name=name,
            url=url
        )

        try:
            await self._spawn(instance)
            self.instances[channel_id] = instance
            logger.info(f"Started: {name} (PID: {instance.pid})")
            return True
        except Exception as e:
            logger.error(f"Failed to start {name}: {e}")
            return False

    async def _spawn(self, instance: FFmpegInstance):
        """Spawn ffmpeg process"""
        log_file = self.log_dir / f"{instance.channel_id}.log"

        # FFmpeg command - NO TRANSCODING
        cmd = [
            "ffmpeg",
            # Reconnection flags
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "10",
            # Input
            "-i", instance.url,
            # No transcoding - pure remux
            "-c", "copy",
            "-bsf:v", "h264_mp4toannexb",
            "-f", "flv",
            # Output to nginx RTMP
            f"{self.hls_base}/{instance.channel_id}"
        ]

        # Start process
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            log_file=open(log_file, "ab") if log_file else asyncio.subprocess.DEVNULL
        )

        instance.process = process
        instance.pid = process.pid
        instance.started_at = datetime.now()

        # Monitor process
        asyncio.create_task(self._monitor(instance))

    async def _monitor(self, instance: FFmpegInstance):
        """Monitor ffmpeg process, restart if needed"""
        while self._running and instance.channel_id in self.instances:
            try:
                # Wait for process to exit
                returncode = await instance.process.wait()

                if not self._running:
                    break

                # Process died - schedule restart
                instance.restart_count += 1
                logger.warning(
                    f"Channel {instance.channel_name} died (exit {returncode}), "
                    f"restarting (attempt {instance.restart_count})..."
                )

                # Exponential backoff
                delay = min(60, 2 ** instance.restart_count)
                await asyncio.sleep(delay)

                # Restart
                if instance.channel_id in self.instances:
                    try:
                        await self._spawn(instance)
                        logger.info(f"Restarted: {instance.channel_name}")
                    except Exception as e:
                        logger.error(f"Restart failed for {instance.channel_name}: {e}")

            except asyncio.CancelledError:
                break

    async def stop(self, channel_id: str):
        """Stop ffmpeg for a channel"""
        if channel_id not in self.instances:
            return

        instance = self.instances.pop(channel_id)

        try:
            if instance.process:
                instance.process.terminate()
                try:
                    await asyncio.wait_for(
                        instance.process.wait(),
                        timeout=5.0
                    )
                except asyncio.TimeoutError:
                    instance.process.kill()
        except ProcessLookupError:
            pass

        logger.info(f"Stopped: {instance.channel_name}")

    async def stop_all(self):
        """Stop all ffmpeg processes"""
        self._running = False
        tasks = [
            self.stop(ch_id)
            for ch_id in list(self.instances.keys())
        ]
        await asyncio.gather(*tasks, return_exceptions=True)

    async def get_status(self) -> dict:
        """Get status of all channels"""
        status = {}
        for ch_id, instance in self.instances.items():
            uptime = "N/A"
            if instance.started_at:
                delta = datetime.now() - instance.started_at
                hours, remainder = divmod(int(delta.total_seconds()), 3600)
                minutes, seconds = divmod(remainder, 60)
                uptime = f"{hours}h {minutes}m"

            status[ch_id] = {
                "name": instance.channel_name,
                "pid": instance.pid,
                "running": instance.process is not None and instance.process.returncode is None,
                "started_at": instance.started_at,
                "uptime": uptime,
                "restart_count": instance.restart_count,
                "bitrate": instance.bitrate
            }
        return status
