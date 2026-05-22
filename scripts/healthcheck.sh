#!/bin/bash
pgrep nginx > /dev/null && curl -sf http://localhost:${PORT:-8080}/health
