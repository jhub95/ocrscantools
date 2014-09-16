use strict;
use warnings;
use FindBin::libs qw(use export);
use BookScan;
use Test::More tests => 6;

my $BASE = "$lib[0]/../tests";
my $TEST_DIR = "$BASE/detect_blank";
my $s = BookScan->new(
    #DEBUG => 1
);

for my $f (glob "$TEST_DIR/blank/*") {
    is $s->is_blank( $f ) => 1,
        "$f should be blank";
}

for my $f (glob "$TEST_DIR/notblank/*") {
    is $s->is_blank( $f ) => 0,
        "$f should not be blank";
}
