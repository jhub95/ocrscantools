#!/bin/bash
cd /depo/scans
for i in */; do
    cd $i
    /home/bookscanner/scantools/convert_book.pl pdf text #clean
    if [ $? != 0 ]; then
        pwd
        echo "Command failed"
    fi
    cd ..
done
