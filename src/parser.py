from dataclasses import dataclass, field, asdict

@dataclass
class Channel:
    """Channel data structure with dict-like access"""
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
            import hashlib
            self.id = hashlib.md5(self.url.encode()).hexdigest()[:12]

    def get(self, key: str, default=None):
        """Allow dict-like access"""
        return getattr(self, key, default)

    def __getitem__(self, key: str):
        """Allow bracket access"""
        return getattr(self, key)

    def to_dict(self) -> dict:
        """Convert to dictionary"""
        return asdict(self)
