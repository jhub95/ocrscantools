use strict;
use warnings;
use Data::Dumper;

my %lists;
for my $f (<*.jpg>) {
    $f =~ /^(\d+)\./ or next;
    push @{ $lists{ $1 % 2 ? 'odd' : 'even' } }, $f;
}
print Dumper \%lists;

while( my ($type, $files) = each %lists ) {
    # XXX needs to be an even number of differences
    shift @$files if @$files % 2;
    print "@$files\n";

    my @cmd = (
        'convert',
        '-compose' => 'divide_dst',
        shift @$files => '-auto-orient'
    );

    for(@$files) {
        push @cmd,
            $_,
            '-auto-orient',
            '-composite';
    }

    if( $type eq 'odd' ) {
        #push @cmd, '-crop','98%x100%+100%+0';
    } else {
        push @cmd, '-crop','93%x100%+0+0';
    }

    push @cmd, "$type.jpg";
    #push @cmd, qw< -virtual-pixel edge -blur 0x2 -fuzz 50% -trim -format >,
    #    '%[fx:page.x],%[fx:page.y] %[fx:page.x+w],%[fx:page.y+h]',
    #    'info:';
    print "type: $type\n";
    print "@cmd\n";
    system @cmd;
}
