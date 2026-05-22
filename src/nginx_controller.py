"""
Nginx Controller - Simply checks if nginx is running
"""

import asyncio
import logging

logger = logging.getLogger("nginx")

class NginxController:
    """Simply monitors nginx - it's started by entrypoint.sh"""

    def __init__(self):
        self._started = False

    async def start(self):
        """Verify nginx is running"""
        proc = await asyncio.create_subprocess_exec(
            "pgrep", "-x", "nginx",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )
        await proc.communicate()

        if proc.returncode == 0:
            self._started = True
            logger.info("Nginx is running ✓")
        else:
            logger.warning("Nginx not detected")
            self._started = True

    async def stop(self):
        """Stop nginx"""
        proc = await asyncio.create_subprocess_exec(
            "nginx", "-s", "quit",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL
        )
        try:
            await asyncio.wait_for(proc.communicate(), timeout=5)
        except:
            pass
