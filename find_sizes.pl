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

for my $type (qw< odd even >) {
    my $file = BookConf->opt( $type . "_blank_page" );

    # XXX only use one page
    my @cmd = (
        'convert',
        $file,
        qw< -auto-orient >,
    );

    if( $type eq 'odd' ) {
        #push @cmd, qw< -gravity NorthEast -crop 98.5%x100%+0+0 >
    } else {
        push @cmd, qw< -crop 94%x100%+0+0 >
    }
    push @cmd, "/tmp/t.jpg";

    #print "type: $type\n";
    #print "@cmd\n";
    system @cmd;
    #print "$base/detect_page /tmp/t.jpg\n";
    chomp( my $dim = `$base/detect_page /tmp/t.jpg` );
    print $type . "_page_crop = ", $dim, "\n";
}
