#!/usr/bin/perl
use threads;
use utf8;
use strict;
use warnings;
use List::Util 'first';
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
my $return_q = Thread::Queue->new;

my @pages;
for(<*.jpg>) {
    next unless /^0*(\d+)\.jpg$/i;
    push @pages, {
        num => $1,
        file => $_,
        page_type => $1 % 2 ? 'odd' : 'even'
    };
}
#@pages = sort { $a->{num} <=> $b->{num} } @pages;

if( $DEBUG ) {
    mkdir "output";
    mkdir "page_output";
}

my $pdf_page_size = BookConf->opt( 'pdf_page_size' ) or die;
my $white_background = BookConf->opt( 'white_background' );
if( !$white_background ) {
    run_multi( sub {
        my ($page) = @_;
        my $crop = BookConf->opt( $page->{page_type} . '_ocr_crop' );
        # XXX unlink at end if dev run
        runcmd( 'convert',
            $page->{file},
            '-auto-orient',
            '-crop' => $crop,
            '+repage',
            '-resize' => '4000x4000',
            '-colorspace' => 'gray',
            '-blur' => '0x10',
            $page->{output}
        );
    }, sub {
        my ($q) = @_;
        for my $type ('odd', 'even') {
            my $name = BookConf->opt( $type . '_blank_page' );
            my $page = first { $_->{file} eq $name } @pages;
            if( !$page ) {
                die "No blank $type page specified in config";
            }

            my $output = "output/" . $page->{page_type} . '_blank_mask.png';
            next if -f $output;

            $q->enqueue( {
                %$page,
                output => $output
            });
        }
    });
}

if( 1 ) {
    run_multi( \&process_whole_page, sub {
        my ($q) = @_;
        $q->enqueue( @pages );
    }, 4/3);

    exit;
}

run_multi( \&process_page, sub {
    my ($q) = @_;
    $q->enqueue( @pages );
}, 4/3);

$return_q->end;

# Combine the text
@pages = ();
while( defined( my $item = $return_q->dequeue ) ) {
    push @pages, $item;
}
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

sub process_page {
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
                # XXX use adaptive resize?
                '-resize' => '4000x4000',
                '-colorspace' => 'gray',
        );

        if( !$white_background ) {
            push @cmd,
                # Now combine in mask image
                'output/' . $page->{page_type} . '_blank_mask.png',
                '-compose' => 'Divide_Src', '-composite';

        }

        push @cmd,
            # And post-processing
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,
            #'-level' => '83%,92%',

            '-level' => '90%,98%',

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
    $return_q->enqueue( {
        %$page,
        text => path( $real_txt )->slurp_utf8
    });
    #print path( $real_txt )->slurp_utf8, "\n";

    unlink $real_txt;

    #print Dumper $page;
}

sub process_whole_page {
    my ($page) = @_;

    my $crop = BookConf->opt( $page->{page_type} . '_page_crop' );

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

    if( !-f $outimg ) {
        my @cmd = (
            'convert',
                $page->{file},
                '-auto-orient',
                '-crop' => $crop,
                '-deskew' => '80%',
                '+repage',

                # XXX use adaptive resize?
                '-colorspace' => 'gray',
        );

        my $tmpimg = tmpfile( SUFFIX => ".png" );
        push @cmd,
            # And post-processing
            #qw< -level 50%,90% -morphology erode rectangle:6x1 >,
            #'-level' => '83%,92%',

            '-level' => '90%,98%',
            $tmpimg;

        runcmd @cmd;

        # Find white image borders using a blur
        @cmd = (
            'convert' => $tmpimg,
            '-quiet',
            qw< -blur 0x3 -fuzz 50% -virtual-pixel edge -bordercolor white -border 1 -trim >,
            '-format' => '"%[fx:w] %[fx:h] %[fx:page.x] %[fx:page.y]"',
            'info:'
        );
        my $cmd = join " ", @cmd;

        chomp( my $out = `$cmd` );
        my ($w,$h,$offx,$offy) = split / /, $out;

        warn "  $outimg: $out\n";
        if( $w < 5 || $h < 5 ) {
            # XXX image was blank
            return;
        } else {

            # Expand a bit to avoid cropping key side stuff (but if
            # larger than specified image above won't do anything)
            my $wadd = int($w * 0.01);
            my $hadd = int($h * 0.01);
            $_ = $_ < 30 ? $_ : 30 for $wadd, $hadd;    # 1% or X px minimum expansion
            $offx -= $wadd;
            $offy -= $hadd;
            $w += $wadd*2;
            $h += $hadd*2;

            runcmd 'convert',
                qw< ( -size >, $pdf_page_size, qw< xc:white ) >,   # Create white layer

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

                $outimg;
        }
    }

    #return;

    runcmd
        'tesseract',
        '-l' => 'mark',
        $outimg => sprintf( "page_output/%03d", $page->{num} ),
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

sub tmpfile {
    my %ARGS = @_;
    return File::Temp->new(
        TEMPLATE =>'tmpXXXXXXXX',
        UNLINK => 1,
        %ARGS
    );
}
