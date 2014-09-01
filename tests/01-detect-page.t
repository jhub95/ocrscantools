use strict;
use warnings;
use FindBin::libs qw(use export);
use BookScan;
use Test::More 'no_plan';
use Test::Differences;

my $BASE = "$lib[0]/../tests";
my $TEST_DIR = "$BASE/detect_page";
my $b = BookScan->new(
);

my $f = 'normal_nocrop_01.jpg';
eq_or_diff [$b->auto_crop_detect( "$TEST_DIR/$f" )]
        => [
            '10 1050',
            '10 3770',
            '1610 3810',
            '1700 1110'
        ],
    "$f should have crop detection correct";

$f = 'normal_nocrop_02.jpg';
eq_or_diff [$b->auto_crop_detect( "$TEST_DIR/$f" )]
        => [
            '10 1190',
            '10 3680',
            '1650 3690',
            '1680 1210'
        ],
    "$f should have crop detection correct";

$f = 'fullscreen_nocrop_01.jpg';
eq_or_diff [$b->auto_crop_detect( "$TEST_DIR/$f" )]
        => [
            '10 1190',
            '10 3680',
            '1650 3690',
            '1680 1210'
        ],
    "$f should have crop detection correct";

