package common;
use utf8;
use strict;
use warnings;

sub is_allowed {
    my ($w) = @_;
    return 0 if $w =~ /[^!"\$%&'()*+\-\/0-9;<=>?\@A-Za-z\[\]_a-z,:. |«»ÂÇÔÎÖÛÜâçÊêîôöûüĞğİıŞş`“”\x{2018}\x{2019}]/;
    return 0 if $w =~ /_{2,}/;
    return 0 if $w =~ /\d/ and $w =~ /[a-zA-Z]/;
    return 1;
}

1
