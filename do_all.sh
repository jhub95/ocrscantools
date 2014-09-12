#!/bin/bash
DIR=$(dirname $0)
(
    # Lock to make sure that only 1 process can run at the same time
    flock -n 9 || exit 1
    $DIR/sync_pi.sh

    cd /depo/scans
    for i in */; do
        echo "About to process $i..."
        cd $i
        /home/bookscanner/scantools/convert_book.pl pdf text #clean
        if [ $? != 0 ]; then
            echo "Command failed: $i"
        fi
        cd ..
    done

    $DIR/sync_pi.sh
) 9> /tmp/convert_book_lock
