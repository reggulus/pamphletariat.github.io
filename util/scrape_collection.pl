#!/usr/bin/env perl
use strict;
use warnings;

use HTML::TreeBuilder;
use File::Path qw(make_path);

my ($index_url, $keyword) = @ARGV;
die "usage: scrape_collection.pl INDEX_URL KEYWORD\n"
  unless $index_url && $keyword;

my $base = 'https://teachingamericanhistory.org';
my $outdir = $keyword;
$outdir =~ s/\s+/_/g;
make_path($outdir);

# ---- fetch index page ----
system("curl -L '$index_url' -o index.html") == 0
  or die "failed to fetch index\n";

# ---- parse index ----
my $tree = HTML::TreeBuilder->new_from_file('index.html');

my %urls;
for my $a ($tree->look_down(_tag => 'a')) {
    my $href = $a->attr('href') or next;
    my $text = $a->as_text // '';

    next unless ($href =~ /\Q$keyword\E/i || $text =~ /\Q$keyword\E/i);

    $href =~ s/#.*$//;
    $href = "$base$href" if $href =~ m{^/};
    $urls{$href} = 1;
}

$tree->delete;

die "no matching links found\n" unless %urls;

# ---- fetch + extract each page ----
for my $url (sort keys %urls) {
    my ($name) = $url =~ m{/([^/]+)/?$};
    $name ||= 'page';
    my $html = "$outdir/$name.html";
    my $txt  = "$outdir/$name.txt";

    system("curl -L '$url' -o '$html'") == 0
      or die "failed to fetch $url\n";

    my $t = HTML::TreeBuilder->new_from_file($html);

    # YOU MAY TUNE THIS SELECTOR ONCE IF NEEDED
    my $content = $t->look_down(
        _tag  => 'div',
        class => qr/(content|entry|article|body)/i
    );

    unless ($content) {
        warn "no content found in $url\n";
        next;
    }

    my $text = $content->as_text;
    $text =~ s/\r//g;
    $text =~ s/\n{3,}/\n\n/g;
    $text =~ s/[ \t]+/ /g;

    open my $fh, '>', $txt or die $!;
    print $fh $text;
    close $fh;

    $t->delete;
}

print "Done. Output in ./$outdir/\n";
