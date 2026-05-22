"""
Nginx RTMP Controller
Manages nginx process lifecycle
"""

import asyncio
import logging
from pathlib import Path

logger = logging.getLogger("nginx")

class NginxController:
    """Controls nginx RTMP server"""

    def __init__(
        self,
        nginx_bin: str = "/usr/local/nginx/sbin/nginx",
        config_path: str = "/app/config/nginx.conf",
        pid_file: str = "/var/run/nginx.pid"
    ):
        self.nginx_bin = nginx_bin
        self.config_path = config_path
        self.pid_file = pid_file
        self._started = False

    async def start(self):
        """Start nginx"""
        if self._started:
            return

        # Ensure directories exist
        Path("/tmp/hls").mkdir(parents=True, exist_ok=True)
        Path("/var/log/nginx").mkdir(parents=True, exist_ok=True)

        # Test config
        proc = await asyncio.create_subprocess_exec(
            self.nginx_bin, "-t",
            "-c", self.config_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await proc.communicate()

        if proc.returncode != 0:
            logger.error(f"Nginx config error: {stderr.decode()}")
            raise RuntimeError(f"Nginx config test failed: {stderr.decode()}")

        # Start nginx
        proc = await asyncio.create_subprocess_exec(
            self.nginx_bin,
            "-c", self.config_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        await proc.communicate()

        if proc.returncode == 0:
            self._started = True
            logger.info("Nginx started successfully")
        else:
            raise RuntimeError("Failed to start nginx")

    async def stop(self):
        """Stop nginx"""
        if not self._started:
            return

        try:
            proc = await asyncio.create_subprocess_exec(
                self.nginx_bin, "-s", "quit",
                "-c", self.config_path,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            await asyncio.wait_for(proc.communicate(), timeout=10)
        except Exception as e:
            logger.warning(f"Error stopping nginx: {e}")

        self._started = False
      
