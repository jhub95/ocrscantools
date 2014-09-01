package BookScan;
use Mouse;
use File::Temp ();

our @lib;
use FindBin::libs 'export';
my $path = $lib[0];

has qw< DEBUG > => ( is => 'rw' );
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
    chomp( my @corners = `$self->{BASE}/detect_page $autoimg` );
    if( !@corners ) {
        warn "Page dimensions not found for $file\n";
    }

    return map { my ($x,$y) = split ' '; { x => $x, y => $y } } @corners;
}

sub runcmd {
    my ($self, @cmd) = @_;

    warn "@cmd\n" if $self->{DEBUG};
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
