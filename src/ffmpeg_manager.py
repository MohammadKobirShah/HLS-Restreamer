"""
FFmpeg Process Manager
"""

import asyncio
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger("ffmpeg")

class FFmpegManager:
    """Manages ffmpeg processes for restreaming"""

    def __init__(self, max_concurrent: int = 50, log_dir: Path = Path("/var/log/ffmpeg"), hls_base: str = "rtmp://127.0.0.1:1935/mylive"):
        self.max_concurrent = max_concurrent
        self.log_dir = log_dir
        self.hls_base = hls_base
        self.instances = {}
        self._running = True

        self.log_dir.mkdir(parents=True, exist_ok=True)

    def _get_attr(self, obj, key, default=None):
        if hasattr(obj, 'get'):
            return obj.get(key, default)
        return getattr(obj, key, default)

    async def start(self, channel) -> bool:
        """Start ffmpeg for a channel"""
        channel_id = self._get_attr(channel, 'id', '')
        url = self._get_attr(channel, 'url', '')
        name = self._get_attr(channel, 'name', 'Unknown')

        if not channel_id or not url:
            logger.error(f"Invalid channel: {channel}")
            return False

        if len(self.instances) >= self.max_concurrent:
            logger.warning(f"Max concurrent reached ({self.max_concurrent}), skipping {name}")
            return False

        if channel_id in self.instances:
            return True

        # Start ffmpeg
        try:
            log_file = self.log_dir / f"{channel_id}.log"

            cmd = [
                "ffmpeg",
                "-reconnect", "1",
                "-reconnect_streamed", "1",
                "-reconnect_delay_max", "10",
                "-i", url,
                "-c", "copy",
                "-f", "flv",
                f"{self.hls_base}/{channel_id}"
            ]

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL
            )

            self.instances[channel_id] = {
                "pid": proc.pid,
                "name": name,
                "url": url
            }

            logger.info(f"Started: {name} (PID: {proc.pid})")
            return True

        except Exception as e:
            logger.error(f"Failed to start {name}: {e}")
            return False

    async def stop(self, channel_id: str):
        """Stop ffmpeg for a channel"""
        if channel_id not in self.instances:
            return

        instance = self.instances.pop(channel_id)

        try:
            import os
            os.kill(instance["pid"], 9)
        except:
            pass

        logger.info(f"Stopped: {instance['name']}")

    async def stop_all(self):
        """Stop all ffmpeg processes"""
        self._running = False
        for channel_id in list(self.instances.keys()):
            await self.stop(channel_id)
