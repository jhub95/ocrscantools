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
my ($pdf_page_size, $masks);

my ($cmd) = @ARGV;
$cmd ||= 'pdf';
my %cmd = (
    clean => \&clean,
    cleanall => sub { clean(1) },
    pdf => sub { create_pdf( initial_setup() ) },
    text => sub { create_text( initial_setup() ) },
);
if( $cmd{$cmd} ) {
    $cmd{$cmd}->();
} else {
    warn "$0: Unknown command '$cmd' - please specify one of " . join(", ", sort keys %cmd) . "\n";
    exit 1;
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

sub initial_setup {
    my @pages = load_pages($path);
    check_pages(\@pages);
    $pdf_page_size = find_biggest_page_size( \@pages );

    $masks = generate_masks( \@pages, $conf );

    return \@pages;
}

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

sub runcmd { $s->runcmd( @_ ) }

sub generate_cropped_masked_img {
    my ($page) = @_;
    my $cropped_masked_img = $s->_tmp_page_file( 'cropped_masked', $page );
    if( !-f $cropped_masked_img ) {
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

        runcmd( @cmd => $cropped_masked_img );
    }

    return $cropped_masked_img;
}

sub generate_white_bordered_img {
    my ($page, $cropped_masked_img, $out_pdf, $dpi) = @_;
    my $white_bordered_img = $s->_tmp_page_file( 'white_bordered', $page );
    if( !-f $white_bordered_img ) {
        my ($w,$h,$offx,$offy) = find_image_extent( $cropped_masked_img );

        if( $w < 5 || $h < 5 ) {
            # image was totally blank, just output a blank PDF
            runcmd 'convert',
                # Create single white pixel on PDF page (actually can do without this but probably not with convert tool)
                qw< ( -page >, $pdf_page_size, qw< xc:white ) >,

                '+repage',

                # dpi here is needed to get page sizing working in acrobat
                qw< -units PixelsPerInch >,
                '-density' => $dpi,

                $out_pdf;

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

            # Crop main content to white boundaries
            qw< ( >,
                $cropped_masked_img,

                qw< -crop >, "${w}x${h}+$offx+$offy!",

                '-flatten', # expand if necessary (to get it centered)
                qw< +repage
            ) >,

            # Set to center
            qw< -gravity center +geometry >,

            # Merge white and centered content together
            qw< -composite >,

            '+repage',

            $white_bordered_img;
    }
    return $white_bordered_img;
}

sub generate_pdf_bg_img {
    my ($page, $input_img, $dpi) = @_;
    my $pdf_bg_img = $s->_tmp_page_file( 'pdf_bg', $page, '.jpg' );
    if( !-f $pdf_bg_img ) {
        # Set pic to grayscale (1/3, 1/3, 1/3) and subtract it from the
        # original, then cut out some fuzz. If there are non-grayscale colors
        # over larger areas there will be a maxima here which we can pick up
        # on.
        my $is_grayscale = is_grayscale( $input_img );

        # Now output the image that's going to be visible to the user - loose
        # some resolution but keep the dimensions the same

        # ratio of out_dpi:dpi defines how much we scale the image in the PDF.
        # So for example if dpi is 300 and out_dpi is 150 then we would scale
        # PDF to 50% of original size
        my $out_dpi = 140;   
        my $scale = sprintf "%0.2f%%", $out_dpi / $dpi * 100;

        runcmd 'convert', $input_img,

            # XXX need to look to see if we can reduce/increase the quality...
            -quality => $is_grayscale ? 40 : 50,

            qw< -background white >,

            # Some minor enhancements to filter out noise on the PDF image
            '-level' => $conf->opt('output-level') || $conf->opt('level') || '50%,98%',

            ( $is_grayscale ? qw< -colorspace gray > : () ),

            -scale => $scale,

            # leptonica ie tesseract needs these settings to detect DPI properly
            qw< -units PixelsPerInch >, -density => $out_dpi,

            $pdf_bg_img;
    }
    return $pdf_bg_img;
}

sub generate_ocr_img {
    my ($page, $input_img, $dpi) = @_;
    my $ocr_img = $s->_tmp_page_file( 'ocr_img', $page );
    if( !-f $ocr_img ) {
        my $tmpimg = $s->_tmpfile( 'ocr_cleanup', '.png' );
        runcmd 'convert', $input_img,

            # Stretch black and white in the image - this needs to be detected
            # on each book/page to figure out what is best for tessearct but
            # makes a very good improvement
            '-level' => $conf->opt('level') || '50%,98%',

            $tmpimg;

        # XXX check that this algorithm actually improves quality over a wide range of sources
        #runcmd 'python', $FindBin::Bin . '/extract_text.py', $tmpimg, $tmpimg;
        #runcmd $FindBin::Bin . '/../DetectText/DetectText', $tmpimg, $tmpimg, 1;

        # XXX See what qw< -filter triangle -resize 300% > does - reported to work well (http://stb-tester.com/blog/2014/04/14/improving-ocr-accuracy.html)
        runcmd 'convert',
            $tmpimg,

            #convert page_output/004.png \( SWT_output.png -modulate 80% -blur 3 \) -compose Soft_Light -composite t.jpg also a possibility

            #'(', $outimg, qw< -colorspace gray ) >,
            #'(', $outimg2, qw< -morphology erode disk:3 -negate ) -compose Divide_Src -composite >,
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,

            #qw< -filter triangle -resize 300% >,

            # leptonica ie tesseract needs these settings to detect DPI properly
            qw< -units PixelsPerInch >, -density => $dpi,# * 3,

            #'+repage',
            $ocr_img;
    }
    return $ocr_img
}

sub create_text {
    my ($pages) = @_;

    @$pages = run_array( sub {
        my ($page) = @_;

        my $cropped_masked_img = generate_cropped_masked_img( $page );
        my $ocr_img = generate_ocr_img( $page, $cropped_masked_img, 300 );

        my $txt_file_no_ext = $s->output_page_file( 'text', $page, '');
        $page->{txt_file} = "$txt_file_no_ext.txt";
        if( !-f $page->{txt_file} ) {
            runcmd
                'tesseract',
                '-l' => 'mark',
                $ocr_img => $txt_file_no_ext,
                'mark';
        }

        return $page;
    }, $pages, 4/3 );

    # Combine the text
    @$pages = sort { $a->{num} <=> $b->{num} } @$pages;
    my $fh = path('book.txt')->openw_utf8;
    for my $page ( @$pages ) {
        my $text = path( $page->{txt_file} )->slurp_utf8;
        $fh->print( "---- page $page->{num} ----\n", $text, "\n" );
    }
}

sub create_pdf {
    my ($pages) = @_;
    @$pages = run_array( sub {
        my ($page) = @_;
        process_page_pdf($page);
        return $page
    }, $pages, 4/3 );

    runcmd 'pdfunite', map({ $_->{pdf_file} } @$pages), 'book.pdf';
}

sub process_page_pdf {
    my ($page) = @_;

    my $out_pdf_noext = $s->output_page_file( 'pdf', $page, '' );
    my $out_pdf = "$out_pdf_noext.pdf";
    $page->{pdf_file} = $out_pdf;
    return if -f $out_pdf;

    # This just defines the page size in final output
    my $dpi = 300;

    my $cropped_masked_img = generate_cropped_masked_img( $page );
    my $white_bordered_img = generate_white_bordered_img( $page, $cropped_masked_img, $out_pdf, $dpi );
    return if !$white_bordered_img && -f $out_pdf;  # May shortcut if whole image is white

    my $pdf_bg_img = generate_pdf_bg_img( $page, $white_bordered_img, $dpi );
    my $ocr_img = generate_ocr_img( $page, $white_bordered_img, $dpi );

    # Convert to an OCR'd PDF
    runcmd
        'tesseract',

        # Use our provided image
        -c => 'pdf_background_image=' . $pdf_bg_img,

        # Language spec
        -l => 'mark',

        $ocr_img => $out_pdf_noext,

        'mark_pdf';
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

sub load_pages {
    my ($path) = @_;
    if( -f $DUMP_FILE ) {
        our $VAR1;
        require $DUMP_FILE;
        return @$VAR1;
    }

    my @pages;
    for( glob "$path/*.jpg") {
        next unless m!(?: /|^ ) (0*(\d+))\.jpg$!xi;
        push @pages, {
            num => $2,
            fullnum => $1,
            file => $_,
            page_type => $2 % 2 ? 'odd' : 'even'
        };
    }

    # autodetect crops for each page and find the largest width and height
    @pages = run_array( sub {
        my ($page) = @_;
        get_crop_args( $page );
        return $page;
    }, \@pages );
    @pages = sort { $a->{num} <=> $b->{num} } @pages;

    path($DUMP_FILE)->spew( Dumper(\@pages) );

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

        return if $conf->opt( 'white_background' );

        for my $type ('odd', 'even') {
            my $name = $conf->opt( $type . '_blank_page' ) or next;
            my $page = first { $_->{file} eq "$path/$name" } @$pages;   # XXX ugh use hash

            my $output = $s->_tmp_output_file( 'mask', $page->{page_type} . '_blank_mask.png' );
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

# Return true if image is grayscale, false if colour.
sub is_grayscale {
    my ($img) = @_;

    # Clone image to grayscale, subtract from initial image and then check to see if there is anything other than black left over.
    my $max_color_diff = `convert $img -scale 25% \\( +clone -modulate 100,0 \\) -compose Difference -composite -level 10% -format '%[fx:maxima]' info:`;

    return $max_color_diff < 0.05;
}

sub clean {
    my ($extra) = @_;
    my @tmp = glob 'tmp-*';
    push @tmp, $DUMP_FILE, qw< pdf text > if $extra;

    for my $f (@tmp) {
        path($f)->remove_tree if -d $f;
        path($f)->remove if -f $f;
    }

    exit;
}
