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

sub test_crop_detect {
    my ($params, $exp) = @_;
    my ($f) = shift @$params;
    $exp = [ map { my ($x,$y) = split ' '; { x => $x, y => $y } } @$exp ];
    eq_or_diff [$b->auto_crop_detect( "$TEST_DIR/$f", @$params )], $exp,
        "$f should have crop detection correct";
}

test_crop_detect( [ 'normal_nocrop_01.jpg' ], [
            '10 1050',
            '10 3770',
            '1610 3810',
            '1700 1100'
        ]);

test_crop_detect( ['normal_nocrop_02.jpg']
        => [
            '10 1190',
            '10 3690',
            '1650 3690',
            '1680 1210'
        ]);

test_crop_detect( ['fullscreen_nocrop_01.jpg']
        => [
            '10 10',
            '10 4590',
            '3200 4590',
            '3240 10'
        ]);

test_crop_detect( [ 'fullscreen_nocrop_02.jpg' ]
        => [
            '10 10',
            '50 4500',
            '3210 4540',
            '3290 10'

        ]);

test_crop_detect([ 'normal_crop_01.jpg','94.5%x100%+0+0', 'even' ]
        => [
            '3250 1100',
            '1580 1130',
            '1640 3790',
            '3250 3760'
        ]);

test_crop_detect( [ 'normal_crop_02.jpg','94.5%x100%+0+0', 'even' ]
        => [
            '1660 1240',
            '1630 3680',
            '3190 3690',
            '3200 1250'
        ]);

test_crop_detect( [ 'fullscreen_crop_01.jpg','94.5%x100%+0+0', 'even' ]
        => [
            '80 70',
            '100 4590',
            '3180 4590',
            '3250 60'
        ]);

test_crop_detect( ['fullscreen_crop_02.jpg','94.5%x100%+0+0', 'even']
        => [
            '60 10',
            '140 4590',
            '3180 4570',
            '3250 10'
        ]);
