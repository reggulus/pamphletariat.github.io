#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use open ':std', ':encoding(UTF-8)';

use File::Find;
use HTML::TreeBuilder;
use Encode qw(decode);
my $root = shift or die "usage: tah_dir_to_md.pl DIRECTORY\n";
# ---------------- AUTHOR DETECTION ----------------
sub detect_author {
    my ($title, $text) = @_;

    return "Brutus"         if $title =~ /\bBrutus\b/i || $text =~ /\bBrutus\b/i;
    return "Federal Farmer" if $title =~ /Federal Farmer/i;
    return "Cato"           if $title =~ /\bCato\b/i;
    return "Centinel"       if $title =~ /\bCentinel\b/i;
    return "Publius"        if $title =~ /\bFederalist\b/i;

    return "Unknown";
}

# ---------------- CLEANER ----------------
sub clean {
    my ($s) = @_;
    $s //= '';

    # Drop bracketed numeric footnote markers like [1], [2], etc.
    # Do this early so whitespace normalization doesn't leave artifacts.
    $s =~ s/\s*\[(?:\d+)\]\s*/ /g;

    $s =~ s/\s+/ /g;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}
# ---------------- WALK DIRECTORY ----------------
find(
    {
        wanted => sub {
            return unless /\.html$/i;
            process_file($File::Find::name);
        },
        no_chdir => 1,
    },
    $root
);

sub process_file {
    my ($html) = @_;
    print "Processing $html\n";

    # Read raw bytes and decode explicitly to avoid mojibake when the source
    # HTML is UTF-8 (or Windows-1252) but charset sniffing is wrong.
    open my $fh, '<:raw', $html or do { warn "Cannot read $html: $!\n"; return };
    local $/;
    my $bytes = <$fh>;
    close $fh;

    # Try to detect charset from HTML meta tags; default to UTF-8.
    my $charset = 'utf-8';
    if ($bytes =~ /<meta\s+[^>]*charset\s*=\s*['\"]?\s*([^\s'\";>]+)/i) {
        $charset = $1;
    } elsif ($bytes =~ /<meta\s+[^>]*http-equiv\s*=\s*['\"]content-type['\"][^>]*content\s*=\s*['\"][^'\"]*charset\s*=\s*([^\s'\";>]+)/i) {
        $charset = $1;
    }
    $charset = lc $charset;
    $charset =~ s/[^a-z0-9_\-]//g;

    my $decoded;
    eval { $decoded = decode($charset, $bytes, 1); 1 } or do {
        # Common fallback for “smart punctuation” pages that are actually cp1252.
        eval { $decoded = decode('windows-1252', $bytes, 1); 1 } or do {
            $decoded = decode('utf-8', $bytes); # last resort
        };
    };

    my $tree = HTML::TreeBuilder->new;
    $tree->parse_content($decoded);
    # ---------- TITLE ----------
    my $h1 = $tree->look_down(_tag => 'h1')
        or do { warn "No <h1> in $html\n"; return };

    my $title = clean($h1->as_text);

    # ---------- SLUG ----------
    # Per requirement: slug should match the HTML filename (base name) with a .md extension for output.
    # Example: Some-File.html -> slug: some-file, outfile: some-file.md
    my ($base) = $html =~ m{([^/\\]+)\z};
    $base //= $html;
    $base =~ s/\.html\z//i;

    my $slug = lc $base;
    $slug =~ s/\s+/-/g;
    $slug =~ s/[^a-z0-9_-]+/-/g;
    $slug =~ s/-{2,}/-/g;
    $slug =~ s/^-|-$//g;
    # ---------- DATE (semantic header / frontmatter) ----------
    # TeachingAmericanHistory document pages typically render the publish date as:
    #   <ul class="t-single__content-Head-content-meta-dates"><li>December 13, 1787</li></ul>
    # Timeline/listing pages often use:
    #   <div class="o-timeline__slider-Slide-content-date">December 13, 1787</div>

    sub _dbg_codepoints {
        my ($s) = @_;
        $s //= '';
        my $out = '';
        for my $ch (split(//, $s)) {
            my $o = ord($ch);
            if ($o >= 0x20 && $o <= 0x7E) {
                $out .= $ch;
            } else {
                $out .= sprintf('\\x{%04X}', $o);
            }
        }
        return $out;
    }

    sub parse_date_to_iso {
        my ($date_raw, $where) = @_;
        return '' if !defined($date_raw) || $date_raw eq '';

        # NOTE: We intentionally do NOT use Time::Piece here.
        # Many Perl/platform builds cannot parse years < 1900 via strptime/mktime,
        # which breaks historical dates like 1788.

        my $date_norm = $date_raw;

        # Normalize Unicode whitespace/invisibles that commonly break parsing.
        $date_norm =~ s/\x{00A0}/ /g;                    # NBSP
        $date_norm =~ s/\x{202F}/ /g;                    # NARROW NO-BREAK SPACE
        $date_norm =~ s/\x{2009}/ /g;                    # THIN SPACE
        $date_norm =~ s/\x{2060}//g;                     # WORD JOINER
        $date_norm =~ s/[\x{200B}-\x{200D}\x{FEFF}]//g; # zero-width chars
        $date_norm =~ s/[\x{00AD}]//g;                   # soft hyphen

        $date_norm =~ s/[\x{2013}\x{2014}]/-/g;         # en/em dash -> hyphen
        $date_norm =~ s/\s+/ /g;
        $date_norm =~ s/^\s+|\s+$//g;

        # Drop common leading noise.
        $date_norm =~ s/^\s*(?:circa|c\.|ca\.|approx\.|about)\s+//i;

        # Remove ordinal suffixes: 1st/2nd/3rd/4th...
        $date_norm =~ s/\b(\d{1,2})(?:st|nd|rd|th)\b/$1/ig;

        # Normalize month abbreviations with trailing periods.
        $date_norm =~ s/\bSept\./Sep/ig;
        $date_norm =~ s/\bSep\./Sep/ig;
        $date_norm =~ s/\bJan\./Jan/ig;
        $date_norm =~ s/\bFeb\./Feb/ig;
        $date_norm =~ s/\bMar\./Mar/ig;
        $date_norm =~ s/\bApr\./Apr/ig;
        $date_norm =~ s/\bJun\./Jun/ig;
        $date_norm =~ s/\bJul\./Jul/ig;
        $date_norm =~ s/\bAug\./Aug/ig;
        $date_norm =~ s/\bOct\./Oct/ig;
        $date_norm =~ s/\bNov\./Nov/ig;
        $date_norm =~ s/\bDec\./Dec/ig;

        # Strip trailing punctuation that sometimes appears in rendered dates.
        $date_norm =~ s/[\.,;:]+\z//;

        my %mon = (
            jan => 1, january => 1,
            feb => 2, february => 2,
            mar => 3, march => 3,
            apr => 4, april => 4,
            may => 5,
            jun => 6, june => 6,
            jul => 7, july => 7,
            aug => 8, august => 8,
            sep => 9, sept => 9, september => 9,
            oct => 10, october => 10,
            nov => 11, november => 11,
            dec => 12, december => 12,
        );

        my $fail_reason = '';

        # 1) ISO: YYYY-MM-DD
        if ($date_norm =~ /^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$/) {
            my ($y,$m,$d) = ($1,$2,$3);
            return sprintf('%04d-%02d-%02d', $y,$m,$d);
        }

        # 2) "March 06, 1788" or "March 6 1788" (comma optional)
        if ($date_norm =~ /^\s*([A-Za-z]+)\s+(\d{1,2})(?:\s*,\s*|\s+)(\d{4})\s*$/) {
            my ($mname,$d,$y) = ($1,$2,$3);
            my $m = $mon{lc $mname};
            if ($m) {
                return sprintf('%04d-%02d-%02d', $y,$m,$d);
            }
            $fail_reason = "unknown month '$mname'";
        }

        # 3) "6 March 1788"
        if ($date_norm =~ /^\s*(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})\s*$/) {
            my ($d,$mname,$y) = ($1,$2,$3);
            my $m = $mon{lc $mname};
            if ($m) {
                return sprintf('%04d-%02d-%02d', $y,$m,$d);
            }
            $fail_reason = "unknown month '$mname'";
        }

        # 4) "December 1787" -> assume day 01
        if ($date_norm =~ /^\s*([A-Za-z]+)\s+(\d{4})\s*$/) {
            my ($mname,$y) = ($1,$2);
            my $m = $mon{lc $mname};
            if ($m) {
                return sprintf('%04d-%02d-01', $y,$m);
            }
            $fail_reason = "unknown month '$mname'";
        }

        # 5) "1787" -> assume Jan 01
        if ($date_norm =~ /^\s*(\d{4})\s*$/) {
            my $y = $1;
            return sprintf('%04d-01-01', $y);
        }

        my $extra = $fail_reason ? " ($fail_reason)" : '';
        warn "Unparseable date$extra raw='" . _dbg_codepoints($date_raw) . "' norm='" . _dbg_codepoints($date_norm) . "' file=$where\n";
        return '';
    }
    my $date_iso = '';
    my $date_raw = '';

    # Primary: document header date
    if (my $ul = $tree->look_down(
            _tag  => 'ul',
            class => 't-single__content-Head-content-meta-dates'
        )) {
        if (my $li = $ul->look_down(_tag => 'li')) {
            $date_raw = clean($li->as_text);
        }
    }

    # Fallback: timeline/listing date (if present in the HTML)
    if (!$date_raw) {
        if (my $div = $tree->look_down(
                _tag  => 'div',
                class => 'o-timeline__slider-Slide-content-date'
            )) {
            $date_raw = clean($div->as_text);
        }
    }

    if ($date_raw) {
        $date_iso = parse_date_to_iso($date_raw, $html);
    }
    # ---------- BODY (PARAGRAPH HARVEST) ----------
    # IMPORTANT: Do not harvest all <p> tags globally; that pulls in footer text.
    # Prefer the page's main content container(s) and fall back only if needed.
    my @paras;

    my @scopes;
    for my $candidate (
        # Prefer semantic containers first
        ($tree->look_down(_tag => 'main')),
        ($tree->look_down(_tag => 'article')),
        # Common TAH/WP-ish containers (best-effort; harmless if not present)
        ($tree->look_down(_tag => 'div', class => qr/\bt-single__content\b/)),
        ($tree->look_down(_tag => 'div', class => qr/\bcontent\b/)),
        ($tree->look_down(_tag => 'div', class => qr/\bentry-content\b/)),
        ($tree->look_down(_tag => 'section', class => qr/\bcontent\b/))
    ) {
        push @scopes, $candidate if defined $candidate;
    }

    # De-dupe scopes (TreeBuilder nodes stringify to something stable enough for this use)
    if (@scopes) {
        my %seen;
        @scopes = grep { !$seen{"$_"}++ } @scopes;
    } else {
        # Fallback: whole document (old behavior)
        @scopes = ($tree);
    }

    SCOPE:
    for my $scope (@scopes) {
        for my $p ($scope->look_down(_tag => 'p')) {
            my $t = clean($p->as_text);
            next if $t eq '';

            # filter site junk
            next if $t =~ /(conversation-based seminars|study questions|coming soon|world war|related resources)/i;
            next if $t =~ /^Source:/i;

            # filter common site footer/copyright blocks that sometimes appear as <p>
            next if $t =~ /\bTeachingAmericanHistory\.org\b\s+is\s+a\s+project\s+of\s+the\s+Ashbrook\s+Center\b/i;
            next if $t =~ /\bAshland\s+University\b/i && $t =~ /\bAshland,\s+Ohio\b/i;
            next if $t =~ /\b401\s+College\s+Avenue\b/i;
            next if $t =~ /\bPHONE\b.*\(419\)\s*289-5411/i;
            next if $t =~ /\bTOLL\s+FREE\b.*\(877\)\s*289-5411/i;
            next if $t =~ /\bDesigned\s+by\s+Beck\s*&\s*Stone\b/i;
            next if $t =~ /\b©\b\s*\d{4}-\d{4}\s+Ashbrook\s+Center\b/i;

            push @paras, $t;
        }

        # If we found enough paragraphs in a likely content scope, stop.
        last SCOPE if @paras >= 5 && $scope != $tree;
    }

    if (@paras < 5) {
        warn "No body found in $html\n";
        return;
    }

    my $body = join "\n\n", @paras;
    # ---------- AUTHOR ----------
    my $author = detect_author($title, $body);

    # ---------- WRITE ----------
    my $outfile = "$slug.md";    open my $out, '>:encoding(UTF-8)', $outfile
        or die "cannot write $outfile\n";

    print $out <<"YAML";
---
title: "$title"
slug: "$slug"
author: $author
date: $date_iso

era: historical
domain: Politics
subject: US Constitution

topics: []

reading_level: advanced
reader_warning: ""

source_work: "Anti-Federalist Essays"
public_domain: true
transcription_source: "TeachingAmericanHistory.org"
---

$body

YAML

    close $out;
    $tree->delete;
}
