"""
Master HLS Playlist Generator
"""

import logging
from pathlib import Path
from typing import List

logger = logging.getLogger("master")

M3U_HEADER = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n"

class MasterPlaylistGenerator:
    def __init__(self, output_path: Path = Path("/var/www/html/master.m3u8")):
        self.output_path = output_path
        self.output_path.parent.mkdir(parents=True, exist_ok=True)

    def _get(self, obj, key: str, default=None):
        """Safely get value from dict or dataclass"""
        if hasattr(obj, 'get'):
            return obj.get(key, default)
        return getattr(obj, key, default)

    async def generate(self, channels: List):
        lines = [M3U_HEADER]
        for ch in channels:
            name = self._get(ch, "name", "Unknown")
            name = str(name).replace('"', "'")
            channel_id = self._get(ch, "id", "") or self._get(ch, "url", "")
            
            lines.append(f"#EXTINF:-1 tvg-id=\"{channel_id}\" tvg-name=\"{name}\",{name}")
            lines.append(f"/hls/{channel_id}/stream.m3u8")
        
        lines.append("#EXT-X-ENDLIST")
        content = "\n".join(lines)
        
        temp_path = self.output_path.with_suffix(".tmp")
        temp_path.write_text(content)
        temp_path.rename(self.output_path)
        self.output_path.chmod(0o644)
        
        logger.info(f"Generated master playlist with {len(channels)} channels")
