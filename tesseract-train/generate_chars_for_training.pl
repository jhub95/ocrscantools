#!/usr/bin/perl
use utf8;
use strict;
use warnings;
use FindBin;
use lib $FindBin::Bin;
use Unicode::Normalize 'NFC';
use List::Util 'shuffle';
use common;

use open qw(:std :utf8);


# Print out up to 30 of the most common words for a given letter, given a set of input text

my %chars;
while(<>) {
    chomp;
    $_ = NFC $_;
    for my $w (split /[\s.,:]+/, $_ ) {
        next if !common::is_allowed($w);
        my @chars = split //, $w;
        for my $c (@chars) {
            next if $c =~ /\s/;
            $chars{$c}{count}++;
            $chars{$c}{words}{$w}++
        }
    }
}
#print map { "$_\n" } sort keys %chars;
#exit;
#use Data::Dumper;
#print Dumper \%chars;
my @words;

my $MAX = 150;
while( my ($c, $d) = each %chars ) {
    my $w = $d->{words};
    my @order = sort { $w->{$b} <=> $w->{$a} } keys %$w;
    @order = @order[0 .. $MAX] if @order > $MAX;
    push @words, @order;
}

my @app = (',', ':', '.', ('') x 200);  # Add back in stuff we lost in the split with appropriate proabilities
@words = map { $_ . $app[rand @app] } @words;
my %words = map { $_ => 1 } @words;     # uniq
@words = shuffle keys %words;

print "@words\n";
#\U@words \L@words\n";
