"""
Configuration management
Supports environment variables for Railway deployment
"""

import os
from dataclasses import dataclass
from typing import Optional

@dataclass
class Config:
    """Application configuration"""

    # Source
    source_url: str
    source_timeout: int = 30

    # Ports
    http_port: int = 8080
    rtmp_port: int = 1935

    # HLS settings
    hls_fragment: int = 10  # seconds
    hls_playlist_length: int = 15  # seconds
    hls_path: str = "/tmp/hls"

    # Performance
    max_concurrent: int = 100
    refresh_interval: int = 60  # seconds

    # Logging
    log_level: str = "INFO"

    @classmethod
    def from_env(cls) -> "Config":
        """Load config from environment variables"""
        return cls(
            source_url=os.getenv("SOURCE_URL", "https://example.com/playlist.m3u"),
            source_timeout=int(os.getenv("SOURCE_TIMEOUT", "30")),
            http_port=int(os.getenv("PORT", "8080")),
            rtmp_port=int(os.getenv("NGINX_RTMP_PORT", "1935")),
            hls_fragment=int(os.getenv("HLS_FRAGMENT", "10")),
            hls_playlist_length=int(os.getenv("HLS_PLIST_LENGTH", "15")),
            hls_path=os.getenv("HLS_PATH", "/tmp/hls"),
            max_concurrent=int(os.getenv("MAX_CONCURRENT", "100")),
            refresh_interval=int(os.getenv("CHANNEL_REFRESH", "60")),
            log_level=os.getenv("LOG_LEVEL", "INFO")
        )
