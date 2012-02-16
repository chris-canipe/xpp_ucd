#!/usr/local/bin/perl
use warnings;
use strict;
use File::Find::Rule;
use FindBin qw($Bin);
use Number::Format qw(format_number);
use Path::Class;
use Set::IntSpan;
use Term::Prompt;
use Term::Size::Any qw(chars);
use Unicode::UCD qw(charinfo);
use XML::Writer;

### Vars.
my $conv_data = dir($Bin, '..', 'conv_data');
my $spanner;

### Load blocks (adapated from the Unicode::UCD source)
my @blocks;
my $block_path;
my $block_file = 'Blocks.txt';
for my $dir (@INC) {
    $block_path = file($dir, 'unicore', $block_file);
    last if -f $block_path;
}
die "Unable to find $block_file in @INC" unless -f $block_path;
open my $BLKS, '<', $block_path;
while (<$BLKS>) {
	s/\s+\z//;
	next if /\A#/ || /\A\s*\z/;
	push @blocks, $_;
}

### Select blocks.
print "Blocks:\n=======\n";
my $blk_num;
map { printf "%3d. %s\n", ++$blk_num, $_ } @blocks;
print "\n";
do {
	my $blocks = prompt(
		'e',
		"Which blocks?",
		'e.g.: 1-4,8,12,20-50',
		'',
		'(?:\d+(?:-\d+)?(?:,|\z))+'
	);
	eval { $spanner = Set::IntSpan->new($blocks); };
	warn "Invalid range.\n" if $@ || do {
		($spanner->elements)[-1] > @blocks && ++$@;
	};
} while ($@);
print STDERR "\n";

### Progress display.
$| = 1;
my ($cols, $rows) = chars;
$cols -= 2;
my $format = "\r  %-${cols}s";

### Remove existing XML.
#map { unlink $_ or die $! } File::Find::Rule->file->name('*.xml')->maxdepth(1)->in($conv_data);

### Loop blocks.
for ($spanner->elements) {

	my $count = 0;

	### Info.
	my ($from, $to, $block_name) = split /\s*(?:;|\.\.)\s*/, $blocks[$_-1];
	(my $div_name = $block_name) =~ s/\W+/_/g;
	$div_name = "${from}_${to}_$div_name";

	### XML.
	my $xml_out = file($conv_data, "$div_name.xml");
	open my $OUT, '>', "$xml_out" or die $!;
	my $XML = XML::Writer->new(
		DATA_MODE => 1,
		DATA_INDENT => 1,
		OUTPUT => $OUT,
		ENCODING => 'utf-8',
	);
	$XML->startTag('ucd', version => Unicode::UCD::UnicodeVersion);
	$XML->startTag('block');
	$XML->dataElement('name', $block_name);
	$XML->startTag('table', tabstyle => 'ucd');
	$XML->startTag('tgroup');
	
	### Loop characters.
	my ($from_dec, $to_dec) = map { hex $_ } ($from, $to);
	for my $cp ($from_dec..$to_dec) {

		printf STDERR $format, 	"Generating $block_name... " . format_number($count) if $count % 10 == 0;

		### Per the font docs: skip XPP's private use area.
		next if $cp >= 63_488 && $cp <= 63_743;

		### Info.
		my $info = charinfo('U+' . sprintf('%x', $cp)) || next;

		### Skip surrogates and unassigned.
		next if $info->{category} =~ /^C[sn]/;

		### A row contains 8 cells.
		if (++$count % 8 == 1) {
			$XML->endTag($XML->current_element) while $XML->in_element('row');
			$XML->startTag('row');
		}

		### Output character.
		$XML->startTag('entry');
			$XML->dataElement('name', $info->{name});
			$XML->startTag('glyph');
				### Use em spaces in place of control characters and spaces.
				$XML->characters(pack 'U', ($info->{category} eq 'Cc' || $info->{code} eq '0020') ? 8195 : $cp);
			$XML->endTag('glyph');
			$XML->dataElement($_, $info->{$_}) for qw(code category);
		$XML->endTag('entry');
	}
	
	### Wrap up row: close or fill out to 8 cells.
	if ($count % 8 == 0) {
		$XML->endTag($XML->current_element) while $XML->in_element('row');
	}
	else {
		$XML->dataElement('entry') for (1..(8 - ($count % 8)));
	}
	
	### Wrap up doc.
	$XML->endTag($XML->current_element) while ! $XML->in_element('ucd');
	$XML->endTag('ucd');
	$XML->end;
	
	### Report.
	printf STDERR $format, 	"Generating $block_name... Complete.";
	print STDERR "\n";
}
