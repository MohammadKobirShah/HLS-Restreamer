#!/bin/bash
# Health check for Railway

# Check HTTP endpoint
curl -sf http://localhost:8080/health > /dev/null && exit 0

# Check nginx process
pgrep -x nginx > /dev/null || exit 1

exit 1
