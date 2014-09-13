#!/bin/bash
cd /depo/scans
for i in */; do
    if [[ -f "$i/book.conf" && ! -f "$i/book.pdf" ]]; then
        echo "$i contains book.conf but no PDF output"
    fi
done
