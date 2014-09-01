package BookConf;
use strict;
use warnings;

use Config::General;

my $CONF_FILE = 'book.conf';

my $cg = Config::General->new(
    -UTF8 => 1,
    -ConfigFile => $CONF_FILE, 
);


my %CONFIG = (
    # defaults

    $cg->getall
);

sub opt {
    my ($self, $opt) = @_;
    return $CONFIG{$opt};
}

1
