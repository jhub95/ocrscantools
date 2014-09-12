#!/bin/bash
OPTS="-v -a --prune-empty-dirs"

# Copy all files from pi - but only authoritative for the raw/ directories
rsync $OPTS --include="*/" --include="*/raw/*" --exclude="**" spreads@10.0.0.75:/media/kitaplar/scans/ /depo/scans/

# Copy all the book.conf and book output files over to the pi for backup purposes ignoring everything else
rsync $OPTS --include="*/" --include="*/book.*" --exclude="**" /depo/scans/ spreads@10.0.0.75:/media/kitaplar/scans/
