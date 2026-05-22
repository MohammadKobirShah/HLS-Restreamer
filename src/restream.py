#!/usr/bin/env python3
"""
RESTREAM-HLS - Production Restreamer
Simple, reliable version
"""

import asyncio
import signal
import sys
import logging
from pathlib import Path

# Remove uvloop - use standard asyncio
# import uvloop
# uvloop.install()

from .config import Config
from .parser import M3UParser
from .ffmpeg_manager import FFmpegManager
from .nginx_controller import NginxController
from .master_playlist import MasterPlaylistGenerator

logger = logging.getLogger("restream")

class RestreamerApp:
    """Main application orchestrator"""

    def __init__(self):
        self.config = Config.from_env()
        self.parser = M3UParser()
        self.manager = FFmpegManager(
            max_concurrent=self.config.max_concurrent,
            log_dir=Path("/var/log/ffmpeg")
        )
        self.nginx = NginxController()
        self.master_gen = MasterPlaylistGenerator(
            output_path=Path("/var/www/html/master.m3u8")
        )
        self.running = True
        self.channels: dict = {}

    async def start(self):
        """Start the application"""
        print("\n🚀 RESTREAM-HLS Starting...\n")

        # Verify nginx is running (started by entrypoint.sh)
        await self.nginx.start()

        # Initial sync
        await self.sync_channels()

        print("✅ Restreamer ready!\n")

        # Keep running
        while self.running:
            await asyncio.sleep(self.config.refresh_interval)
            await self.sync_channels()

    async def stop(self):
        """Graceful shutdown"""
        print("\n⚠️ Shutting down...")
        self.running = False

        await self.manager.stop_all()
        await self.nginx.stop()

        print("❌ Stopped")
        sys.exit(0)

    async def sync_channels(self):
        """Sync channels from source playlist"""
        try:
            print(f"📡 Fetching playlist...")
            channels = await self.parser.parse(self.config.source_url)

            if not channels:
                print("⚠️ No channels found!")
                return

            # Update master playlist
            await self.master_gen.generate(channels)

            # Start new channels
            started = 0
            for channel in channels:
                channel_id = channel["id"]
                if channel_id not in self.channels:
                    success = await self.manager.start(channel)
                    if success:
                        self.channels[channel_id] = channel
                        started += 1

            # Stop removed channels
            current_ids = {c["id"] for c in channels}
            for channel_id in list(self.channels.keys()):
                if channel_id not in current_ids:
                    await self.manager.stop(channel_id)
                    del self.channels[channel_id]

            print(f"✓ {len(channels)} channels | Started: {started}")

        except Exception as e:
            print(f"❌ Sync error: {e}")
            logger.exception("Sync error")

async def main():
    """Entry point"""
    app = RestreamerApp()

    # Setup signal handlers
    loop = asyncio.get_running_loop()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(app.stop()))

    try:
        await app.start()
    except Exception as e:
        logger.exception("Fatal error")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())
