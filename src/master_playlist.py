"""
Master HLS Playlist Generator
Creates master.m3u8 for all channels
"""

import logging
from pathlib import Path
from typing import List

logger = logging.getLogger("master")

M3U_HEADER = """#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
"""

class MasterPlaylistGenerator:
    """Generates master.m3u8 for all channels"""

    def __init__(self, output_path: Path = Path("/var/www/html/master.m3u8")):
        self.output_path = output_path
        # Ensure directory exists
        self.output_path.parent.mkdir(parents=True, exist_ok=True)

    async def generate(self, channels: List[dict]):
        """Generate master playlist"""
        lines = [M3U_HEADER]

        for channel in channels:
            name = channel.get("name", "Unknown").replace('"', "'")
            channel_id = channel.get("id", "")
            
            lines.append(f'#EXTINF:-1 tvg-id="{channel_id}" tvg-name="{name}",{name}')
            lines.append(f"/hls/{channel_id}/stream.m3u8")

        lines.append("#EXT-X-ENDLIST")

        content = "\n".join(lines)
        
        # Write atomically
        temp_path = self.output_path.with_suffix(".tmp")
        temp_path.write_text(content)
        temp_path.rename(self.output_path)
        
        # Ensure permissions
        self.output_path.chmod(0o644)
        
        logger.info(f"Generated master playlist with {len(channels)} channels")
