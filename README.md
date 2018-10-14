Take jpgs, crop and adjust them, and then pass them through Tesseract. https://github.com/tesseract-ocr/tesseract

# Installation

Install the basics:

    git clone https://github.com/jhub95/ocrscantools
    apt update
    apt install tesseract-ocr libthread-queue-any-perl libmouse-perl libconfig-general-perl liblist-allutils-perl imagemagick libpath-tiny-perl libsys-cpuaffinity-perl libfindbin-libs-perl python-pil python-reportlab libtest-differences-perl

installing the tesseract new word database for Turkish:

    sudo cp tesseract-train/hasat_tur.traineddata /usr/share/tesseract-ocr/4.00/tessdata/

Test to see if the programs need recompilation for your OS:

    ./htmlout

If that produces errors than recompile like:

    apt install libtesseract-dev dpkg-dev libopencv-dev
    g++ -std=c++0x -O3 htmlout.cpp -ltesseract -llept -o htmlout
    g++ -O3 -o detect_page detect_page.cpp -lopencv_core -lopencv_objdetect -lopencv_highgui -lopencv_imgproc -lopencv_imgcodecs

## Installing patched version of tesseract

I don't think this is still required, but you can build the patched version (ver 3 - only tested on ubuntu 14) like:

    apt-get source tesseract
    get pdf_background_image.patch
    cd tesseract-dir
    patch -p0 < ../pdf_background_image.patch
    dpkg-buildpackage
