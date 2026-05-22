#!/usr/bin/env python3
"""
RESTREAM-HLS - Production Restreamer
Handles unlimited channels with async processing
"""

import asyncio
import signal
import sys
import logging
from pathlib import Path
from typing import Optional
from contextlib import asynccontextmanager

import uvloop
from rich.console import Console
from rich.table import Table
from rich.live import Live

from .config import Config
from .parser import M3UParser
from .ffmpeg_manager import FFmpegManager
from .nginx_controller import NginxController
from .master_playlist import MasterPlaylistGenerator

uvloop.install()

console = Console()
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
        self.channels: dict[str, dict] = {}
        self.refresh_task: Optional[asyncio.Task] = None

    async def start(self):
        """Start the application"""
        console.print("\n[bold green]🚀 RESTREAM-HLS Starting...[/bold green]\n")

        # Start nginx RTMP server
        await self.nginx.start()

        # Initial sync
        await self.sync_channels()

        # Start background refresh
        self.refresh_task = asyncio.create_task(self.refresh_loop())

        # Start status display
        asyncio.create_task(self.status_loop())

        console.print("[bold green]✅ Restreamer ready![/bold green]\n")

        # Keep running
        while self.running:
            await asyncio.sleep(1)

    async def stop(self):
        """Graceful shutdown"""
        console.print("\n[bold yellow]⚠️ Shutting down...[/bold yellow]")
        self.running = False

        if self.refresh_task:
            self.refresh_task.cancel()

        await self.manager.stop_all()
        await self.nginx.stop()

        console.print("[bold red]❌ Stopped[/bold red]")
        sys.exit(0)

    async def sync_channels(self):
        """Sync channels from source playlist"""
        try:
            console.print(f"[cyan]📡 Fetching playlist from {self.config.source_url}[/cyan]")

            channels = await self.parser.parse(self.config.source_url)

            if not channels:
                console.print("[bold red]⚠️ No channels found![/bold red]")
                return

            # Update master playlist
            await self.master_gen.generate(channels)

            # Start new channels
            for channel in channels:
                channel_id = channel["id"]
                if channel_id not in self.channels:
                    await self.manager.start(channel)
                    self.channels[channel_id] = channel
                    console.print(f"  [green]+[/green] Started: {channel['name']}")

            # Stop removed channels
            current_ids = {c["id"] for c in channels}
            for channel_id in list(self.channels.keys()):
                if channel_id not in current_ids:
                    channel = self.channels.pop(channel_id)
                    await self.manager.stop(channel_id)
                    console.print(f"  [red]-[/red] Stopped: {channel['name']}")

            console.print(f"[green]✓ Synced {len(channels)} channels[/green]\n")

        except Exception as e:
            console.print(f"[bold red]❌ Sync error: {e}[/bold red]")
            logger.exception("Sync error")

    async def refresh_loop(self):
        """Periodically refresh channel list"""
        while self.running:
            try:
                await asyncio.sleep(self.config.refresh_interval)
                await self.sync_channels()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Refresh error: {e}")

    async def status_loop(self):
        """Display live status"""
        while self.running:
            try:
                await asyncio.sleep(5)
                status = await self.manager.get_status()

                table = Table(title="📺 Channel Status")
                table.add_column("Channel", style="cyan")
                table.add_column("Status", style="green")
                table.add_column("Uptime", style="yellow")
                table.add_column("Bitrate", style="magenta")

                for ch_id, info in status.items():
                    name = info.get("name", ch_id)
                    state = "🟢 Live" if info.get("running") else "🔴 Dead"
                    uptime = info.get("uptime", "-")
                    bitrate = info.get("bitrate", "-")
                    table.add_row(name, state, uptime, bitrate)

                console.print(table)

            except Exception:
                pass  # Ignore display errors


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
