"""
M3U Parser for channel lists
"""

import re
import hashlib
import logging
from typing import List

try:
    import httpx
except ImportError:
    httpx = None

logger = logging.getLogger("parser")

class Channel:
    """Channel data structure"""
    def __init__(self, name: str, url: str, id: str = "", logo: str = "", group: str = ""):
        self.name = name
        self.url = url
        self.id = id or hashlib.md5(url.encode()).hexdigest()[:12]
        self.logo = logo
        self.group = group

    def get(self, key: str, default=None):
        return getattr(self, key, default)

class M3UParser:
    """Parses M3U playlists"""

    async def parse(self, url: str) -> List[Channel]:
        """Fetch and parse M3U playlist"""
        try:
            if httpx:
                async with httpx.AsyncClient(timeout=30) as client:
                    response = await client.get(url, follow_redirects=True)
                    content = response.text
            else:
                import urllib.request
                req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=30) as resp:
                    content = resp.read().decode("utf-8")

            return self._parse_content(content)

        except Exception as e:
            logger.error(f"Failed to fetch playlist: {e}")
            return []

    def _parse_content(self, content: str) -> List[Channel]:
        """Parse M3U content"""
        channels = []
        lines = content.splitlines()

        extinf = None
        for line in lines:
            line = line.strip()

            if line.startswith("#EXTINF:"):
                # Parse EXTINF line
                extinf = self._parse_extinf(line)

            elif line and not line.startswith("#"):
                # This is a URL
                if extinf and line.startswith("http"):
                    channel = Channel(
                        name=extinf.get("name", "Unknown"),
                        url=line,
                        logo=extinf.get("logo", ""),
                        group=extinf.get("group", "")
                    )
                    channels.append(channel)
                extinf = None

        logger.info(f"Parsed {len(channels)} channels")
        return channels

    def _parse_extinf(self, line: str) -> dict:
        """Parse EXTINF line"""
        data = {"name": "Unknown"}

        # Extract name after comma
        if "," in line:
            name = line.split(",", 1)[1].strip()
            # Remove quotes
            name = name.strip('"').strip("'")
            if name:
                data["name"] = name

        # Extract attributes
        if 'group-title="' in line:
            match = re.search(r'group-title="([^"]*)"', line)
            if match:
                data["group"] = match.group(1)

        if 'tvg-logo="' in line:
            match = re.search(r'tvg-logo="([^"]*)"', line)
            if match:
                data["logo"] = match.group(1)

        return data
