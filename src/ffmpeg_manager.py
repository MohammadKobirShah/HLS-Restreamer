    async def start(self, channel) -> bool:
        """Start ffmpeg for a channel"""
        channel_id = getattr(channel, 'id', None) or (channel.get('id') if hasattr(channel, 'get') else None)
        url = getattr(channel, 'url', None) or (channel.get('url') if hasattr(channel, 'get') else None)
        name = getattr(channel, 'name', None) or (channel.get('name') if hasattr(channel, 'get') else None) or 'Unknown'
        
        if not channel_id or not url:
            logger.error(f"Invalid channel: {channel}")
            return False

        if len(self.instances) >= self.max_concurrent:
            logger.warning(f"Max concurrent reached ({self.max_concurrent}), skipping {name}")
            return False

        if channel_id in self.instances:
            return True

        instance = FFmpegInstance(
            channel_id=channel_id,
            channel_name=name,
            url=url
        )

        try:
            await self._spawn(instance)
            self.instances[channel_id] = instance
            logger.info(f"Started: {name} (PID: {instance.pid})")
            return True
        except Exception as e:
            logger.error(f"Failed to start {name}: {e}")
            return False
