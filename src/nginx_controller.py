"""
Nginx RTMP Controller
Simply checks if nginx is running (entrypoint.sh starts it)
"""

import asyncio
import logging
from pathlib import Path

logger = logging.getLogger("nginx")

class NginxController:
    """Simply monitors nginx - it's started by entrypoint.sh"""

    def __init__(self):
        self._started = False

    async def start(self):
        """
        Entry point starts nginx, so we just verify it's running.
        """
        logger.info("Checking nginx status...")
        
        # Check if nginx is running
        proc = await asyncio.create_subprocess_exec(
            "pgrep", "-x", "nginx",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        await proc.communicate()
        
        if proc.returncode == 0:
            self._started = True
            logger.info("Nginx is running ✓")
        else:
            logger.warning("Nginx not detected - check entrypoint")
            # Don't fail, let the app continue
            self._started = True

    async def stop(self):
        """Stop nginx via signal"""
        logger.info("Stopping nginx...")
        try:
            proc = await asyncio.create_subprocess_exec(
                "nginx", "-s", "quit",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL
            )
            await asyncio.wait_for(proc.communicate(), timeout=5)
        except Exception as e:
            logger.warning(f"Error stopping nginx: {e}")
