#!/usr/bin/perl
use threads;
use utf8;
use strict;
use warnings;
use List::Util 'first';
use BookConf;
use Path::Tiny;
use Data::Dumper;
use Thread::Queue;
use Sys::CpuAffinity;
use File::Temp ();
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
}

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
        "output/" . $page->{page_type} . '_blank_mask.png' );
}, sub {
    my ($q) = @_;
    for my $type ('odd', 'even') {
        my $name = BookConf->opt( $type . '_blank_page' );
        my $page = first { $_->{file} eq $name } @pages;
        if( !$page ) {
            die "No blank $type page specified in config";
        }

        $q->enqueue( $page );
    }
});

run_multi( \&process_page, sub {
    my ($q) = @_;
    $q->enqueue( @pages );
}, 1.5);

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

    print "@cmd\n" if $DEBUG;
    system @cmd;

    if ($? == -1) {
        print "failed to execute: $!\n";
    } elsif ($? & 127) {
        printf "child died with signal %d, %s coredump\n",
           ($? & 127),  ($? & 128) ? 'with' : 'without';
    } else {
        my $val = $? >> 8;
        if( $val != 0 ) {
            printf "child exited with value %d\n", $val;
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
            EXTENSION => "." . $OUT_EXT
        );
        $outimg = $tmpimg->filename
    }

    if( #0 &&
            1 ) {
        runcmd 
            'convert',
                $page->{file},
                '-auto-orient',
                '-crop' => $crop, '+repage',
                '-resize' => '4000x4000',
                '-colorspace' => 'gray',

                # Now combine in mask image
                'output/' . $page->{page_type} . '_blank_mask.png',
                '-compose' => 'Divide_Src', '-composite',

                '-contrast-stretch', '0',

                # And post-processing
                '-level' => '80%,88%',

                '-morphology' => 'thicken' => '3x1:1,0,1',
                
                $outimg
        ;
    }

    my $txtfile = tmpfile();
    runcmd
        'tesseract',
        '-l' => 'tur',
        $outimg => $txtfile->filename,
        'mark';

    my $real_txt = $txtfile->filename . ".txt";
    $return_q->enqueue( {
        %$page,
        text => path( $real_txt )->slurp_utf8
    });
    #print path( $real_txt )->slurp_utf8, "\n";

    unlink $real_txt;

    print Dumper $page;
}

# Run specified number of processes as subthread using queue. Returns when all
# work has been completed.
sub run_multi {
    my ($process_func, $main_thread, $thread_divisor) = @_;
    my $NUM_CPUS = Sys::CpuAffinity::getNumCpus();
    my $MAX_THREADS = $NUM_CPUS / ($thread_divisor || 1);
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
