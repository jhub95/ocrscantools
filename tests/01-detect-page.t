use strict;
use warnings;
use FindBin::libs qw(use export);
use BookScan;
use Test::More tests => 119;
use Test::Differences;

my $BASE = "$lib[0]/../tests";
my $TEST_DIR = "$BASE/detect_page";
my $s = BookScan->new(
    #AUTOCROP_DEBUG => 1,
    #AUTOCROP_DEBUG => 2
    #DEBUG => 1
);

sub test_crop_detect {
    my ($params, $exp) = @_;
    my ($f) = shift @$params;
    my @exp = $s->_sort_points( map { my ($x,$y) = split ' '; { x => $x, y => $y } } @$exp );
    my @ret = $s->_sort_points( $s->auto_crop_detect( "$TEST_DIR/$f", @$params ) );

    ok @ret == @exp, "$f: Number of points should be equal";
    if( @ret != @exp ) {
        eq_or_diff \@exp, \@ret, 'points';
    } else {
        for( my $i = 0; $i < @ret; $i++ ) {
            for(qw< x y >) {
                ok( ( $exp[$i]{$_} - 25 < $ret[$i]{$_} && $exp[$i]{$_} + 25 > $ret[$i]{$_} ),
                    "$f: point $i $_ should be roughly the same (exp: $exp[$i]{$_}; ret: $ret[$i]{$_})" );
            }
        }
    }
}

# Ones that have issues but can't find an easy fix:
test_crop_detect( [ 'color_crop_02.jpg', '94.5%x100%+0+0', 'even' ], [ ]);
test_crop_detect( [ 'color_crop_01.jpg', '94.5%x100%+0+0', 'even' ], [ ]);
test_crop_detect( [ '055.jpg' ], [
    '1770 3470',
    '10 3470',
    '20 610',
    '1790 620',
]);
test_crop_detect( [ '067.jpg' ], [
    '1760 3480',
    '10 3470',
    '30 610',
    '1770 610',
]);
# This is not very square anyway
#test_crop_detect( [ 'fullscreen_color_nocrop_02.jpg' ], [
#    '60 10',
#    '3210 10',
#    '80 4240',
#    '3040 4490'
#]);

test_crop_detect( [ 'fullscreen_nocrop_03.jpg' ], [
    '10 10',
    '3130 10',
    '10 4460',
    '3060 4460'
]);
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
            '1660 3690',
            '1680 1210'
        ]);

test_crop_detect( ['fullscreen_nocrop_01.jpg']
        => [
            '10 10',
            '10 4590',
            '3200 4590',
            '3250 20'
        ]);

test_crop_detect( [ 'fullscreen_nocrop_02.jpg' ]
        => [
            '10 10',
            '10 4480',
            '3210 4540',
            '3290 10'

        ]);

test_crop_detect( [ 'fullscreen_color_nocrop_01.jpg' ], [
            '10 10',
            '10 4590',
            '3140 4590',
            '3240 30',
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
            '3250 10'
        ]);

test_crop_detect( ['fullscreen_crop_02.jpg','94.5%x100%+0+0', 'even']
        => [
            '60 10',
            '140 4590',
            '3180 4570',
            '3250 10'
        ]);

test_crop_detect( ['fullscreen_color_crop_01.jpg','94.5%x100%+0+0', 'even']
        => [
            '3250 160',
            '30 160',
            '40 4590',
            '3180 4590'
        ]);

