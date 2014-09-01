#!/usr/bin/perl
use threads;
use utf8;
use strict;
use warnings;
use List::Util qw< first >;
use Path::Tiny;
use Data::Dumper;
use Thread::Queue;
use Sys::CpuAffinity;
use File::Temp ();
use FindBin::libs;
use BookScan;
use BookConf;
binmode \*STDOUT => 'utf8';

my $DEBUG = 1;
my $s = BookScan->new(
    DEBUG => $DEBUG
);

my $conf = 'BookConf';
my $path = $conf->opt( 'path' ) || 'raw';
my $DUMP_FILE = 'pages.dump';

for( qw< output page_output > ) {
    mkdir $_ if !-d;
}

# Process:
# * Detect crops/distortion info
# * Work out general page size from this
# * XXX go through and auto-detect white pages from the crop details, use these for page masks
# * Create page mask to turn background into white
# * Crop/distort/mask pages appropriately
# * Detect any pure white pages and create dummy PDF for them
# * Crop any white edges off pages to reduce image size
# * Figure out if page is grayscale or not in order to reduce output size/complexity
# * Output small jpg for base of PDF
# * Output large png for tesseract to OCR, look at doing some other cleanups prior to OCR
# * OCR and create PDF from this

my @pages = load_pages($path);
check_pages(\@pages);
my $pdf_page_size = find_biggest_page_size( \@pages );

#warn $pdf_page_size;
#my $white_background = $conf->opt( 'white_background' );

my $masks = generate_masks( \@pages, $conf );

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

sub runcmd { $s->runcmd( @_ ) }

sub get_crop_args {
    my ($page) = @_;
    my $page_type = $page->{page_type};

    if( my $crop = $conf->opt( $page_type . '_page_crop' ) ) {
        $page->{im_crop_args} = [ -crop => $crop ];
        $page->{crop_details} = [ $crop =~ /^(\d+)x(\d+) (?: \+(\d+)\+(\d+) )?/x ];
    } else {
        my @corners = $s->auto_crop_detect( $page->{file}, $conf->opt( $page_type . "_detect_crop" ), $page_type )
            or return;

        %$page = (
            %$page,
            $s->get_crop_and_distort( \@corners )
        )
    }
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
                @{ $page->{im_crop_args} },
                '-deskew' => '80%',
                '+repage',
        );

        # Use a merge to try to get rid of background if necessary
        if( my $maskf = $masks->{$page->{page_type}} ) {
            my ($w, $h) = @{$page->{crop_details}} or die;
            push @cmd,
                $maskf,

                # Page detection algorithm has each page with a slightly
                # different size but they should all be pretty similar. Scale
                # the background map to the same size as this page so that we
                # dont get white background but some dark edges.
                '-resize' => "${w}x${h}\!",
                '-compose' => 'Divide_Src', '-composite';
        }

        my $tmpimg = tmpfile( SUFFIX => ".png" );
        runcmd @cmd => $tmpimg;

        my ($w,$h,$offx,$offy) = find_image_extent( $tmpimg );

        # XXX defines the page size in final output
        my $dpi = 300;

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

        # Set pic to grayscale (1/3, 1/3, 1/3) and subtract it from the
        # original, then cut out some fuzz. If there are non-grayscale colors
        # over larger areas there will be a maxima here which we can pick up
        # on.
        my @perhaps_grayscale;
        my $max_color_diff = `convert $outimg -scale 25% \\( +clone -modulate 100,0 \\) -compose Difference -composite -level 10% -format '%[fx:maxima]' info:`;
        if( $max_color_diff < 0.05 ) {
            @perhaps_grayscale = qw< -colorspace gray >;
        }

        # Now output the image that's going to be visible to the user - loose
        # some resolution but keep the dimensions the same
        my $out_ppi = 140;   # Actually choose whatever
        my $scale = sprintf "%0.2f%%", $out_ppi / $dpi * 100;
        runcmd 'convert', $outimg,
            qw< -quality 80 -units PixelsPerInch -background white -density > => $out_ppi,
            '-level' => $conf->opt('output-level') || $conf->opt('level') || '50%,98%',
            @perhaps_grayscale,
            '-scale' => $scale,
            $out_bg_img;

        # XXX modify outimg by eg bumping up size/dpi or applying level to it in order to get it working better with tesseract?
        my $outimg2 = sprintf "page_output/%03d_tmp.%s", $page->{num}, $OUT_EXT;
        # XXX or tmpimg

        runcmd 'convert', $outimg,
            '-level' => $conf->opt('level') || '50%,98%',
            $outimg2;

        # XXX check that this algorithm actually improves quality over a wide range of sources
        #runcmd 'python', $FindBin::Bin . '/extract_text.py', $tmpimg, $tmpimg;
        #runcmd $FindBin::Bin . '/../DetectText/DetectText', $outimg2, $outimg2, 1;

        # XXX See what qw< -filter triangle -resize 300% > does - reported to work well (http://stb-tester.com/blog/2014/04/14/improving-ocr-accuracy.html)
        runcmd 'convert',
            $outimg2,

            #convert page_output/004.png \( output/004_tmp.png -modulate 80% -blur 3 \) -compose Soft_Light -composite t.jpg also a possibility

            #'(', $outimg, qw< -colorspace gray ) >,
            #'(', $outimg2, qw< -morphology erode disk:3 -negate ) -compose Divide_Src -composite >,
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,

            # ppi here is needed for work with leptonica ie tesseract
            qw< -units PixelsPerInch >,

            #qw< -filter triangle -resize 300% >,
            '-density' => $dpi,# * 3,
            #'+repage',
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

sub process_page_txt {
    my ($page) = @_;

    my $crop = $conf->opt( $page->{page_type} . '_ocr_crop' );

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

        if( my $maskf = $masks->{$page->{page_type}} ) {
            push @cmd,
                # Now combine in mask image
                $maskf,
                '-compose' => 'Divide_Src', '-composite';

        }

        push @cmd,
            # And post-processing
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,
            #'-level' => '83%,92%',

            '-level' => $conf->opt('level'),

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

sub load_pages {
    my ($path) = @_;
    if( -f $DUMP_FILE ) {
        our $VAR1;
        require $DUMP_FILE;
        return @$VAR1;
    }

    my @pages;
    for( glob "$path/*.jpg") {
        next unless m!(?: /|^ ) 0*(\d+)\.jpg$!xi;
        push @pages, {
            num => $1,
            file => $_,
            page_type => $1 % 2 ? 'odd' : 'even'
        };
    }

    # autodetect crops for each page and find the largest width and height
    @pages = run_array( sub {
        my ($page) = @_;
        get_crop_args( $page );
        return $page;
    }, \@pages );
    @pages = sort { $a->{num} <=> $b->{num} } @pages;

    open my $fh, '>', $DUMP_FILE;
    print $fh Dumper(\@pages);

    return @pages;
}

sub find_biggest_page_size {
    my ($pages) = @_;

    my @biggest_crop = (0,0);
    for my $page (@$pages) {
        next if !$page->{crop_details};
        for( 0,1 ) {
            $biggest_crop[$_] = $page->{crop_details}[$_] if $page->{crop_details}[$_] > $biggest_crop[$_];
        }
    }

    return join "x", @biggest_crop;
}

sub check_pages {
    my ($pages) = @_;
    my @ok_pages;
    for my $page ( @$pages ) {
        if( !$page->{crop_details} ) {
            warn "Page $page->{num} couldn't detect page size - won't be processed\n"
        } else {
            push @ok_pages, $page;
        }
    }
    @$pages = @ok_pages;
}

sub generate_masks {
    my ($pages, $conf) = @_;

    my %masks;
    run_multi( sub {
        my ($page) = @_;

        # XXX unlink at end if dev run
        runcmd( 'convert',
            $page->{file},
            '-auto-orient',
            @{$page->{im_crop_args}},
            '+repage',
            '-blur' => '0x10',  # Get rid of any text or marks that may just be on this page
            $page->{output}
        );
    }, sub {
        my ($q) = @_;
        for my $type ('odd', 'even') {
            my $name = $conf->opt( $type . '_blank_page' ) or next;
            my $page = first { $_->{file} eq "$path/$name" } @$pages;

            my $output = "output/" . $page->{page_type} . '_blank_mask.png';
            #print Dumper $page;
            $masks{$type} = $output;
            next if -f $output;

            $q->enqueue( {
                %$page,
                output => $output
            });
        }
    });

    return \%masks;
}

# Returns width/height and top x/y of the non-white area of the image
sub find_image_extent {
    my ($img) = @_;
    # Find white image borders
    my @cmd = (
        'convert' => $img,
        '-quiet',

        # Blur to get rid of any specs on the image
        qw< -blur 0x3 >,

        # Insert white border to ensure we only trim white. As we don't
        # repage this wont get counted in the final output
        qw< -virtual-pixel edge -bordercolor white -border 1 >,

        # Fuzz so that anything within 20% of white is counted as such
        qw< -fuzz 20% -trim >,

        '-format' => '"%[fx:w] %[fx:h] %[fx:page.x] %[fx:page.y]"',
        'info:'
    );
    my $cmd = join " ", @cmd;

    chomp( my $out = `$cmd` );
    #warn "$out\n";
    return split / /, $out;
}
