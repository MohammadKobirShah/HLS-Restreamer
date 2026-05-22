import os
from dataclasses import dataclass

@dataclass
class Config:
    """Application configuration"""

    source_url: str = os.getenv("SOURCE_URL", "https://raw.githubusercontent.com/MohammadKobirShah/iptvx26/refs/heads/main/test.m3u")
    source_timeout: int = int(os.getenv("SOURCE_TIMEOUT", "30"))
    http_port: int = int(os.getenv("PORT", "8080"))
    rtmp_port: int = int(os.getenv("NGINX_RTMP_PORT", "1935"))
    hls_fragment: int = int(os.getenv("HLS_FRAGMENT", "10"))
    hls_playlist_length: int = int(os.getenv("HLS_PLIST_LENGTH", "15"))
    hls_path: str = "/tmp/hls"
    max_concurrent: int = int(os.getenv("MAX_CONCURRENT", "50"))
    refresh_interval: int = int(os.getenv("CHANNEL_REFRESH", "60"))
    log_level: str = os.getenv("LOG_LEVEL", "INFO")

    @classmethod
    def from_env(cls) -> "Config":
        return cls()
