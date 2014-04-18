use strict;
use warnings;
use Data::Dumper;

my %lists;
for my $f (<*.jpg>) {
    $f =~ /^(\d+)\./ or next;
    push @{ $lists{ $1 % 2 ? 'odd' : 'even' } }, $f;
}

while( my ($type, $files) = each %lists ) {

    # XXX only use one page
    my @cmd = (
        'convert',
        pop @$files,
        qw< -auto-orient >,
    );

    if( $type eq 'odd' ) {
        push @cmd, qw< -gravity NorthEast -crop 98.5%x100%+0+0 >
    } else {
        push @cmd, qw< -crop 92%x100%+0+0 >
    }

    push @cmd,
        qw< -resize 20% -threshold 50% -morphology Smooth:20 square -resize 500% -trim >,
        #qw< -shave 50x50 >,
        qw< -format >,
        $type . '_page_crop = %[fx:w-100]x%[fx:h-100]+%[fx:page.x+50]+%[fx:page.y+50]',
        #'-draw "rectangle %[fx:page.x+50],%[fx:page.y+50] %[fx:page.x+w-50],%[fx:page.y+h-50]"',
        'info:';

    #print "type: $type\n";
    #print "@cmd\n";
    system @cmd;
}
