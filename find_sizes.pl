use strict;
use warnings;
use FindBin;        
use lib $FindBin::Bin;
use BookConf;
use Data::Dumper;

my ($base) = $0 =~ m!(.*)/[^/]*$!;
$base ||= '.';

my %lists;
#for my $f (<*.jpg>) {
#    $f =~ /^(\d+)\./ or next;
#    push @{ $lists{ $1 % 2 ? 'odd' : 'even' } }, $f;
#}

for my $file (<*.jpg>) {
#for my $type (qw< odd even >) {
#    my $file = BookConf->opt( $type . "_blank_page" );
    $file =~ m!(\d+)\.jpg$!i;
    my $type = $1 % 2 ? 'odd' : 'even';

    # XXX only use one page
    my @cmd = (
        'convert',
        $file,
        qw< -auto-orient >,
    );

    if( my $crop = BookConf->opt( $type . "_detect_crop" ) ) {
        if( $type eq 'odd' ) {
            # XXX need to adjust output params
            push @cmd, qw< -gravity NorthEast >
        }
        push @cmd, -crop => $crop;
    }

    push @cmd, "/tmp/t.jpg";

    #print "type: $type\n";
    #print "@cmd\n";
    system @cmd;
    #print "$base/detect_page /tmp/t.jpg\n";
    chomp( my $dim = `$base/detect_page /tmp/t.jpg` );
    if( $dim ) {
        my ($w, $h, $x, $y) = $dim =~ /(\d+)x(\d+)\+(\d+)\+(\d+)/;
        #print $type . "_page_crop = ", $dim, "\n";
        print "$file: ", $dim, "\n";
        my $draw = sprintf "rectangle %d,%d %d,%d\n", $x, $y, $x+$w, $y+$h;
        @cmd = (
            'convert', $file,
            qw< -auto-orient -fill none -stroke red -strokewidth 10 -draw >, $draw,
            "output/$file"
        );
        system @cmd;
    }
}
