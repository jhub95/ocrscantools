#!/usr/bin/perl
# TODO
# * PDF with HOCR output to merge rather than plain PDF output - hopefully fix that select text at beginning of PDF page issue
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

my $s = BookScan->new(
    DEBUG => 1
);

my $conf = 'BookConf';

my $TESSERACT_LANG = 'hasat_tur';
my $TESSERACT_CONF = 'hasat';
my $INPUT_PATH = $conf->opt( 'path' ) || 'raw';
my $DUMP_FILE = 'pages.dump';

my %cmd = (
    clean => \&clean,
    cleanall => sub { clean(1) },
    pdf => \&create_pdf,
    text => \&create_text,
);
my @cmds = @ARGV ? @ARGV : ('pdf');
for my $cmd (@cmds) {
    if( $cmd{$cmd} ) {
        $cmd{$cmd}->();
    } else {
        warn "$0: Unknown command '$cmd' - please specify one of " . join(", ", sort keys %cmd) . "\n";
        exit 1;
    }
}

# Process:
# * Detect crops/distortion info (done in load_pages()). Saves this info into pages.dump
# * PDF Only: Work out general page size from this (done in find_biggest_page_size())
# * TODO go through and auto-detect white pages from the crop details, use these for page masks
# * Create page mask to turn background into white (done in generate_masks()). Saved into tmp-mask directory
# * Crop/distort/mask pages appropriately (done in generate_cropped_masked_img()). Saved into tmp-cropped_masked directory
# * PDF Only: Detect any pure white pages and create dummy PDF for them (done in generate_white_bordered_img()).
# * PDF Only: Crop any white edges off pages to reduce image size (done in generate_white_bordered_img())
# * PDF Only: Figure out if page is grayscale or not in order to reduce output size/complexity (done in generate_pdf_bg_img())
# * PDF Only: Output small jpg for base of PDF (done in generate_pdf_bg_img()). Saved into tmp-pdf_bg directory
# * Output large png for tesseract to OCR, look at doing some other cleanups prior to OCR (done in generate_ocr_img()). Saved into tmp-ocr-img-(pdf|text) directorys depending on method
# * OCR and create output file from this (create_pdf() or create_text()) - output into pdf/ and text/ and then combined into book.pdf or book.txt

sub initial_setup {
    my $pages = load_pages($INPUT_PATH);
    check_pages($pages);
    my $masks = generate_masks( $pages, $conf );

    return ($pages, $masks);
}

sub get_crop_args {
    my ($page) = @_;
    my $page_type = $page->{page_type};

    if( my $crop = $conf->opt( $page_type . '_page_crop' ) ) {
        die;
        #warn "Manual crop specified";
        #$page->{im_crop_args} = [ -crop => $crop ];
        #$page->{dimensions} = [ $crop =~ /^(\d+)x(\d+)/x ];
    } else {
        my $initial_crop = $conf->opt( $page_type . "_detect_crop" );
        my @corners = $s->auto_crop_detect( $page->{file}, $initial_crop, $page_type )
            or return;

        %$page = (
            %$page,
            $s->get_crop_and_distort( $page_type, $initial_crop, \@corners, $conf->opt('middle_no_crop') )
        )
    }
}

sub runcmd { $s->runcmd( @_ ) }

sub generate_cropped_masked_img {
    my ($page, $masks) = @_;
    my $cropped_masked_img = $s->_tmp_page_file( 'cropped_masked', $page );
    if( !-f $cropped_masked_img ) {
        my @cmd = (
            'convert',
                $page->{file},
                '-auto-orient',

                # Figure out crop bounds so that we get the page in a picture
                @{ $page->{im_crop_args} },
        );

        # Use a merge to try to get rid of background
        if( my $maskf = $masks->{$page->{page_type}} ) {
            my ($w, $h) = @{$page->{dimensions}} or die;
            push @cmd,
                $maskf,

                # Page detection algorithm has each page with a slightly
                # different size but they should all be pretty similar. Scale
                # the background map to the same size as this page so that we
                # dont get white background but some dark edges.
                '-resize' => "${w}x${h}\!",
                '-compose' => 'Divide_Src', '-composite';
        }

        # Try to remove any near-white bits that the mask didn't get rid of
        push @cmd,
            # Clone the image, kill any areas that are more than 10% away from white
            qw< ( +clone -fuzz 10% -fill white +opaque white >,
            # Blur and remove from the image
            qw< -resize 4% -resize 2500% ) -compose Divide_Src -composite  >;

        # Now try to rotate the page according to the lines to straighten it up
        push @cmd,
            '-deskew' => '80%',
            '+repage';

        runcmd( @cmd => $cropped_masked_img );
    }

    return $cropped_masked_img;
}

sub generate_white_bordered_img {
    my ($page, $cropped_masked_img, $pdf_page_size, $out_pdf, $dpi) = @_;
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
            -quality => $is_grayscale ? 20 : 50,

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
    my ($type, $page, $input_img, $dpi) = @_;

    # If we did this for PDF previously use that file, otherwise if there was
    # something for text we cant use that for PDF.
    my $ocr_img = $s->_tmp_page_file( "ocr-img-$type" , $page );
    if( $type eq 'text' && !-f $ocr_img ) {
        my $t = $s->_tmp_page_file( "ocr-img-pdf" , $page );
        $ocr_img = $t if -f $t;
    }
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
    return if -f 'book.txt';
    # TODO Actually this initial setup can be done on a page-by-page basis in
    # text mode as we dont need to know the overall max page dimensions.
    my ($pages, $masks) = initial_setup();

    @$pages = run_array( sub {
        my ($page) = @_;

        my $cropped_masked_img = generate_cropped_masked_img( $page, $masks );
        # Because we skip a few stages here (not doing white masks etc) the PDF
        # version cannot use our generated OCR images here but we can use the
        # version that was created for the PDF
        my $ocr_img = generate_ocr_img( 'text', $page, $cropped_masked_img, 300 );

        my $txt_file_no_ext = $s->output_page_file( 'text', $page, '');
        $page->{txt_file} = "$txt_file_no_ext.txt";
        if( !-f $page->{txt_file} ) {
            runcmd
                'tesseract',
                '-l' => $TESSERACT_LANG,
                $ocr_img => $txt_file_no_ext,
                $TESSERACT_CONF . '_txt';
        }

        return $page;
    }, $pages, 4/3 );

    # Combine and output text
    my $fh = path('book.txt')->openw_utf8;
    for my $page ( sort { $a->{num} <=> $b->{num} } @$pages ) {
        my $f = path( $page->{txt_file} );
        my $text = $f->slurp_utf8;

        # Apply fixups to tesseract output and write back to file
        $text =~ tr/`“”\x{2018}\x{2019}/'""''/;
        $f->spew_utf8( $text );

        $fh->print( "---- page $page->{num} ----\n", $text, "\n" );
    }
}

sub create_pdf {
    return if -f 'book.pdf';
    my ($pages, $masks) = initial_setup();
    my $pdf_page_size = find_biggest_page_size( $pages );

    @$pages = run_array( sub {
        my ($page) = @_;
        process_page_pdf($page, $pdf_page_size, $masks);
        return $page
    }, $pages, 4/3 );

    runcmd 'pdfunite', map({ $_->{pdf_file} } sort { $a->{num} <=> $b->{num} } @$pages), 'book.pdf';
}

sub process_page_pdf {
    my ($page, $pdf_page_size, $masks) = @_;

    my $out_pdf_noext = $s->output_page_file( 'pdf', $page, '' );
    my $out_pdf = "$out_pdf_noext.pdf";
    $page->{pdf_file} = $out_pdf;
    return if -f $out_pdf;

    # This just defines the page size in final output
    my $dpi = 300;

    my $cropped_masked_img = generate_cropped_masked_img( $page, $masks );
    my $white_bordered_img = generate_white_bordered_img( $page, $cropped_masked_img, $pdf_page_size, $out_pdf, $dpi );
    return if !$white_bordered_img && -f $out_pdf;  # May shortcut if whole image is white

    my $pdf_bg_img = generate_pdf_bg_img( $page, $white_bordered_img, $dpi );
    my $ocr_img = generate_ocr_img( 'pdf', $page, $white_bordered_img, $dpi );

    # Convert to an OCR'd PDF
    runcmd
        'tesseract',

        # Use our provided image
        -c => 'pdf_background_image=' . $pdf_bg_img,

        # Language spec
        -l => $TESSERACT_LANG,

        $ocr_img => $out_pdf_noext,

        $TESSERACT_CONF . '_pdf';
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
        return $VAR1;
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
    #@pages = grep { $_->{num} < 10 || $_->{num} == 209 } @pages;

    # autodetect crops for each page and find the largest width and height
    @pages = run_array( sub {
        my ($page) = @_;
        get_crop_args( $page );
        return $page;
    }, \@pages );
    @pages = sort { $a->{num} <=> $b->{num} } @pages;

    path($DUMP_FILE)->spew( Dumper(\@pages) );

    return \@pages;
}

sub find_biggest_page_size {
    my ($pages) = @_;

    my @biggest_crop = (0,0);
    for my $page (@$pages) {
        next if !$page->{dimensions};
        for( 0,1 ) {
            $biggest_crop[$_] = $page->{dimensions}[$_] if $page->{dimensions}[$_] > $biggest_crop[$_];
        }
    }

    return join "x", @biggest_crop;
}

sub check_pages {
    my ($pages) = @_;
    # Ensure all pages have a dimension (ie autocrop worked)

    # Kill head & tail without issue
    shift @$pages while !$pages->[0]{dimensions};
    pop @$pages while !$pages->[-1]{dimensions};

    for my $page ( @$pages ) {
        if( !$page->{dimensions} ) {
            die "Page $page->{num} couldn't detect page size - won't be processed\n"
        }
    }
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
            my $page = first { $_->{file} eq "$INPUT_PATH/$name" } @$pages;   # XXX ugh use hash

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
