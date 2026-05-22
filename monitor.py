#!/usr/bin/env python3

import psutil
import requests
import time
import json
from datetime import datetime

API_URL = 'http://localhost:3000'
INTERVAL = 10


def get_system_stats():
    return {
        'cpu_percent': psutil.cpu_percent(interval=1),
        'memory_percent': psutil.virtual_memory().percent,
        'memory_mb': psutil.virtual_memory().used / 1024 / 1024,
        'disk_percent': psutil.disk_usage('/').percent,
        'network_sent_mb': psutil.net_io_counters().bytes_sent / 1024 / 1024,
        'network_recv_mb': psutil.net_io_counters().bytes_recv / 1024 / 1024
    }


def get_server_stats():
    try:
        response = requests.get(f'{API_URL}/api/stats', timeout=5)
        if response.status_code == 200:
            return response.json()['stats']
    except:
        pass
    return None


def print_stats():
    system = get_system_stats()
    server = get_server_stats()

    print("\n" + "=" * 60)
    print(f"  HLS RESTREAMER - MONITORING | {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    print("\nSYSTEM RESOURCES:")
    print(f"  CPU Usage:    {system['cpu_percent']:.1f}%")
    print(f"  Memory Usage: {system['memory_percent']:.1f}% ({system['memory_mb']:.0f} MB)")
    print(f"  Disk Usage:   {system['disk_percent']:.1f}%")
    print(f"  Network Up:   {system['network_sent_mb']:.2f} MB")
    print(f"  Network Down: {system['network_recv_mb']:.2f} MB")

    if server:
        print("\nSERVER STATUS:")
        print(f"  Total Channels:   {server.get('totalChannels', 0)}")
        print(f"  Running Channels: {server.get('runningChannels', 0)}")
        print(f"  Total Segments:   {server.get('totalSegments', 0)}")
        print(f"  Uptime:           {int(server.get('uptime', 0))}s")

    print("=" * 60)


if __name__ == '__main__':
    print("Starting monitoring service...")
    print(f"API Endpoint: {API_URL}")
    print(f"Refresh Interval: {INTERVAL}s")
    print("\nPress Ctrl+C to stop\n")

    try:
        while True:
            print_stats()
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        print("\nMonitoring stopped")
