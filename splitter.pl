# pdftotext -layout '/home/mark/documents/Work Abroad/Turkey/Books/Jerry_Mattix/Hey_Gavur/old/Hey Gavur, Anlatsana, 7. baski -son.pdf' - | perl splitter.pl

use strict;
use warnings;
use utf8;
use Path::Tiny;
binmode \*STDIN, ':utf8';

local $/;
my $inp = <>;
$inp =~ y/ĠġĢ‟„/İŞş''/;

my @pages = split /\f+/, $inp;
my $OUTDIR = 'pdfout';
path($OUTDIR)->remove_tree;
mkdir $OUTDIR;
for( my $i = 0; $i < @pages; $i++) {
    path(sprintf "%s/%03d.txt", $OUTDIR, $i+3)->spew_utf8( $pages[$i] );
}
