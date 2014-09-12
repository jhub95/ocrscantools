#!/usr/bin/perl
use strict;
use warnings;
use Unicode::Normalize 'NFC';
use FindBin;
use lib $FindBin::Bin;
use common;

use open qw(:std :utf8);

# Given a load of text will return words in order of frequency
my %words;
while(<>) {
    chomp;
    $_ = NFC $_;
    for my $w (split /[^'\p{Word}]+/, $_ ) {    # XXX does this provide eg ğĞ in all locale?
        next if !length $w || !common::is_allowed($w);
        $w =~ s/^[']|[']$//g;
        #print $w, "\n";
        $words{$w}++;
    }
}

#use Data::Dumper;
#print Dumper \%chars;

for my $w ( sort { $words{$b} <=> $words{$a} || $a cmp $b } keys %words ) {
    #my $c = $words{$w};
    #print "$w $c\n";
    print "$w\n";
}
