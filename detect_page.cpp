// g++ -O3 -o detect_page detect_page.cpp -lopencv_core -lopencv_objdetect -lopencv_highgui -lopencv_imgproc

#include "opencv2/core/core.hpp"
#include "opencv2/imgproc/imgproc.hpp"
#include "opencv2/highgui/highgui.hpp"

#include <iostream>
#include <math.h>
#include <string.h>

using namespace cv;
using namespace std;

#define DOWNSIZE 10.0

int thresh = 50, N = 11;
const char* wndname = "Square Detection Demo";

// helper function:
// finds a cosine of angle between vectors
// from pt0->pt1 and from pt0->pt2
double angle( Point pt1, Point pt2, Point pt0 )
{
    double dx1 = pt1.x - pt0.x;
    double dy1 = pt1.y - pt0.y;
    double dx2 = pt2.x - pt0.x;
    double dy2 = pt2.y - pt0.y;
    return (dx1*dx2 + dy1*dy2)/sqrt((dx1*dx1 + dy1*dy1)*(dx2*dx2 + dy2*dy2) + 1e-10);
}

// returns sequence of squares detected on the image.
// the sequence is stored in the specified memory storage
void findSquares( Mat& image, vector<vector<Point> >& squares )
{
    squares.clear();
    
    //image.resize( Size( image.cols / DOWNSIZE, image.rows / DOWNSIZE ) );
    Mat pyr, timg;
    resize( image, timg, Size(), 1.0 / DOWNSIZE, 1.0 / DOWNSIZE);
    Mat gray0(timg.size(), CV_8U), gray;
    
    vector<vector<Point> > contours;
    
    // find squares in every color plane of the image
    //for( int c = 0; c < 3; c++ )
    {
        //int ch[] = {c, 0};
        //mixChannels(&timg, 1, &gray0, 1, ch, 1);
        cvtColor( timg, gray0, CV_BGR2GRAY, 1 );
        
        // try several threshold levels
        //for( int l = 1; l < N; l++ )
        {
            // hack: use Canny instead of zero threshold level.
            // Canny helps to catch squares with gradient shading
            //if( l == 0 )
            /*{
                // apply Canny. Take the upper threshold from slider
                // and set the lower to 0 (which forces edges merging)
                Canny(gray0, gray, 0, 100, 5);
                // dilate canny output to remove potential
                // holes between edge segments
                dilate(gray, gray, Mat(), Point(-1,-1));
            }*/
            //else
            {
                // apply threshold if l!=0:
                //     tgray(x,y) = gray(x,y) < (l+1)*255/N ? 255 : 0
                gray = gray0 > 200;
            }

            // find contours and store them all as a list
            findContours(gray, contours, CV_RETR_LIST, CV_CHAIN_APPROX_SIMPLE);

#if 0
            RNG rng(12345);
            for( size_t i = 0; i < contours.size(); i++ )
            {
                drawContours(timg, contours, i, Scalar( rng.uniform(0, 255), rng.uniform(0,255), rng.uniform(0,255) ), 3 );
                imshow( "blah", timg );
            }
                waitKey(0);
#endif

            vector<Point> approx;
            
            // test each contour
            for( size_t i = 0; i < contours.size(); i++ )
            {
                // approximate contour with accuracy proportional
                // to the contour perimeter
                approxPolyDP(Mat(contours[i]), approx, arcLength(Mat(contours[i]), true)*0.02, true);
                
                // square contours should have 4 vertices after approximation
                // relatively large area (to filter out noisy contours)
                // and be convex.
                // Note: absolute value of an area is used because
                // area may be positive or negative - in accordance with the
                // contour orientation
                if( approx.size() == 4 &&
                    fabs(contourArea(Mat(approx))) > 1000 &&
                    isContourConvex(Mat(approx)) )
                {
                    double maxCosine = 0;

                    for( int j = 2; j < 5; j++ )
                    {
                        // find the maximum cosine of the angle between joint edges
                        double cosine = fabs(angle(approx[j%4], approx[j-2], approx[j-1]));
                        maxCosine = MAX(maxCosine, cosine);
                    }

                    // if cosines of all angles are small
                    // (all angles are ~90 degree) then write quandrange
                    // vertices to resultant sequence
                    if( maxCosine < 0.04 )
                        squares.push_back(approx);
                }
            }
        }
    }
}

void get_corners( vector<Point> square, Point &top, Point &bottom ) {
    top = square[0];
    bottom = square[0];
    for( size_t i = 1; i < square.size(); i++ ) {
        if( square[i].x < top.x )
            top.x = square[i].x;
        if( square[i].x > bottom.x )
            bottom.x = square[i].x;
        if( square[i].y < top.y )
            top.y = square[i].y;
        if( square[i].y > bottom.y )
            bottom.y = square[i].y;
    }
}

Size square_dim(vector<Point> square) {
    Point top, bottom;
    get_corners( square, top, bottom );
    return Size(
        bottom.x - top.x,
        bottom.y - top.y
    );
}

bool sortcmp( Point i, Point j ) {
    return i.x < j.x || i.y < j.y;
}

int main(int argc, char** argv)
{
    namedWindow( wndname, 1 );
    vector<vector<Point> > squares;

    // image.jpg
    
    Mat image = imread(argv[1], 1);
    if( image.empty() )
    {
        cout << "Couldn't load " << argv[1] << endl;
        return 1;
    }
    
    findSquares(image, squares);

    // none found
    if( !squares.size() )
        return 1;

    // Now find biggest square (area)
    vector<Point> biggest = squares[0];
    Size biggest_wh = square_dim( biggest );

    for( size_t i = 1; i < squares.size(); i++ )
    {
        Size wh = square_dim( squares[i] );

        if( wh.width * wh.height > biggest_wh.width * biggest_wh.height ) {
            biggest_wh = wh;
            biggest = squares[i];
        }
    }

    // XXX Now need to figure out the rectangle within this for cropping
    int w, h, x, y;

    // crop borders appropriately
    w = biggest_wh.width - 2;
    h = biggest_wh.height - 2;
    Point top,bottom;
    get_corners( biggest, top, bottom );
    x = top.x + 1;
    y = top.y + 1;

    /*
    cout << "Biggest Square:" << endl;
    cout << "w: " << w * DOWNSIZE << "; h: " << h * DOWNSIZE << endl;
    cout << "x: " << x * DOWNSIZE << "; y: " << y * DOWNSIZE << endl;
    */
    cout << w * DOWNSIZE << "x" << h * DOWNSIZE << "+" << x * DOWNSIZE << "+" << y * DOWNSIZE << endl;
    //cout << x * DOWNSIZE << "," << y * DOWNSIZE << " " << (x+w) * DOWNSIZE << "," << (y+h) * DOWNSIZE << endl;

    return 0;
}
