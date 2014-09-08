// g++ -O3 -o detect_page detect_page.cpp -lopencv_core -lopencv_objdetect -lopencv_highgui -lopencv_imgproc

#include "opencv2/core/core.hpp"
#include "opencv2/imgproc/imgproc.hpp"
#include "opencv2/highgui/highgui.hpp"

#include <iostream>
#include <math.h>
#include <string.h>


using namespace cv;
using namespace std;
typedef vector<vector<Point> > point_list;

#define DOWNSIZE 10.0

int debug = 0;  // XXX for better binary size you can #def this to 0
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
point_list findSquares( Mat& image )
{
    point_list squares, contours;
    
    //image.resize( Size( image.cols / DOWNSIZE, image.rows / DOWNSIZE ) );
    Mat pyr, timg;
    resize( image, timg, Size(), 1.0 / DOWNSIZE, 1.0 / DOWNSIZE);
    Mat gray0(timg.size(), CV_8U), gray;
    
    // find squares in every color plane of the image
    for( int c = 0; c < 3; c++ )
    {
        int ch[] = {c, 0};
        mixChannels(&timg, 1, &gray0, 1, ch, 1);
        //cvtColor( timg, gray0, CV_BGR2GRAY, 1 );
        
        // try several threshold levels
        //for( int l = 1; l < N; l++ )
        {
            // hack: use Canny instead of zero threshold level.
            // Canny helps to catch squares with gradient shading
            //if( l == 0 )
            /*{
                // apply Canny. Take the upper threshold from slider
                // and set the lower to 0 (which forces edges merging)
                Canny(gray0, gray, 0, 100);
                // dilate canny output to remove potential
                // holes between edge segments
                dilate(gray, gray, Mat(), Point(-1,-1));
            }*/
            //else
            {
                // apply threshold if l!=0:
                //     tgray(x,y) = gray(x,y) < (l+1)*255/N ? 255 : 0
                //adaptiveThreshold( gray0, gray, 255.0, ADAPTIVE_THRESH_MEAN_C, THRESH_BINARY, 7, 40 );

                GaussianBlur( gray0, gray0, Size(7,7), 0 );
                gray = gray0 > 150;
                //double high_thres = cv::threshold( gray0, gray, 0, 255, CV_THRESH_BINARY+CV_THRESH_OTSU );
                //cerr << "HIGH: "<< high_thres << "\n";
                //Canny(gray0, gray, 0, 250, 3);
                //dilate(gray, gray, Mat(), Point(-1,-1));
                //dilate(gray, gray, Mat(), Point(-1,-1));
                //dilate(gray, gray, Mat(), Point(-1,-1));

            }

            // find contours and store them all as a list
            Mat tmat;
            if( debug )
                cvtColor( gray, tmat, CV_GRAY2BGR );

            point_list cont;
            findContours(gray, cont, CV_RETR_LIST, CV_CHAIN_APPROX_SIMPLE);
            contours.insert(contours.end(), cont.begin(), cont.end());

            if( debug > 1 ) {
                RNG rng(12345);
                for( size_t i = 0; i < cont.size(); i++ )
                {
                    drawContours(tmat, cont, i, Scalar( rng.uniform(0, 255), rng.uniform(0,255), rng.uniform(0,255) ), 3 );
                }
                imshow( "blah", tmat );
                waitKey(0);
            }
        }
    }

    // Debug for showing all the potential contours it has found
    /*
    if( debug ) {
        RNG rng(12345);
        Mat tmat(timg.clone());
        for( size_t i = 0; i < contours.size(); i++ )
        {
            drawContours(tmat, contours, i, Scalar( rng.uniform(0, 255), rng.uniform(0,255), rng.uniform(0,255) ), 3 );
        }
        imshow( "blah", tmat );
        waitKey(0);
    }
    */

    // test each contour
    for( size_t i = 0; i < contours.size(); i++ )
    {
        vector<Point> approx, approx2, c = contours[i];

        if( contourArea(Mat(c)) < 1000 )
            continue;

        convexHull(c, approx2);
        if( debug > 1 && fabs(contourArea(Mat(approx2))) > 1000 ) {
            Mat tmat(timg.clone());
            point_list t;
            t.push_back( approx2 );
            drawContours(tmat, t, 0, Scalar(0, 255, 0), 3 );
            imshow( "blah", tmat );
            waitKey(0);
        }

        // approximate contour with accuracy proportional
        // to the contour perimeter
        approxPolyDP(approx2, approx, arcLength(Mat(c), true)*0.03, true);

        if( debug > 1 && fabs(contourArea(Mat(approx))) > 1000 ) {
            Mat tmat(timg.clone());
            point_list t;
            t.push_back( approx );
            drawContours(tmat, t, 0, Scalar(128, 128, 128), 3 );
            imshow( "blah", tmat );
            waitKey(0);
        }

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
            if( maxCosine < 0.05 )
                squares.push_back(approx);
        }
    }

    return squares;
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
    if( argc > 2 )
        debug = atoi( argv[2]);

    // image.jpg
    
    Mat image = imread(argv[1], 1);
    if( image.empty() )
    {
        cout << "Couldn't load " << argv[1] << endl;
        return 1;
    }
    
    point_list squares = findSquares(image);

    // Debug for showing all the squares
    if( debug > 1 ) {
        RNG rng(12345);
        Mat timg;
        resize( image, timg, Size(), 1.0 / DOWNSIZE, 1.0 / DOWNSIZE);
        for( size_t i = 0; i < squares.size(); i++ )
        {
            drawContours(timg, squares, i, Scalar( rng.uniform(0, 255), rng.uniform(0,255), rng.uniform(0,255) ), 3 );
        }
        imshow( "blah", timg );
        waitKey(0);
    }

    // none found
    if( !squares.size() )
        return 1;

    // Now find biggest square (area)
    vector<Point> biggest = squares[0];
    Size biggest_wh = square_dim( biggest );
    size_t biggest_n = 0;

    for( size_t i = 1; i < squares.size(); i++ )
    {
        Size wh = square_dim( squares[i] );

        if( wh.width * wh.height > biggest_wh.width * biggest_wh.height ) {
            biggest_wh = wh;
            biggest_n = i;
            biggest = squares[i];
        }
    }
    if( debug ) {
        Mat timg;
        resize( image, timg, Size(), 1.0 / DOWNSIZE, 1.0 / DOWNSIZE);
        drawContours(timg, squares, biggest_n, Scalar( 255, 0, 0 ), 1 );
        imshow( "blah", timg );
        waitKey(0);
    }

    for( size_t i = 0; i < biggest.size(); i++ ) {
        cout << biggest[i].x * DOWNSIZE << " " << biggest[i].y * DOWNSIZE << endl;
    }

#if 0
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
#endif

    return 0;
}
