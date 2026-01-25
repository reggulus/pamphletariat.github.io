#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';
use File::Path qw(make_path);

my $input  = shift or die "Usage: $0 federalist.txt\n";
my $outdir = "pamphlets";

make_path($outdir);

# ---------- read whole file ----------
open my $fh, "<", $input or die "Can't open $input: $!";
local $/;
my $text = <$fh>;
close $fh;

# ---------- normalize newlines ----------
$text =~ s/\r\n/\n/g;
$text =~ s/\r/\n/g;

# ---------- strip Gutenberg header/footer ----------
$text =~ s/\A.*?\*\*\* START OF THIS PROJECT GUTENBERG EBOOK.*?\n//s;
$text =~ s/\n\*\*\* END OF THIS PROJECT GUTENBERG EBOOK.*\z//s;

# ---------- split essays ----------
my @essays = split /\n(?=FEDERALIST No\. \d+)/, $text;

for my $essay (@essays) {
    next unless $essay =~ /^FEDERALIST No\. (\d+)/;
    my $num        = $1;
    my $num_padded = $num; #sprintf("%02d", $num);

    my $series = "federalist";
    my $slug   = sprintf("%s-%d", $series, $num);
    
    my @related;
    push @related, sprintf("%s-%d", $series, $num - 1) if $num > 1;
    push @related, sprintf("%s-%d", $series, $num + 1) if $num < 85;
    
    
    # Remove title line
    $essay =~ s/^FEDERALIST No\. \d+\s*\n//;

    my $date = '1787';
    if( $essay =~ /\s(\w+\s+\d+,\s+\d\d\d\d)/ ) {
	$date = federalist_date_to_iso($1);
    }

    # Split "front matter-ish" chunk vs body (first blank-line break)
    my ($address_block, $body) = split /\n\s*\n/, $essay, 2;
    next unless defined $body;

    # Strip all leading whitespace (spaces/tabs/NBSP) on each line
    for ($address_block, $body) {
        s/^[\t \x{A0}]+//mg;
    }

    # ---------- unwrap body paragraphs ----------
    # 1) Mark paragraph breaks
    $body =~ s/\n\s*\n/\n<<<PARA>>>\n/g;

    # 2) Remove leading whitespace again (post-marking)
    $body =~ s/^[\t \x{A0}]+//mg;

    # 3) Unwrap remaining newlines (hard wraps) into spaces
    $body =~ s/\n/ /g;

    # 4) Normalize spacing
    $body =~ s/ {2,}/ /g;

    # 5) Restore paragraph breaks
    $body =~ s/<<<PARA>>>/\n\n/g;

    # 6) Trim trailing whitespace
    $body =~ s/[ \t]+$//mg;

    # Normalize double hyphen to em dash
    $body =~ s/--/—/g;
    
    # ---------- verse-ish quoted line -> Markdown blockquote ----------
    # Work at paragraph level so we don't fight unwrap.
    my @paras = split /\n{2,}/, $body;

    for my $p (@paras) {
        $p =~ s/^\s+//;
        $p =~ s/\s+$//;

        # If the entire paragraph is a single short quoted line,
        # treat it as verse/pull-quote and render as a blockquote.
        # Examples it should catch:
        #   "Gorgons, hydras, and chimeras dire";
        # It will NOT catch inline quotes in prose paragraphs.
        if ($p =~ /^"[^"\n]{10,200}"[;:,.!?]?\s*$/) {
            $p = "> $p";
        }
    }

    $body = join "\n\n", @paras;

    # ---------- write output ----------
    my $outfile = "$outdir/federalist-$num_padded.md";
    open my $out, ">", $outfile or die "Can't write $outfile: $!";


    print $out <<ENDD;
---
title: "The Federalist No. $num"
slug: "$slug"
author: Publius
date: $date

era: historical

domain: politics
subject: us_constitution

# TEMP
topics:
  - militia
  - executive_power

reading_level: advanced
reader_warning: ""

source: "Project Gutenberg"
public_domain: true

ENDD
    
    if (@related) {
	print $out "related:\n";
	for my $r (@related) {
	    print $out "  - \"$r\"\n";
	}
    }

    print $out "---\n\n";

    # Address block as-is (but no leading whitespace)
    $address_block =~ s/[ \t]+$//mg;
    print $out "$address_block\n\n";

    print $out "$body\n";

    close $out;
    print "Wrote $outfile\n";
}

    use strict;
use warnings;

sub federalist_date_to_iso {
    my ($s) = @_;

    # Example input:
    # "Wednesday, January 9, 1788"

    # Remove weekday if present
    $s =~ s/^[A-Za-z]+,\s*//;

    # Match "Month Day, Year"
    my ($month, $day, $year) =
        $s =~ /([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})/
        or return undef;

    my %month = (
        January   => 1,
        February  => 2,
        March     => 3,
        April     => 4,
        May       => 5,
        June      => 6,
        July      => 7,
        August    => 8,
        September => 9,
        October   => 10,
        November  => 11,
        December  => 12,
    );

    return undef unless exists $month{$month};

    return sprintf "%04d-%02d-%02d", $year, $month{$month}, $day;
}

