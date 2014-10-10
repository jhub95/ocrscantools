#!/usr/bin/perl
# TODO
# * ^C breaks partial PNG outputs sometimes - find out a way to kill off any .pngs that might have been underway or do it to tmp file and then move to proper?
# * Often it assumes font size is changing very quickly so confused by ', " or .....'s
# * Triangling of pages due to large stack of paper behind them eg Anadolu Azizleri 250 - needs a better autocrop algorithm to accurately determine the page structure - perhaps say if 6 corners then cut the 2 furthest away?? A bit difficult to do.
# 
# * Should auto-detect images and not apply the level adjustment to those areas of the picture ?
# * Can we auto-detect levels? Small blur (3px?) then histogram to see where the black/white parts are & run over all imgs?
# * Because paper is old lots of specks on 679 - perhaps try to remove them somehow? May end up damaging the text but could try an erode on the output image?
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
use lib '/home/bookscanner/scantools/lib';
use BookScan;
use BookConf;
binmode \*STDOUT => 'utf8';

my $s = BookScan->new(
    DEBUG => 1
);

my $conf = 'BookConf';

my $PDF_DPI_OUTPUT = $conf->opt('pdf-dpi') || 180;

# This just defines the page size in final output
my $INPUT_DPI = $conf->opt('input-dpi') || 400;

my $TESSERACT_CONF = 'hasat_txt';
my $DUMP_FILE = 'pages.dump';

# Mapping of specified language to tesseract language name
my %LANGS = (
    tur => 'hasat_tur',
    eng => 'eng',
);
my $DEFAULT_LANG = 'tur';

my %CMD = (
    clean => \&clean,
    cleanall => sub { clean(1) },
    pdf => \&create_pdf,
    text => \&create_text,
    html => \&create_html,
);

eval { $conf->init };
if( $@ ) {
    show_help();
    die $@;
}

my @cmds = @ARGV ? @ARGV : ('help');
my @exec;
for my $cmd (@cmds) {
    if( $CMD{$cmd} ) {
        push @exec, $CMD{$cmd};
    } else {
        show_help();
        warn "Unknown command '$cmd'\n";
        exit 1;
    }
}
$_->() for @exec;
exit 0;

sub show_help {
    warn "$0 [cmds]\nAvailable commands are:  " . join(", ", sort keys %CMD) . "\n";
}

# Process:
# * Detect crops/distortion info (done in load_pages()). Saves this info into pages.dump
# * Crop and distort pages to turn the picture into an image of the page (crop_and_distort_pages()). Saved into tmp-cropped_distorted directory
# * Go through and auto-detect white pages (find_mask_pages()), change these into page masks for removing background. Saved into tmp-mask directory.
# * Resave pages.dump
# * Mask pages to remove the background, align image based on lines (deskew) (done in img_remove_background()). Saved into tmp-cropped_masked directory
# * PDF Only:
#    - Crop any white edges off pages to reduce image size (done in generate_white_bordered_img()). Saved into tmp-white_bordered directory
#    TODO: We should do this white detection on text too to save running tesseract on the images
#    - Figure out if page is grayscale or not in order to reduce output size/complexity (done in generate_pdf_bg_img())
#    - Output small jpg for base of PDF (done in generate_pdf_bg_img()). Saved into tmp-pdf_bg directory
# * Output large png for tesseract to OCR, look at doing some other cleanups prior to OCR (done in generate_ocr_img()). Saved into tmp-ocr-img-(pdf|text) directorys depending on method
# * OCR and create output file from this (process_page_pdf() or create_text()) - output each page into hocr/ and text/
# * PDF Only:
#    - Work out general page size for output (done in find_biggest_page_size())
#    - Check if there are covers (front.jpg, back.jpg) and if so convert them into PDF pages the same size as the others (generate_pdf_cover). Saved into pdf_covers directory.
# * Combine into output (create_pdf(), create_html() or create_text()). For PDF we actually output hocr and then use hocr2pdf to combine with the different images

sub initial_setup {
    my $pages = load_pages(input_path());
    check_pages($pages);

    crop_and_distort_pages( $pages );

    # Ensure that all pages are masked and the files exist otherwise redo process
    if( grep { !exists $_->{mask} || !-f $_->{mask} } @$pages ) {
        $pages = find_mask_pages( $pages );
        save_pages( $pages );
    }

    return ($pages);
}

sub crop_and_distort_pages {
    my ($pages) = @_;

    @$pages = run_pages( sub {
        my ($page) = @_;

        my $out = $page->{cropped_distorted} = $s->_tmp_page_file( 'cropped_distorted', $page );
        if( !-f $out ) {
            runcmd( 'convert',
                $page->{file},
                '-auto-orient',

                # Figure out crop bounds so that we get the page in a picture
                @{ $page->{im_crop_args} },
                '+repage',
                $out
            );
        }

        return $page;
    }, $pages);

    return $pages;
}

sub find_mask_pages {
    my ($pages) = @_;

    my @mask_pages = run_pages( sub {
        my ($page) = @_;

        return $s->is_blank( $page->{cropped_distorted} ) ? $page : 0;
    }, $pages);

    # Mark the pages as blank to save processing later. %blank_nums is all
    # blank pages, %blanks is the ones we want to use for masking in
    # particular.
    my %blank_nums = map { $_->{num} => 1 } @mask_pages;
    my %blanks;
    $blanks{$_->{page_type}}{$_->{num}} = $_ for @mask_pages;

    # Add in any that are specified explicitly. XXX remove this code when
    # certain that blank autodetection works properly
    for my $type (qw< odd even >) {
        if( my $name = $conf->opt( $type . '_blank_page' ) ) {
            my $p = first { $_->{file} eq input_path() . "/$name" } grep { $_->{page_type} eq $type } @$pages;

            if( !$p ) {
                die "custom $type mask page specified but file $name could not be found"
            }

            # Override detected blanks
            $blanks{$type} = { $p->{num} => $p };
            $blank_nums{$p->{num}} = 1;
        }

        if( !values %{$blanks{$type}} ) {
            die "No $type mask pages detected. Please specify manually using '${type}_blank_page' configuration option\n";
            next;
        }

    }
    @mask_pages = map { values %{$_} } values %blanks;
    # XXX changes to @mask_pages here dont affect the pages array
    for( @mask_pages ) {
        $_->{mask_file} = $s->_tmp_page_file( 'mask', $_ );
    }

    run_pages(sub {
        my ($page) = @_;

        runcmd( 'convert',
            $page->{cropped_distorted},
            '-blur' => '0x10',  # Get rid of any text or marks that may just be on this page
            $page->{mask_file}
        );
    }, \@mask_pages);

    # Now find the closest mask page to each page and set its mask to that
    for my $page (@$pages) {
        my @opts;
        while( my ($num, $m) = each %{$blanks{$page->{page_type}}} ) {
            push @opts, {
                score => abs( $num - $page->{num} ),
                mask => $m
            };
        }
        my $best = (sort { $a->{score} <=> $b->{score} } @opts)[0];
        $page->{mask} = $best->{mask}{mask_file};
    }

    for my $page (@$pages) {
        $page->{is_blank} = 1 if $blank_nums{$page->{num}};
    }

    return $pages;
}

sub get_crop_args {
    my ($page) = @_;
    my $page_type = $page->{page_type};

    if( my $crop = $conf->opt( $page_type . '_page_crop' ) ) {
        die "Manual crop specified";
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
sub runcmd_get_output { $s->runcmd_get_output( @_ ) }

sub img_remove_background {
    my ($page) = @_;
    my $removed_bg_img = $s->_tmp_page_file( 'cropped_masked', $page );
    if( !-f $removed_bg_img ) {
        my @cmd = (
            'convert',
            $page->{cropped_distorted}
        );

        # Use a merge to try to get rid of background
        if( my $maskf = $page->{mask} ) {
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

        runcmd( @cmd => $removed_bg_img );
    }

    return $removed_bg_img;
}

sub generate_white_bordered_img {
    my ($page, $cropped_masked_img) = @_;
    my $white_bordered_img = $s->_tmp_page_file( 'white_bordered', $page );
    if( !-f $white_bordered_img ) {
        my ($w,$h,$offx,$offy) = find_image_extent( $cropped_masked_img );
        if( $w < 5 && $h < 5 ) {
            # XXX actually was blank
            die "Page was blank"
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
            $cropped_masked_img,

            qw< -crop >, "${w}x${h}+$offx+$offy!",

            '-flatten', # expand if necessary (to get it centered)
            '+repage',

            $white_bordered_img;
    }
    return $white_bordered_img;
}

sub generate_pdf_bg_img {
    my ($page, $input_img) = @_;
    my $pdf_bg_img = $s->_tmp_page_file( 'pdf_bg', $page, '.jpg' );
    if( !-f $pdf_bg_img ) {
        my $is_grayscale = is_grayscale( $input_img );

        # Now output the image that's going to be visible to the user - loose
        # some resolution but keep the dimensions the same

        # XXX grayscale with pictures requires a higher quality setting - this
        # should actually be 'does this page have graphics on it' that we
        # use.
        my $quality = $is_grayscale ? ( $conf->opt( 'pdf-grayscale-quality' ) || 20 )
                                : ( $conf->opt( 'pdf-color-quality' ) || 50 );

        runcmd 'convert', $input_img,
            -quality => $quality,

            qw< -background white >,

            # Some minor enhancements to filter out noise on the PDF image
            '-level' => $conf->opt('output-level') || $conf->opt('level') || '50%,98%',

            ( $is_grayscale ? qw< -colorspace gray > : () ),

            -scale => get_pdf_scale(),

            # leptonica ie tesseract needs these settings to detect DPI properly
            qw< -units PixelsPerInch >, -density => $PDF_DPI_OUTPUT,
            '-flatten',

            $pdf_bg_img;
    }
    return $pdf_bg_img;
}

sub generate_ocr_img {
    my ($type, $page, $input_img) = @_;

    # If we did this for PDF previously use that file, otherwise if there was
    # something for text we cant use that for PDF.
    my $ocr_img = $s->_tmp_page_file( "ocr-img-$type" , $page );
    if( $type eq 'text' && !-f $ocr_img ) {
        my $t = $s->_tmp_page_file( "ocr-img-pdf" , $page );
        $ocr_img = $t if -f $t;
    }
    if( !-f $ocr_img ) {
        #my $tmpimg = $s->_tmpfile( 'ocr_cleanup', '.png' );
        runcmd 'convert', $input_img,

            # Stretch black and white in the image - this needs to be detected
            # on each book/page to figure out what is best for tessearct but
            # makes a very good improvement
            '-level' => $conf->opt('level') || '50%,98%',

            #$tmpimg;

        # XXX check that this algorithm actually improves quality over a wide range of sources
        #runcmd 'python', $FindBin::Bin . '/extract_text.py', $tmpimg, $tmpimg;
        #runcmd $FindBin::Bin . '/../DetectText/DetectText', $tmpimg, $tmpimg, 1;

        # XXX See what qw< -filter triangle -resize 300% > does - reported to work well (http://stb-tester.com/blog/2014/04/14/improving-ocr-accuracy.html)
        #runcmd 'convert',
            #$tmpimg,

            #convert page_output/004.png \( SWT_output.png -modulate 80% -blur 3 \) -compose Soft_Light -composite t.jpg also a possibility

            #'(', $outimg, qw< -colorspace gray ) >,
            #'(', $outimg2, qw< -morphology erode disk:3 -negate ) -compose Divide_Src -composite >,
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,

            #qw< -filter triangle -resize 300% >,

            # leptonica ie tesseract needs these settings to detect DPI properly
            qw< -units PixelsPerInch >, -density => $INPUT_DPI,# * 3,
            '-flatten',

            #'+repage',
            $ocr_img;
    }
    return $ocr_img
}

sub create_text {
    if( -f 'book.txt' ) {
        warn "book.txt already exists - not doing anything\n";
        return;
    }
    # TODO Actually this initial setup can be done on a page-by-page basis in
    # text mode as we dont need to know the overall max page dimensions.
    my ($pages) = initial_setup();

    @$pages = run_pages( sub {
        my ($page) = @_;

        return if $page->{is_blank};

        my $cropped_masked_img = img_remove_background( $page );
        # Because we skip a few stages here (not doing white masks etc) the PDF
        # version cannot use our generated OCR images here but we can use the
        # version that was created for the PDF
        my $ocr_img = generate_ocr_img( 'text', $page, $cropped_masked_img );

        my $txt_file_no_ext = $s->output_page_file( 'text', $page, '');
        $page->{txt_file} = "$txt_file_no_ext.txt";
        if( !-f $page->{txt_file} ) {
            runcmd
                'tesseract',
                '-l' => get_language(),
                $ocr_img => $txt_file_no_ext,
                $TESSERACT_CONF;
        }

        return $page;
    }, $pages, 4/3 );

    # Combine and output text
    my $fh = path('book.txt')->openw_utf8;
    for my $page ( sort { $a->{num} <=> $b->{num} } @$pages ) {
        my $f = path( $page->{txt_file} );
        my $text = $f->slurp_utf8;

        # Apply fixups to tesseract output and write back to file
        $text =~ tr/`“”\x{2018}\x{2019}’/'""'''/;
        $text =~ s/\x{fb01}/fi/g;
        $f->spew_utf8( $text );

        $fh->print( "---- page $page->{num} ----\n", $text, "\n" );
    }
}

sub create_html {
    my $html_file = 'book.html';
    if( -f $html_file ) {
        warn "$html_file already exists - not doing anything\n";
        return;
    }
    # TODO Actually this initial setup can be done on a page-by-page basis in
    # text mode as we dont need to know the overall max page dimensions.
    my ($pages) = initial_setup();

    @$pages = run_pages( sub {
        my ($page) = @_;

        return if $page->{is_blank};

        my $cropped_masked_img = img_remove_background( $page );
        # Because we skip a few stages here (not doing white masks etc) the PDF
        # version cannot use our generated OCR images here but we can use the
        # version that was created for the PDF
        my $ocr_img = generate_ocr_img( 'text', $page, $cropped_masked_img );

        $page->{html_file} = $s->output_page_file( 'html', $page, '.html');
        mkdir "html/imgs";
        if( !-f $page->{html_file} ) {
            runcmd
                $s->BASE . '/htmlout',
                get_language(),
                "html/imgs/img_$page->{num}_",
                $ocr_img => $page->{html_file},
                $TESSERACT_CONF;
        }

        return $page;
    }, $pages, 4/3 );

    # Combine and output text
    my $fh = path($html_file)->openw_utf8;
    $fh->print("<!DOCTYPE html>\n<html><head><meta charset='utf-8' /><link rel='stylesheet' href='out.css'></head><body>\n");
    for my $page ( sort { $a->{num} <=> $b->{num} } @$pages ) {
        my $f = path( $page->{html_file} );
        my $text = $f->slurp_utf8;

        # Apply fixups to tesseract output and write back to file
        $text =~ tr/`“”\x{2018}\x{2019}/'""''/;
        $f->spew_utf8( $text );
        $fh->print( $text );
    }
    $fh->print("</body></html>\n");
}

sub _get_pdf_scale { return $PDF_DPI_OUTPUT / $INPUT_DPI }
sub get_pdf_scale {
    # see book.conf.example comment on 'pdf-dpi' option for fuller
    # understanding of this code:
    return sprintf "%0.2f%%", _get_pdf_scale() * 100
}

# Given a cover image and a pdf page size create a pdf page 
sub generate_pdf_cover {
    my ($type, $pdf_page_size) = @_;
    my $input_img = "$type.jpg";
    return '' if !-f $input_img;

    my $pdf_cover_img = $s->output_file( 'pdf_covers', "$type.jpg" );
    if( !-f $pdf_cover_img ) {
        my $quality = $conf->opt( 'pdf-color-quality' ) || 50;
        my $small_pdf_page_size = $pdf_page_size;
        $small_pdf_page_size =~ s/([\d.]+)/int( $1 * _get_pdf_scale() )/eg;

        runcmd 'convert',
            $input_img,
            '-auto-orient',
            -resize => $small_pdf_page_size,

            -quality => $quality,

            qw< -units PixelsPerInch >, -density => $PDF_DPI_OUTPUT,

            '-flatten',
            '+repage',

            $pdf_cover_img;
    }

    return $pdf_cover_img;
}

sub create_pdf {
    if( -f 'book.pdf' ) {
        warn "book.pdf already exists - not doing anything\n";
        return;
    }
    my ($pages) = initial_setup();

    @$pages = run_pages( sub {
        my ($page) = @_;
        process_page_pdf($page);
        return $page
    }, $pages, 4/3 );

    # XXX this code sucks
    my $first_decent_page = first { $_->{bg_img} } @$pages;
    my $bg_dir = $first_decent_page->{bg_img};
    my $hocr_dir = $first_decent_page->{hocr_file};
    s![^/]+$!! for $bg_dir, $hocr_dir;

    my $pdf_page_size = find_biggest_page_size( $pages );
    my ($pdf_w, $pdf_h) = split /x/, $pdf_page_size;

    runcmd $s->BASE . '/hocr2pdf', '',
            $pdf_w, $pdf_h, $INPUT_DPI,
            $bg_dir, $hocr_dir,
            => 'book.pdf',
            generate_pdf_cover('front', $pdf_page_size), generate_pdf_cover('back', $pdf_page_size)
}

sub process_page_pdf {
    my ($page) = @_;

    # Shortcut blank pages
    return if $page->{is_blank};

    my $out_hocr_noext = $s->output_page_file( 'hocr', $page, '' );
    $page->{hocr_file} = "$out_hocr_noext.hocr";

    my $cropped_masked_img = img_remove_background( $page );
    my $white_bordered_img = generate_white_bordered_img( $page, $cropped_masked_img );

    $page->{bg_img} = generate_pdf_bg_img( $page, $white_bordered_img );
    return if -f $page->{hocr_file};
    my $ocr_img = generate_ocr_img( 'pdf', $page, $white_bordered_img );

    # Convert to a HOCR file
    runcmd
        'tesseract',

        # Use our provided image
        -c => 'tessedit_create_hocr=1',

        # Language spec
        -l => get_language(),

        $ocr_img => $out_hocr_noext,

        $TESSERACT_CONF;
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
    die "No items" if !@$items;

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

sub run_pages {
    my ($sub, $pages, @args) = @_;
    return sort { $a->{num} <=> $b->{num} } run_array($sub, $pages, @args);
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
    die "No pages found" unless @pages;
    #@pages = grep { $_->{num} < 10 || $_->{num} == 209 } @pages;

    # autodetect crops for each page and find the largest width and height
    @pages = run_pages( sub {
        my ($page) = @_;
        get_crop_args( $page );
        return $page;
    }, \@pages );

    save_pages( \@pages );

    return \@pages;
}

sub save_pages {
    my ($pages) = @_;
    path($DUMP_FILE)->spew( Dumper($pages) );
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

    $biggest_crop[0] += $conf->opt( 'horiz_padding' ) || 0;
    $biggest_crop[1] += $conf->opt( 'vert_padding' ) || 0;

    return join "x", @biggest_crop;
}

sub check_pages {
    my ($pages) = @_;
    # Ensure all pages have a dimension (ie autocrop worked)

    # Kill head & tail without issue
    shift @$pages while @$pages and !$pages->[0]{dimensions};
    pop @$pages while @$pages and !$pages->[-1]{dimensions};

    die "No pages found" if !@$pages;

    for my $page ( @$pages ) {
        if( !$page->{dimensions} ) {
            die "Page $page->{num} couldn't detect page size - won't be processed\n"
        }
    }
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
        qw< -bordercolor white -border 1 >,

        # Fuzz so that anything within 20% of white is counted as such
        qw< -fuzz 20% -trim >,

        '-format' => '"%[fx:w] %[fx:h] %[fx:page.x] %[fx:page.y]"',
        'info:'
    );

    return split / /, runcmd_get_output( @cmd );
}

# Return true if image is grayscale, false if colour.
#
# Algorithm: Set pic to grayscale (1/3, 1/3, 1/3) and subtract it from the
# original, then cut out some fuzz. If there are non-grayscale colors over
# larger areas there will be a maxima here which we can pick up on.
sub is_grayscale {
    my ($img) = @_;

    # Clone image to grayscale, subtract from initial image and then check to see if there is anything other than black left over.
    my $max_color_diff = runcmd_get_output("convert $img -scale 25% \\( +clone -modulate 100,0 \\) -compose Difference -composite -level 10% -format '%[fx:maxima]' info:");

    return $max_color_diff < 0.05;
}

sub clean {
    my ($extra) = @_;
    my @tmp = glob 'tmp-*';
    push @tmp, $DUMP_FILE, qw< pdf html text pdf_covers > if $extra;

    eval { _clean(@tmp) };
    if( $@ ) {
        sleep 3;    # Try again - stupid ntfs
        _clean(@tmp);
    }
}

sub _clean {
    my (@tmp) = @_;

    for my $f (@tmp) {
        path($f)->remove_tree if -d $f;
        path($f)->remove if -f $f;
    }
}

sub input_path { $conf->opt( 'path' ) || 'raw' }

# XXX for multiple languages just return a spec like eng+hasat_tur
sub get_language {
    my $lang = $conf->opt( 'language' ) || $DEFAULT_LANG;
    return $LANGS{$lang} or die "Language $lang not allowed yet - add to config"
}
