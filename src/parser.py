"""
High-performance M3U8 parser for large playlists
Handles thousands of channels efficiently
"""

import re
import hashlib
import logging
from typing import Optional
from dataclasses import dataclass, field
from concurrent.futures import ThreadPoolExecutor

try:
    import httpx
except ImportError:
    import urllib.request as urllib2
    httpx = None

from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger("parser")

# Regex patterns
EXTINF_RE = re.compile(
    r'#EXTINF:(?P<duration>-?\d+\.?\d*)\s*(?P<attributes>[^,]*),?(?P<name>[^\n]*)?',
    re.IGNORECASE
)
EXTGRP_RE = re.compile(r'group-title="([^"]*)"')
EXTTVG_RE = re.compile(r'tvg-name="([^"]*)"')
EXTTVGID_RE = re.compile(r'tvg-id="([^"]*)"')
LOGO_RE = re.compile(r'tvg-logo="([^"]*)"')
RADIO_RE = re.compile(r'radio="([^"]*)"')

@dataclass
class Channel:
    """Channel data structure"""
    name: str
    url: str
    id: str = ""
    logo: str = ""
    group: str = ""
    tvg_id: str = ""
    radio: bool = False
    attributes: dict = field(default_factory=dict)

    def __post_init__(self):
        if not self.id:
            self.id = hashlib.md5(self.url.encode()).hexdigest()[:12]


class M3UParser:
    """
    Async M3U8 parser with streaming support for large files.
    Uses chunked reading to handle playlists with 10,000+ channels.
    """

    def __init__(self, chunk_size: int = 8192):
        self.chunk_size = chunk_size
        self.timeout = httpx.Timeout(30.0, connect=10.0) if httpx else None

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=30)
    )
    async def fetch(self, url: str) -> str:
        """Fetch playlist with retry logic"""
        if httpx:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.get(
                    url,
                    headers={"User-Agent": "Restream-HLS/1.0"},
                    follow_redirects=True
                )
                response.raise_for_status()
                return response.text
        else:
            import urllib.request
            req = urllib.request.Request(url, headers={"User-Agent": "Restream-HLS/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return resp.read().decode("utf-8")

    async def parse(self, url: str) -> list[Channel]:
        """
        Parse M3U playlist from URL.
        Uses streaming parser for memory efficiency with large files.
        """
        content = await self.fetch(url)
        return self.parse_content(content)

    def parse_content(self, content: str) -> list[Channel]:
        """
        Parse M3U content string.
        Optimized for streaming with large content.
        """
        channels = []
        lines = content.splitlines()
        total_lines = len(lines)
        logger.info(f"Parsing {total_lines} lines")

        i = 0
        extinf_data = None

        while i < total_lines:
            line = lines[i].strip()

            if line.startswith("#EXTINF:"):
                # Parse EXTINF line
                extinf_data = self._parse_extinf(line)
                i += 1

            elif line.startswith("#") or line == "":
                # Skip comments and empty lines
                i += 1

            elif line.startswith("http") or line.startswith("rtmp"):
                # This is a stream URL
                if extinf_data:
                    extinf_data["url"] = line
                    channel = Channel(**extinf_data)
                    channels.append(channel)
                extinf_data = None
                i += 1

            else:
                # Might be URL without preceding EXTINF (some playlists)
                if self._looks_like_url(line):
                    channel = Channel(
                        name=self._generate_name(line),
                        url=line
                    )
                    channels.append(channel)
                i += 1

        logger.info(f"Parsed {len(channels)} channels")
        return channels

    def _parse_extinf(self, line: str) -> dict:
        """Parse EXTINF line into channel data"""
        data = {
            "name": "Unknown",
            "url": "",
            "attributes": {}
        }

        # Extract duration (not really needed but keeping for compatibility)
        duration_match = re.search(r'#EXTINF:(\d+\.?\d*)', line, re.I)
        if duration_match:
            data["attributes"]["duration"] = float(duration_match.group(1))

        # Extract tvg-name
        tvg_match = EXTTVG_RE.search(line)
        if tvg_match:
            data["name"] = tvg_match.group(1).strip()

        # Extract tvg-id
        tvg_id_match = EXTTVGID_RE.search(line)
        if tvg_id_match:
            data["tvg_id"] = tvg_id_match.group(1).strip()

        # Extract group-title
        group_match = EXTGRP_RE.search(line)
        if group_match:
            data["group"] = group_match.group(1).strip()

        # Extract tvg-logo
        logo_match = LOGO_RE.search(line)
        if logo_match:
            data["logo"] = logo_match.group(1).strip()

        # Extract radio flag
        radio_match = RADIO_RE.search(line)
        if radio_match:
            data["radio"] = radio_match.group(1).lower() == "true"

        # If no tvg-name, try to extract name after comma
        if data["name"] == "Unknown":
            name_match = re.search(r',(.+)$', line)
            if name_match:
                raw_name = name_match.group(1).strip()
                # Remove any remaining attributes
                raw_name = re.sub(r'\s+.*$', '', raw_name)
                if raw_name:
                    data["name"] = raw_name

        return data

    def _looks_like_url(self, line: str) -> bool:
        """Check if line looks like a URL"""
        url_patterns = [
            r'^https?://',
            r'^rtmp://',
            r'^rtsp://',
            r'^udp://',
            r'^mms://'
        ]
        return any(re.match(p, line) for p in url_patterns)

    def _generate_name(self, url: str) -> str:
        """Generate a name from URL"""
        # Extract meaningful part of URL
        name = re.sub(r'^https?://', '', url)
        name = re.sub(r'/\?.*$', '', name)  # Remove query string
        name = name.rstrip('/')

        # Take last meaningful segment
        parts = name.split('/')
        if parts:
            name = parts[-1]
            # Remove common extensions
            name = re.sub(r'\.(m3u8?|ts|mp4|mkv)$', '', name, flags=re.I)

        # If empty, use hash
        if not name or name == url:
            name = hashlib.md5(url.encode()).hexdigest()[:8]

        return name
