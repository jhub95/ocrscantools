package BookConf;
use strict;
use warnings;

use Config::General;

my $CONF_FILE = 'book.conf';
my %CONFIG;

sub init {
    die "$CONF_FILE does not exist\n" if !-f $CONF_FILE;

    my $cg = Config::General->new(
        -UTF8 => 1,
        -ConfigFile => $CONF_FILE, 
    );

    %CONFIG = (
        # defaults

        $cg->getall
    );
}

sub opt {
    my ($self, $opt) = @_;
    return $CONFIG{$opt};
}

1
