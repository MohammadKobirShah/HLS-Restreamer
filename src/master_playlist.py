"""
Master HLS Playlist Generator
Creates multi-bitrate master playlist for all channels
"""

import logging
from pathlib import Path
from typing import List

logger = logging.getLogger("master")

# M3U8 header template
M3U_HEADER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
"""

CHANNEL_TEMPLATE = """#EXTINF:-1 tvg-id="{tvg_id}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}",{name}
{path}/{id}/stream.m3u8"""

class MasterPlaylistGenerator:
    """Generates master.m3u8 for all channels"""

    def __init__(self, output_path: Path):
        self.output_path = output_path

    async def generate(self, channels: List[dict]):
        """Generate master playlist"""
        lines = [M3U_HEADER]

        for channel in channels:
            # Sanitize name
            name = channel.get("name", "Unknown").replace('"', "'")
            channel_id = channel.get("id", "")
            tvg_id = channel.get("tvg_id", channel_id)
            logo = channel.get("logo", "")
            group = channel.get("group", "General")

            lines.append(CHANNEL_TEMPLATE.format(
                tvg_id=tvg_id,
                name=name,
                logo=logo,
                group=group,
                path="/hls",
                id=channel_id
            ))

        content = "\n".join(lines)

        # Write atomically
        temp_path = self.output_path.with_suffix(".tmp")
        temp_path.write_text(content)
        temp_path.rename(self.output_path)

        logger.info(f"Generated master playlist with {len(channels)} channels")
