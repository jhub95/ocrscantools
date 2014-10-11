/*
 html output from tesseract cutting out anything that looks like an image and
 outputting html for the rest.

 Compile with
 g++ -std=c++0x -O3 htmlout.cpp -ltesseract -llept -o htmlout

 TODO:
 * Tesseract seems to have major issues with images that contain text - perhaps
   use opencv to do the region detection and then pass through to tesseract?

 Mark Zealey, 2014
*/

#include <string>
#include <list>
#include <iostream>
#include <fstream>
#include <tesseract/baseapi.h>
#include <tesseract/publictypes.h>
#include <leptonica/allheaders.h>

using namespace tesseract;
using namespace std;

typedef struct {
    int top;
    int left;
    string html;
} block_ent;

bool block_compare( const block_ent &a, const block_ent &b ) {
    return a.top == b.top ? a.left < b.left : a.top < b.top;
}

list <block_ent> img_blocks;

string check_add_images( int top ) {
    string ret;
    while( img_blocks.size() && top > img_blocks.front().top ) {
        block_ent b = img_blocks.front();
        img_blocks.pop_front();
        ret += b.html;
    }

    return ret;
}

int img_counter = 0;
tesseract::TessBaseAPI *api;
string process_file( char *img_base, char *img ) {
    string html_str = "";

    // Open input image with leptonica library
    Pix *image = pixRead(img);
    api->SetImage(image);
    int img_width = pixGetWidth(image);

    // First pass, find images, extract and blank out
    api->SetPageSegMode(PSM_AUTO);

    /* First pass: Go through the different blocks on the page that tesseract
     * has found, see if any are images. If they are extract them to image
     * files and make a note of them, and replace them with white. */
    PageIterator *page_it = api->AnalyseLayout();
    if (page_it == NULL) {
        //cerr << "Nothing found" << endl;
        pixDestroy(&image);
        return html_str;
    }

    Boxa *maskboxa = boxaCreate(0);
    PageIteratorLevel level = RIL_BLOCK;
    do {
        PolyBlockType type = page_it->BlockType();
        if( !PTIsImageType(type) )
            continue;

        block_ent b;
        int right, bottom;
        page_it->BoundingBox(level, &b.left, &b.top, &right, &bottom);

        int w = right - b.left, h = bottom - b.top;

        //cerr << "Image block found: " << b.left << ":" << b.top << ":" << right << ":" << bottom << " (" << w << "x" << h << ")" << endl;

        Box* lbox = boxCreate(b.left, b.top, w, h);
        Pix* img_part = pixClipRectangle( image, lbox, NULL );
        string filename = img_base + to_string( img_counter ) + ".png";
        //cerr << "filename: " << filename << endl;

        pixWritePng(filename.c_str(), img_part, 1);
        boxaAddBox( maskboxa, lbox, 0 );
        img_counter++;

        // Figure out html and if it should float or not
        float perc_width = w * 100.0 / img_width;
        b.html = "<img src='" + filename + "'";

        list<string> styles;
        if( perc_width < 80.0 ) {
            if( b.left < img_width * 0.15 )
                styles.push_back("float: left");
            if( right > img_width * 0.85 )
                styles.push_back("float: right");
        }
        styles.push_back("width: " + to_string( (int)perc_width ) + "%");

        if( styles.size() ) {
            b.html += " style='";
            for( list<string>::iterator s = styles.begin(); s != styles.end(); s++ )
                b.html += *s + "; ";
            b.html += "'";
        }

        b.html += ">\n";
        //cerr << b.html;
        img_blocks.push_back(b);
    } while(page_it->Next(level));
    delete page_it;

    img_blocks.sort(block_compare);

    Pix *t = pixSetBlackOrWhiteBoxa( image, maskboxa, 1 );     // 1 white 0 black
    boxaDestroy(&maskboxa);
    pixDestroy( &image );
    image = t;
    //pixWritePng("out.png", image, 1);     // debugging purposes

    api->SetImage(image);
    api->SetSourceResolution(300);  // XXX why is this needed should autodetect...?!

    /* For some reason doing a component image split and then working through
     * each as a single block tends to get the best tesseract recognition. No
     * idea why this is but can just try with a PSM_AUTO and see what happens -
     * sometimes it drops words randomly though...
     */
    Boxa *boxes = api->GetComponentImages(RIL_PARA, true, false, 0, NULL, NULL, NULL);
    if( !boxes ) {
        pixDestroy(&image);
        return html_str;
    }

    api->SetPageSegMode(PSM_SINGLE_BLOCK);

    api->SetVariable("save_blob_choices", "T");
    /*
    api->SetVariable("tessedit_write_images", "1");
    api->ProcessPage(image, 0, "blah", "blah", 0, (TessResultRenderer*)NULL);
    */

    for( int i = 0; i < boxaGetCount(boxes); i++ ) {
        //cerr << i << endl;
        int x, y, w, h;
        boxaGetBoxGeometry(boxes, i, &x, &y, &w, &h);
        api->SetRectangle(x, y, w, h);
        api->Recognize(NULL);
        //cerr << api->GetUTF8Text();

        int wcnt = 0, word_font_size = 0;
        string para_str;

        ResultIterator *res_it = api->GetIterator();
        while (!res_it->Empty(RIL_BLOCK)) {
          const char *text = res_it->GetUTF8Text(RIL_WORD);

          /* Weird bug in tesseract whereby the test for ->Empty(RIL_WORD) at
             the top doesnt hit, but there is no utf8 text returned. In this
             case we can't trust WordFontAttributes unfortunately they return
             uninitialized values (see
             https://code.google.com/p/tesseract-ocr/issues/detail?id=1334 )
           */
          if (res_it->Empty(RIL_WORD) || strlen(text) == 0 ) {
            res_it->Next(RIL_WORD);
            //cerr << "Empty block" << endl;
            continue;
          }

          // Open any new block/paragraph/textline.
          if (res_it->IsAtBeginningOf(RIL_BLOCK)) {
            //html_str += "   <div>";
              //cerr << res_it->GetUTF8Text(RIL_BLOCK) << endl;
          }

          bool bold, italic, underlined, monospace, serif, smallcaps;
          int pointsize, font_id;
          const char *font_name = res_it->WordFontAttributes(&bold, &italic, &underlined,
                                            &monospace, &serif, &smallcaps,
                                            &pointsize, &font_id);

          // Average the font size of the paragraph out as tesseract doesnt usually
          // have it very accurately for each word.
          //cerr << pointsize << "pt " << strlen(text) << endl;
          // XXX sometimes font_name is rubbish
          wcnt++;
          word_font_size += pointsize;

          if (res_it->IsAtBeginningOf(RIL_PARA)) {
              //html_str += "\n    <p>";
          }
          if (res_it->IsAtBeginningOf(RIL_TEXTLINE)) {

              // Check to see if we have any images to put down

              int left, top, right, bottom;
              res_it->BoundingBox(RIL_TEXTLINE, &left, &top, &right, &bottom);

              // half a line height
              para_str += check_add_images( top + (bottom - top) / 2 );
          }

          list<string> word_attrs;
          list<string> classes;

          // Now, process the word...
          int conf = res_it->Confidence(RIL_WORD); // 0 .. 100

          /*
          para_str += " style='";
          para_str += "font-family: ";
          para_str += font_name;
          */
          if( conf < 80 ) {
              if( conf > 60 )
                  classes.push_back("conf-med");
              else if( conf > 30 )
                  classes.push_back("conf-low");
              else
                  classes.push_back("conf-none");
          }

          if (bold) classes.push_back("bold");
          if (italic) classes.push_back("italic");
          if (underlined) classes.push_back("underline");

          if( classes.size() ) {
              string class_str = "class='";
              for( list<string>::iterator c = classes.begin(); c != classes.end(); c++ )
                  class_str += " " + *c;
              class_str += "'";
              word_attrs.push_back( class_str );
          }

          if( word_attrs.size() ) {
              para_str += "<span";
              for( list<string>::iterator a = word_attrs.begin(); a != word_attrs.end(); a++ )
                  para_str += " " + *a;
              para_str += ">";
          }

          /*
          switch (res_it->WordDirection()) {
            case DIR_LEFT_TO_RIGHT: para_str += " dir='ltr'"; break;
            case DIR_RIGHT_TO_LEFT: para_str += " dir='rtl'"; break;
            default:  // Do nothing.
              break;
          }
          */
          bool last_word_in_line = res_it->IsAtFinalElement(RIL_TEXTLINE, RIL_WORD);
          bool last_word_in_para = res_it->IsAtFinalElement(RIL_PARA, RIL_WORD);
          //bool last_word_in_block = res_it->IsAtFinalElement(RIL_BLOCK, RIL_WORD);

          /*
          const char *word = res_it->GetUTF8Text(RIL_WORD);
          para_str += word;
          res_it->Next(RIL_WORD);
          */
          do {
              const char *grapheme = res_it->GetUTF8Text(RIL_SYMBOL);

              /*
              cerr << "Main: " << res_it->GetUTF8Text(RIL_SYMBOL) << " (" << conf << ")" << endl;
              ChoiceIterator ci(*res_it);
              do {
                  cerr << "Alt: " << ci.GetUTF8Text() << " (" << ci.Confidence() << ")" << endl;
              } while(ci.Next());
              */

              if (grapheme && grapheme[0] != 0) {
                if (grapheme[1] == 0) {
                  switch (grapheme[0]) {
                    case '<': para_str += "&lt;"; break;
                    case '>': para_str += "&gt;"; break;
                    case '&': para_str += "&amp;"; break;
                    case '"': para_str += "&quot;"; break;
                    case '\'': para_str += "&#39;"; break;
                    default: para_str += grapheme;
                  }
                } else {
                  para_str += grapheme;
                }
              }
              delete []grapheme;
              res_it->Next(RIL_SYMBOL);
          } while (!res_it->Empty(RIL_BLOCK) && !res_it->IsAtBeginningOf(RIL_WORD));

          /* HYPHENATION:
           *
           * If the word is at the end of the line, AND ends with a - AND the
           * char before that is not a numeral (to avoid breaking bible refs),
           * then remove the - and merge with next word */
          bool needs_space = true;

          // XXX remove last_word_in_para if is near the end of the page?
          if (last_word_in_line && !last_word_in_para) {
              size_t strend = para_str.length();

              //cerr << para_str.at(strend-1) << endl;

              if( strend > 2 && para_str.at(strend-1) == '-' ) {
                  char prev = para_str.at(strend-2);
                  if( prev < '0' || prev > '9' ) {
                      needs_space = false;
                      para_str.pop_back();
                  }
              }
          }

          if( word_attrs.size() )
              para_str += "</span>";
          if( needs_space )
              para_str += " ";

          if (last_word_in_para && wcnt) {
              html_str += "<p style='font-size: " + to_string( word_font_size / wcnt ) + "pt'>" + para_str + "\n</p>\n";
              para_str = "";
              wcnt = 0;
              word_font_size = 0;
          }
          /*
          if (last_word_in_block) {
            html_str += "   </div>\n";
            bcnt++;
          }
          */
        }
        delete res_it;
    }

    html_str += check_add_images( 100000 );   // ensure all images are added

    boxaDestroy(&boxes);
    pixDestroy(&image);

    return html_str;
}

int main(int argc, char *argv[]) {
    if( argc < 5 ) {
        cerr << "usage:" << endl;
        cerr << argv[0] << " <lang> <img_base> <file> <output file> [config file]" << endl;
        return 1;
    }

    api = new tesseract::TessBaseAPI();
    if (api->Init(NULL, argv[1])) {
        cerr << "Could not initialize tesseract.\n";
        return 1;
    }
    if( argc > 5 )
        api->ReadConfigFile(argv[5]);

/*
    cout << "<!DOCTYPE html>\n<html><head><meta charset='utf-8' /><link rel='stylesheet' href='out.css'></head><body>" << endl;
    for( int i=1; i<argc; i++)
        cout << process_file(argv[i]) << endl;
    cout << "</body></html>" << endl;
    */
    ofstream outfile (argv[4]);
    if (!outfile.is_open()) {
        cerr << "Cannot open file for writing: " << argv[4] << endl;
        return 1;
    }
    outfile << process_file(argv[2], argv[3]) << endl;
    outfile.close();

    api->End();

    return 0;
}
