#!/usr/bin/perl
use threads;
use utf8;
use strict;
use warnings;
use List::Util qw< first min max >;
use Path::Tiny;
use Data::Dumper;
use Thread::Queue;
use Sys::CpuAffinity;
use File::Temp ();

use FindBin;
use lib $FindBin::Bin;
use BookConf;
binmode \*STDOUT => 'utf8';

my $DEBUG = 1;

my $path = BookConf->opt( 'path' ) || '.';
my @pages;
my $DUMP_FILE = 'pages.dump';

for( qw< output page_output > ) {
    mkdir $_ if !-d;
}

if( -f $DUMP_FILE ) {
    our $VAR1;
    require $DUMP_FILE;
    @pages = @$VAR1;
} else {
    for( glob "$path/*.jpg") {
        next unless m!(?: /|^ ) 0*(\d+)\.jpg$!xi;
        push @pages, {
            num => $1,
            file => $_,
            page_type => $1 % 2 ? 'odd' : 'even'
        };
    }
    #@pages = sort { $a->{num} <=> $b->{num} } @pages;

    # autodetect crops for each page and find the largest width and height
    @pages = run_array( sub {
        my ($page) = @_;
        $page->{crop_args} = get_crop_args( $page ) or return;
        return $page;
    }, \@pages );

    open my $fh, '>', $DUMP_FILE;
    print $fh Dumper(\@pages);
}


my @biggest_crop = (0,0);
for my $page (@pages) {
    my @item = get_crop_details( $page->{crop_args} );
    die Dumper($page) if !@item;
    for( 0,1 ) {
        $biggest_crop[$_] = $item[$_] if $item[$_] > $biggest_crop[$_];
    }
}

my $pdf_page_size = join "x", @biggest_crop;
#warn $pdf_page_size;
my $white_background = BookConf->opt( 'white_background' );

my %masks;
run_multi( sub {
    my ($page) = @_;

    # XXX unlink at end if dev run
    runcmd( 'convert',
        $page->{file},
        '-auto-orient',
        @{$page->{crop_args}},
        '+repage',
        '-blur' => '0x10',
        $page->{output}
    );
}, sub {
    my ($q) = @_;
    for my $type ('odd', 'even') {
        my $name = BookConf->opt( $type . '_blank_page' ) or next;
        my $page = first { $_->{file} eq "$path/$name" } @pages;

        my $output = "output/" . $page->{page_type} . '_blank_mask.png';
        use Data::Dumper;
        print Dumper $page;
        $masks{$type} = $output;
        next if -f $output;

        $q->enqueue( {
            %$page,
            output => $output
        });
    }
});

if( 1 ) {
    run_array( \&process_page_pdf, \@pages, 4/3 );

    exit;
}

@pages = run_array( \&process_page_txt, \@pages, 4/3 );

# Combine the text
@pages = sort { $a->{num} <=> $b->{num} } @pages;
for my $page ( @pages ) {
    print "---- page $page->{num} ----\n", $page->{text}, "\n";
}

sub runcmd {
    my (@cmd) = @_;

    warn "@cmd\n" if $DEBUG;
    system @cmd;

    if ($? == -1) {
        warn "failed to execute: $!\n";
    } elsif ($? & 127) {
        warn sprintf "child died with signal %d, %s coredump\n",
           ($? & 127),  ($? & 128) ? 'with' : 'without';
    } else {
        my $val = $? >> 8;
        if( $val != 0 ) {
            warn sprintf "child exited with value %d\n", $val;
        }
    }
}

sub get_crop_args {
    my ($page) = @_;
    my $type = $page->{page_type};

    if( my $crop = BookConf->opt( $type . '_page_crop' ) ) {
        return [ -crop => $crop ];
    }

    my $autoimg = tmpfile(
        SUFFIX => ".jpg"
    );
    my @cmd = (
        'convert', $page->{file}, '-auto-orient'
    );
    if( my $crop = BookConf->opt( $type . "_detect_crop" ) ) {
        if( $type eq 'odd' ) {
            # XXX need to adjust output params
            push @cmd, qw< -gravity NorthEast >
        }
        push @cmd, -crop => $crop;
    }
    push @cmd, $autoimg;
    runcmd @cmd;
    chomp( my @dim = `$FindBin::Bin/detect_page $autoimg` );
    if( !@dim ) {
        warn "Page dimensions not found for $page->{file}\n";
        return;
    }

    # Now have 4 points of the corners. Figure out the big rectangle
    # surrounding them, crop, and then move the points to fill the whole
    # square image
    my @points = sort { $a->{y} <=> $b->{y} } map { my ($x,$y) = split ' '; { x => $x, y => $y } } @dim;

    # top-left top-right bottom-left bottom-right
    @points = (
        sort( { $a->{x} <=> $b->{x} } @points[0,1] ),
        sort( { $a->{x} <=> $b->{x} } @points[2,3] ),
    );

    #for(my $i = 0; $i < @points; $i++) {
    #    printf "%d,%d\n", @{$points[$i]}{qw<x y>}
    #}

    # Shrink the crop area by a few px
    my $crop_inside = 50;
    $points[$_]{x} += $crop_inside for 0,2;
    $points[$_]{x} -= $crop_inside for 1,3;

    $points[$_]{y} += $crop_inside for 0,1;
    $points[$_]{y} -= $crop_inside for 2,3;

    # Get surrounding rectangle points
    my (%min, %max, %wh);
    for my $p (qw< x y >) {
        $min{$p} = min( map { $_->{$p} } @points );
        $max{$p} = max( map { $_->{$p} } @points );
        $wh{$p} = $max{$p} - $min{$p};
    }
    my $crop = sprintf "%dx%d+%d+%d",
        $wh{x}, $wh{y},
        $min{x}, $min{y};

    my @real_points = (
        { x => 0, y => 0 },
        { x => $wh{x}, y => 0 },
        { x => 0, y => $wh{y} },
        { x => $wh{x}, y => $wh{y} },
    );

    # Now figure out where each corner should go in the image (using a distort)
    my $distort;
    for(my $i = 0; $i < @points; $i++) {
        $distort .= sprintf " %d,%d %d,%d",
            $points[$i]{x} - $min{x},
            $points[$i]{y} - $min{y},
            @{$real_points[$i]}{qw< x y>};
    }

    return [
        -crop => $crop,
        '-distort' => 'BilinearReverse' => $distort
    ];
}

sub process_page_pdf {
    my ($page) = @_;

    my ($tmpimg, $outimg);
    my $OUT_EXT = "png";
    if( $DEBUG ) {
        $outimg = sprintf "page_output/%03d.%s", $page->{num}, $OUT_EXT;
    } else {
        # keep in scope so doesnt get deleted
        $tmpimg = tmpfile(
            SUFFIX => "." . $OUT_EXT
        );
        $outimg = $tmpimg->filename
    }

    my $outpdf = sprintf "page_output/%03d", $page->{num};

    my $out_bg_img = sprintf "page_output/%03d_bg.jpg", $page->{num};
    if( !-f $outimg ) {
        my @cmd = (
            'convert',
                $page->{file},
                '-auto-orient',

                # Figure out crop bounds so that we get the page in a picture, straighten it
                @{ $page->{crop_args} },
                '-deskew' => '80%',
                '+repage',
        );

        # Use a merge to try to get rid of background if necessary
        if( my $maskf = $masks{$page->{page_type}} ) {
            my ($w, $h) = get_crop_details( $page->{crop_args} ) or die;
            push @cmd,
                $maskf,

                # Page detection algorithm has page sizes a bit differently but
                # they should all be pretty similar. Scale the background map
                # to the same size as this page so that we dont get white
                # background but some dark edges.
                '-resize' => "${w}x${h}\!",
                '-compose' => 'Divide_Src', '-composite';

        }

        # Now mask out anything that doesnt look like text to give nice white background
        #push @cmd,
        #    '(',
        #        qw< +clone -contrast-stretch 0.5%x60% -morphology erode:3 disk -threshold 80% -blur 0x5 -threshold 80% -negate -write mpr:mask >,
        #    ')',
        #    #-lat => '30x30,-1%',       # adaptive thresholding here if needed
        #    qw< -mask mpr:mask -threshold -1 +mask -delete 1 >
        #    ;

        my $tmpimg = tmpfile( SUFFIX => ".png" );
        push @cmd,
            # And post-processing
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,
            #'-level' => '83%,92%',

            #'-level' => BookConf->opt('level'),
            $tmpimg;

        runcmd @cmd;

        # Find white image borders using a blur
        @cmd = (
            'convert' => $tmpimg,
            '-quiet',
            qw< -blur 0x3 -fuzz 20% -virtual-pixel edge -bordercolor white -border 1 -trim >,
            '-format' => '"%[fx:w] %[fx:h] %[fx:page.x] %[fx:page.y]"',
            'info:'
        );
        my $cmd = join " ", @cmd;

        chomp( my $out = `$cmd` );
        my ($w,$h,$offx,$offy) = split / /, $out;

        # XXX defines the page size in final output
        my $dpi = 300;

        warn "  $outimg: $out\n";
        if( $w < 5 || $h < 5 ) {
            # image was blank
            runcmd 'convert',
                qw< ( -page >, $pdf_page_size, qw< xc:white ) >,   # Create single white pixel on PDF page (actually can do without this but probably not with convert tool)
                '+repage',

                # ppi here is needed for work with leptonica ie tesseract
                qw< -units PixelsPerInch >,
                '-density' => $dpi,

                $outpdf . ".pdf";

            return;
        }

        # Expand a bit to avoid cropping key side stuff (but if
        # larger than specified image above won't do anything)
        my $wadd = int($w * 0.03);
        my $hadd = int($h * 0.03);
        $_ = $_ < 30 ? $_ : 30 for $wadd, $hadd;    # % or X px minimum expansion
        $offx -= $wadd;
        $offy -= $hadd;
        $w += $wadd*2;
        $h += $hadd*2;

        runcmd 'convert',
            qw< ( -size >, $pdf_page_size, qw< xc:white ) >,   # Create white layer. XXX do this transparent?

            # Crop main content to boundaries
            qw< ( >,
                $tmpimg,

                qw< -crop >, "${w}x${h}+$offx+$offy!",

                '-flatten', # expand if necessary (to get it centered)
                qw< +repage
            ) >,

            # Set to center
            qw< -gravity center +geometry >,

            # Merge white and centered content together
            qw< -composite >,

            '+repage',

            # ppi here is needed for work with leptonica ie tesseract
            #qw< -units PixelsPerInch >,
            #'-density' => $dpi,

            $outimg;

        # Now output the image that's going to be visible to the user - loose
        # some resolution but keep the dimensions the same
        my $out_ppi = 140;   # Actually choose whatever
        my $scale = sprintf "%0.2f%%", $out_ppi / $dpi * 100;
        runcmd 'convert', $outimg,
            qw< -quality 80 -units PixelsPerInch -background white -density > => $out_ppi,
            '-scale' => $scale,
            $out_bg_img;

        # XXX modify outimg by eg bumping up size/dpi or applying level to it in order to get it working better with tesseract?

        runcmd 'convert', $outimg,
            '-level' => BookConf->opt('level') || '0%,100%',
            $tmpimg;
        runcmd 'python', $FindBin::Bin . '/extract_text.py', $tmpimg, $tmpimg;
        runcmd 'convert', $tmpimg,
            # ppi here is needed for work with leptonica ie tesseract
            qw< -units PixelsPerInch >,
            '-density' => $dpi,
            '+repage',
            $outimg;
    }

    # Convert to an OCR'd PDF
    runcmd
        'tesseract',
        '-c' => 'pdf_background_image=' . $out_bg_img,
        '-l' => 'mark',
        $outimg => $outpdf,
        'mark_pdf';

    #print Dumper $page;
}

# Run specified number of processes as subthread using queue. Returns when all
# work has been completed.
sub run_multi {
    my ($process_func, $main_thread, $thread_divisor) = @_;
    my $NUM_CPUS = Sys::CpuAffinity::getNumCpus();
    my $MAX_THREADS = $NUM_CPUS / ($thread_divisor || 1);
    #print "$MAX_THREADS\n";
    my $q = Thread::Queue->new;

    my @thr;
    for( 1 .. $MAX_THREADS ) {
        push @thr, threads->create( sub {
            while( defined( my $item = $q->dequeue ) ) {
                $process_func->( $item );
            }
        });
    }

    $main_thread->( $q );
    $q->end;
    $_->join for @thr;
}

sub run_array {
    my ($sub, $items, @args) = @_;
    my $return_q = Thread::Queue->new;

    run_multi( sub {
        my ($item) = @_;
        my $ret = $sub->( { %$item } );
        $return_q->enqueue( $ret ) if $ret;
    }, sub {
        my ($q) = @_;
        $q->enqueue( @$items );
    }, @args );

    $return_q->end;
    my @ret;
    while( defined( my $item = $return_q->dequeue ) ) {
        push @ret, $item;
    }
    return @ret;
}

sub tmpfile {
    my %ARGS = @_;
    return File::Temp->new(
        TEMPLATE =>'tmpXXXXXXXX',
        UNLINK => 1,
        %ARGS
    );
}

sub get_crop_details {
    my ($c) = @_;
    for( my $i = 0; $i < @$c; $i++ ) {
        if( $c->[$i] eq '-crop' ) {
            return ( $c->[$i+1] =~ /^(\d+)x(\d+) (?: \+(\d+)\+(\d+) )?/x );
        }
    }
    return ();
}

sub process_page_txt {
    my ($page) = @_;

    my $crop = BookConf->opt( $page->{page_type} . '_ocr_crop' );

    my ($tmpimg, $outimg);
    my $OUT_EXT = "png";
    if( $DEBUG ) {
        $outimg = sprintf "output/%03d.%s", $page->{num}, $OUT_EXT;
    } else {
        # keep in scope so doesnt get deleted
        $tmpimg = tmpfile(
            SUFFIX => "." . $OUT_EXT
        );
        $outimg = $tmpimg->filename
    }

    if( !-f $outimg ) {
        my @cmd = (
            'convert',
                $page->{file},
                '-auto-orient',
                '-crop' => $crop, '+repage',
                '-deskew' => '80%',
        );

        if( my $maskf = $masks{$page->{page_type}} ) {
            push @cmd,
                # Now combine in mask image
                $maskf,
                '-compose' => 'Divide_Src', '-composite';

        }

        push @cmd,
            # And post-processing
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,
            #'-level' => '83%,92%',

            '-level' => BookConf->opt('level'),

            #'-morphology' => 'thicken' => '3x1:1,0,1',
            
            $outimg;
        runcmd @cmd;
        #return;
    }

    my $txtfile = tmpfile();
    runcmd
        'tesseract',
        '-l' => 'mark',
        $outimg => $txtfile->filename,
        'mark';

    my $real_txt = $txtfile->filename . ".txt";

    $page->{text} = path( $real_txt )->slurp_utf8;
    #print path( $real_txt )->slurp_utf8, "\n";

    unlink $real_txt;

    #print Dumper $page;
    return $page;
}

