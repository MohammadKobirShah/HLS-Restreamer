#!/usr/bin/env python3

import os
import time
import json
import logging
from datetime import datetime, timedelta
from pathlib import Path

CONFIG_FILE = 'config.json'
LOG_FILE = 'logs/cleanup.log'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)


class HLSCleanup:
    def __init__(self, config_path):
        with open(config_path, 'r') as f:
            self.config = json.load(f)

        self.segment_path = self.config['hls']['segmentPath']
        self.max_age = self.config['hls']['maxSegmentAge']
        self.interval = self.config['hls']['cleanupInterval']

        logger.info(f"Cleanup Service Started")
        logger.info(f"Segment Path: {self.segment_path}")
        logger.info(f"Max Segment Age: {self.max_age}s")
        logger.info(f"Cleanup Interval: {self.interval}s")

    def cleanup_old_segments(self):
        deleted_count = 0
        now = datetime.now()
        max_age_delta = timedelta(seconds=self.max_age)

        try:
            for root, dirs, files in os.walk(self.segment_path):
                for file in files:
                    if file.endswith('.ts'):
                        file_path = os.path.join(root, file)
                        mtime = datetime.fromtimestamp(os.path.getmtime(file_path))

                        if now - mtime > max_age_delta:
                            try:
                                os.remove(file_path)
                                deleted_count += 1
                            except OSError as e:
                                logger.error(f"Error deleting {file_path}: {e}")

            if deleted_count > 0:
                logger.info(f"Deleted {deleted_count} old segments")

            return deleted_count

        except Exception as e:
            logger.error(f"Cleanup error: {e}")
            return 0

    def cleanup_empty_dirs(self):
        removed_count = 0

        try:
            for item in os.listdir(self.segment_path):
                dir_path = os.path.join(self.segment_path, item)

                if os.path.isdir(dir_path):
                    files = os.listdir(dir_path)
                    ts_files = [f for f in files if f.endswith('.ts')]

                    if len(ts_files) == 0:
                        try:
                            for file in files:
                                os.remove(os.path.join(dir_path, file))
                            os.rmdir(dir_path)
                            removed_count += 1
                            logger.info(f"Removed empty channel: {item}")
                        except OSError as e:
                            logger.error(f"Error removing {dir_path}: {e}")

            return removed_count

        except Exception as e:
            logger.error(f"Directory cleanup error: {e}")
            return 0

    def get_stats(self):
        total_segments = 0
        total_size = 0
        channels = []

        try:
            for item in os.listdir(self.segment_path):
                dir_path = os.path.join(self.segment_path, item)

                if os.path.isdir(dir_path):
                    segment_count = 0
                    channel_size = 0

                    for file in os.listdir(dir_path):
                        if file.endswith('.ts'):
                            file_path = os.path.join(dir_path, file)
                            file_size = os.path.getsize(file_path)

                            segment_count += 1
                            channel_size += file_size
                            total_segments += 1
                            total_size += file_size

                    if segment_count > 0:
                        channels.append({
                            'name': item,
                            'segments': segment_count,
                            'size_mb': round(channel_size / 1024 / 1024, 2)
                        })

            return {
                'total_segments': total_segments,
                'total_size_mb': round(total_size / 1024 / 1024, 2),
                'channels': channels
            }

        except Exception as e:
            logger.error(f"Stats error: {e}")
            return None

    def run(self):
        logger.info("Starting cleanup loop...")
        iteration = 0

        try:
            while True:
                iteration += 1

                self.cleanup_old_segments()
                self.cleanup_empty_dirs()

                if iteration % 20 == 0:
                    stats = self.get_stats()
                    if stats:
                        logger.info(f"Stats: {stats['total_segments']} segments, {stats['total_size_mb']} MB")
                        logger.info(f"Active channels: {len(stats['channels'])}")

                time.sleep(self.interval)

        except KeyboardInterrupt:
            logger.info("Cleanup service stopped by user")
        except Exception as e:
            logger.error(f"Fatal error: {e}")
            raise


if __name__ == '__main__':
    os.makedirs('logs', exist_ok=True)
    cleanup = HLSCleanup(CONFIG_FILE)
    cleanup.run()
