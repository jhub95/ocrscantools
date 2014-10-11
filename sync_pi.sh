#!/bin/bash
OPTS="-v -a --prune-empty-dirs --update"

# Copy all files from pi - but only authoritative for the raw/ directories
rsync $OPTS --include="*/" --include="*/raw/*" --include="book.conf" --include="front.jpg" --include="back.jpg" --exclude="**" spreads@10.0.0.75:/media/kitaplar/scans/ /depo/scans/

# Copy all the book.conf and book output files over to the pi for backup purposes ignoring everything else
rsync $OPTS --include="*/" --include="*/book*" --include="front.jpg" --include="back.jpg" --exclude="**" /depo/scans/ spreads@10.0.0.75:/media/kitaplar/scans/

for i in /depo/scans/*; do
    # ignore blank ones
    if [[ ! -f "$i/book.conf" && -f "$i/raw/010.jpg" ]]; then
        cp /home/bookscanner/scantools/book.conf.default "$i/book.conf"
    fi
done
