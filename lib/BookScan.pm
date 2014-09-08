# NOTES
# * Always +repage after a -crop
package BookScan;
use Mouse;
use File::Temp ();
use List::Util qw< min max >;

our @lib;
use FindBin::libs 'export';
my $path = $lib[0];

has [qw< DEBUG AUTOCROP_DEBUG >] => ( is => 'rw' );
has BASE => ( is => 'ro', default => "$path/.." );

sub _generate_crop {
    my ($self, $crop, $page_type) = @_;
    return (
        -gravity => $page_type eq 'even' ? 'NorthWest' : 'NorthEast',
        -crop => $crop,
        -gravity => 'NorthWest',
        '+repage'
    )
}

sub auto_crop_detect {
    my ($self, $file, $crop, $page_type) = @_;

    my $autoimg = $self->_tmpfile( 'auto_crop', '.jpg' );
    my @cmd = (
        'convert', $file, '-auto-orient'
    );
    push @cmd, $self->_generate_crop( $crop, $page_type ) if $crop;
    push @cmd, $autoimg;
    $self->runcmd( @cmd );
    my $debug = $self->AUTOCROP_DEBUG || 0;
    my $cmd = $self->BASE . "/detect_page";
    chomp( my @corners = `$cmd $autoimg $debug` );
    print map { "$_\n" } @corners if $self->DEBUG;
    if( !@corners ) {
        warn "Page dimensions not found for $file\n";
    }

    return map { my ($x,$y) = split ' '; { x => 0+$x, y => 0+$y } } @corners;
}

sub _sort_points {
    my ($self, @points) = @_;
    return () if !@points;

    @points = sort { $a->{y} <=> $b->{y} } @points;

    # order of points now: top-left top-right bottom-left bottom-right
    return (
        sort( { $a->{x} <=> $b->{x} } @points[0,1] ),
        sort( { $a->{x} <=> $b->{x} } @points[2,3] ),
    );
}

sub get_crop_and_distort {
    my ($self, $page_type, $initial_crop, $corners, $middle_no_crop) = @_;

    # Now have 4 points of the corners. Figure out the big rectangle
    # surrounding them, crop, and then move the points to fill the whole
    # square image
    my @points = $self->_sort_points( @$corners );

    #for(my $i = 0; $i < @points; $i++) {
    #    printf "%d,%d\n", @{$points[$i]}{qw<x y>}
    #}

    # Shrink the crop area by a few px
    my $crop_inside = 50;
    if( !$middle_no_crop || $page_type eq 'even' ) {
        $points[$_]{x} += $crop_inside for 0,2;
    }
    if( !$middle_no_crop || $page_type eq 'odd' ) {
        $points[$_]{x} -= $crop_inside for 1,3;
    }

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

    my @im_args = (
        -crop => sprintf("%dx%d+%d+%d", $wh{x}, $wh{y}, $min{x}, $min{y} ),
        '-distort' => 'BilinearReverse' => $distort
    );

    if( $initial_crop ) {
        # first crop each page as used in page_detect and then apply the proper
        # crop on them - easier than trying to second-guess what the first crop
        # did
        unshift @im_args, $self->_generate_crop( $initial_crop, $page_type );
    }

    return (
        im_crop_args => \@im_args,
        dimensions => [ $wh{x}, $wh{y} ],
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
    my ($self, $name, $ext, %extra) = @_;
    return File::Temp->new(
        TEMPLATE => 'tmp-' . $name . '-XXXXXXXX',
        UNLINK => 1,
        SUFFIX => $ext,
        %extra
    );
}

# XXX change this to just a generic tmpfile when we dont run with debug
sub _tmp_page_file { shift->output_page_file( 'tmp-' . shift, @_ ); }
sub _tmp_output_file { shift->output_file( 'tmp-' . shift, @_ ); }

sub output_page_file {
    my ($self, $type, $page, $ext) = @_;
    $ext = '.png' if !defined $ext;
    $self->output_file( $type, "$page->{fullnum}$ext" );
}
sub output_file {
    my ($self, $type, $name) = @_;
    mkdir $type if !-d $type;
    return "$type/$name";
}

1
