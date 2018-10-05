# ocrscantools
Take jpgs, crop and adjust them, and then pass them through Tesseract. https://github.com/tesseract-ocr/tesseract

# Installation

## == Installing patched version of tesseract ==
apt-get source tesseract

get pdf_background_image.patch

cd tesseract-dir

patch -p0 < ../pdf_background_image.patch

dpkg-buildpackage

## installing the new word database:
sudo cp /tmp/tesstrain/hasat_tur/hasat_tur.traineddata /usr/share/tesseract-ocr/tessdata/hasat_tur.traineddata

## Perl and ImageMagick
sudo apt install libthread-queue-any-perl libmouse-perl libconfig-general-perl liblist-allutils-perl imagemagick
