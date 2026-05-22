    async def sync_channels(self):
        """Sync channels from source playlist"""
        try:
            print(f"📡 Fetching playlist...")
            channels = await self.parser.parse(self.config.source_url)

            if not channels:
                print("⚠️ No channels found!")
                return

            # Update master playlist
            await self.master_gen.generate(channels)

            # Start new channels
            started = 0
            for channel in channels:
                channel_id = getattr(channel, 'id', None) or (channel.get('id') if hasattr(channel, 'get') else None)
                if channel_id and channel_id not in self.channels:
                    success = await self.manager.start(channel)
                    if success:
                        self.channels[channel_id] = channel
                        started += 1

            # Stop removed channels
            current_ids = set()
            for ch in channels:
                cid = getattr(ch, 'id', None) or (ch.get('id') if hasattr(ch, 'get') else None)
                if cid:
                    current_ids.add(cid)
            
            for channel_id in list(self.channels.keys()):
                if channel_id not in current_ids:
                    await self.manager.stop(channel_id)
                    del self.channels[channel_id]

            print(f"✓ {len(channels)} channels | Started: {started}")

        except Exception as e:
            print(f"❌ Sync error: {e}")
            import traceback
            traceback.print_exc()
