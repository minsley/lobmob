#!/bin/bash
CATEGORY="$1"; shift
echo "$(date -Iseconds) [$CATEGORY] $*" >> /var/log/lobmob-events.log
