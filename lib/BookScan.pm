package BookScan;
use Mouse;
use File::Temp ();
use List::Util qw< min max >;

our @lib;
use FindBin::libs 'export';
my $path = $lib[0];

has [qw< DEBUG AUTOCROP_DEBUG >] => ( is => 'rw' );
has BASE => ( is => 'ro', default => "$path/.." );

sub auto_crop_detect {
    my ($self, $file, $crop, $page_type) = @_;

    my $autoimg = $self->_tmpfile( 'auto_crop', '.jpg' );
    my @cmd = (
        'convert', $file, '-auto-orient'
    );
    if( $crop ) {
        if( $page_type eq 'odd' ) {
            # XXX need to adjust output params
            push @cmd, qw< -gravity NorthEast >
        }
        push @cmd, -crop => $crop;
    }
    push @cmd, $autoimg;
    $self->runcmd( @cmd );
    my $debug = $self->AUTOCROP_DEBUG ? 1 : 0;
    my $cmd = $self->BASE . "/detect_page";
    chomp( my @corners = `$cmd $autoimg $debug` );
    if( !@corners ) {
        warn "Page dimensions not found for $file\n";
    }

    return map { my ($x,$y) = split ' '; { x => 0+$x, y => 0+$y } } @corners;
}

sub get_crop_and_distort {
    my ($self, $corners) = @_;

    # Now have 4 points of the corners. Figure out the big rectangle
    # surrounding them, crop, and then move the points to fill the whole
    # square image
    my @points = sort { $a->{y} <=> $b->{y} } @$corners;

    # order of points now: top-left top-right bottom-left bottom-right
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
            @{$real_points[$i]}{qw< x y >};
    }

    return (
        im_crop_args => [
            -crop => sprintf("%dx%d+%d+%d", $wh{x}, $wh{y}, $min{x}, $min{y} ),
            '-distort' => 'BilinearReverse' => $distort
        ],
        crop_details => [ $wh{x}, $wh{y}, $min{x}, $min{y} ],
    );
}

sub runcmd {
    my ($self, @cmd) = @_;

    warn "@cmd\n" if $self->DEBUG;
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

sub _tmpfile {
    my ($self, $name, $ext) = @_;
    return File::Temp->new(
        TEMPLATE => $name . 'XXXXXXXX',
        UNLINK => 1,
        SUFFIX => $ext,
    );
}

1
