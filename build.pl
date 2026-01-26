#!/usr/bin/env perl

# Pamphletariat website build script

use strict;
use warnings;
use utf8;

use File::Find;
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Spec;

# -------------------------
# CONFIG
# -------------------------

my $CONTENT_DIR = "content/pamphlets";
my $PAGES_DIR = "content/pages";

my $OUT_DIR     = "dist";

my @ASSET_DIRS = ("css", "img");

# Extra deploy artifacts that must be present in the published output.
my $DOWNLOADS_DIR = "content/download";
my $CNAME_FILE    = "CNAME";

# Fixed list of domains.
# Changes only slowly over time.
my %DOMAINS = (
    "Power & Institutions" =>
        "Analysis of how authority is structured within institutions, including formal roles, informal power, and organizational behavior.",

    "Political Economy" =>
        "Analysis of how economic incentives, markets, and planning interact with political and institutional structures.",

    "Systems & Failure" =>
        "Analysis of complex systems, including stability, feedback, risk, and conditions under which systems fail or change.",

    "Legitimacy & Authority" =>
        "Analysis of the sources of authority and legitimacy, including consent, compliance, belief, and moral justification.",

    "Knowledge & Truth" =>
        "Analysis of how knowledge is generated, evaluated, communicated, and constrained within institutions and societies.",

    "Law & Constitution" =>
        "Analysis of legal frameworks, constitutional design, and their relationship to power and governance.",

    "Belief & Axioms" =>
    "Analysis of systems grounded in non-falsifiable commitments, foundational beliefs, or axioms that cannot be resolved through evidence or incentives alone.",

    # If the argument would collapse if its core assumptions were required to be empirically tested or incentive-compatible, it belongs in Belief & Axioms. Otherwise, it doesn’t.
    
    "Coordination & Action" =>
    "Analysis of how groups coordinate, fail to coordinate, or act collectively, including collective action problems, coordination failures, and shared constraints on action.",

);


# -------------------------
# DATA STORES
# -------------------------

my @pamphlets;

my %by_domain;
my %by_subject;
my %by_author;
my %by_year;
my %by_era;
my %by_geography;

# -------------------------
# ENTRY
# -------------------------

clean_output();
copy_assets();
load_pamphlets();
index_pamphlets();
emit_pages();

print "Build complete: $OUT_DIR/\n";

# -------------------------
# CORE PIPELINE
# -------------------------

sub clean_output {
    remove_tree($OUT_DIR) if -d $OUT_DIR;
    make_path($OUT_DIR);
}

sub copy_assets {
    for my $dir (@ASSET_DIRS) {
        next unless -d $dir;
        copy_tree($dir, "$OUT_DIR/$dir");
    }

    # Copy downloads to a stable public path: /download/...
    if (-d $DOWNLOADS_DIR) {
        copy_tree($DOWNLOADS_DIR, "$OUT_DIR/download");
    }

    # Preserve GitHub Pages custom domain configuration.
    if (-f $CNAME_FILE) {
        copy($CNAME_FILE, "$OUT_DIR/CNAME")
          or die "Copy $CNAME_FILE -> $OUT_DIR/CNAME failed: $!";
    }
}
sub load_pamphlets {
    die "Missing content dir: $CONTENT_DIR\n" unless -d $CONTENT_DIR;

    find(
        {
            wanted => sub {
                return unless /\.md$/;
                my $p = parse_pamphlet($File::Find::name);

                # Drafts are never included.
                return if ($p->{status} && $p->{status} eq "draft");

                # Domain must be in the fixed allowlist. If it's not allowed,
                # do not add the pamphlet to the database/index at all.
                if (defined $p->{domain} && $p->{domain} ne "" && !exists $DOMAINS{$p->{domain}}) {
                    warn "Skipping: $File::Find::name uses unknown domain '$p->{domain}' (not in %DOMAINS).\n";
                    return;
                }

                push @pamphlets, $p;
            },
            no_chdir => 1,
        },
        $CONTENT_DIR
    );

    # Global ordering should be newest-to-oldest using full `date` when available.
    # This drives the home page "Latest Additions" and the global feeds.
    @pamphlets = sort_newest_first(\@pamphlets);}

sub index_pamphlets {
    for my $p (@pamphlets) {
        push @{ $by_domain{ $p->{domain} } }, $p if $p->{domain};
        push @{ $by_author{ $p->{author_id} } }, $p if $p->{author_id};
        push @{ $by_year{   $p->{year}   } }, $p if $p->{year};
        push @{ $by_era{    $p->{era}    } }, $p if $p->{era};
        push @{ $by_subject{$_} },   $p for @{ $p->{subjects}   || [] };
        push @{ $by_geography{$_} }, $p for @{ $p->{geography} || [] };
    }
}

sub emit_pages {
    emit_root_index();
    emit_static_pages();
    emit_pamphlet_pages();

    # Domains are a fixed allowlist (%DOMAINS) and must have pages even when empty,
    # because the homepage always links to them.
    # Ensure every domain key exists in the index with an (empty) arrayref.
    for my $d (keys %DOMAINS) {
        $by_domain{$d} ||= [];
    }

    emit_index_group("domains",   \%by_domain);
    emit_index_group("subjects",  \%by_subject);
    emit_index_group("authors",   \%by_author);
    emit_index_group("years",     \%by_year);
    emit_index_group("eras",      \%by_era);
    emit_index_group("geography", \%by_geography);

    # Feeds (global + per index pages)
    emit_all_feeds();
}
# -------------------------
# FEEDS (RSS 2.0 + Atom)
# -------------------------

sub site_base_url {
    # Prefer explicit base URL via env var for absolute feed URLs.
    # Example: SITE_URL=https://pamphletariat.example
    my $u = $ENV{SITE_URL} // "";
    $u =~ s/\/$//;
    return $u;
}

sub rfc3339_now {
    # Good enough for Atom updated; uses UTC.
    my @g = gmtime(time);
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

sub rfc2822_date {
    my ($epoch) = @_;
    $epoch //= time;
    my @g = gmtime($epoch);
    my @wd = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mo = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf("%s, %02d %s %04d %02d:%02d:%02d GMT", $wd[$g[6]], $g[3], $mo[$g[4]], $g[5]+1900, $g[2], $g[1], $g[0]);
}

sub atom_date_for_pamphlet {
    my ($p) = @_;
    # Prefer full YYYY-MM-DD; else YYYY-MM; else YYYY.
    my $d = $p->{date} // "";
    if ($d =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        return "$1-$2-$3T00:00:00Z";
    }
    if ($d =~ /^(\d{4})-(\d{2})$/) {
        return "$1-$2-01T00:00:00Z";
    }
    my $y = $p->{year} // "";
    if ($y =~ /^(\d{4})$/) {
        return "$1-01-01T00:00:00Z";
    }
    return rfc3339_now();
}

sub abs_url {
    my ($path) = @_;
    my $base = site_base_url();
    return $path if !$base;
    return $base . $path;
}

sub xml_escape {
    my ($s) = @_;
    $s //= "";
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&apos;/g;
    return $s;
}

sub feed_item_summary {
    my ($p) = @_;
    # Keep it simple: author + domain + year.
    my $a = $p->{author} // "";
    my $d = $p->{domain} // "";
    my $y = $p->{year}   // "";
    my $s = join(" · ", grep { defined($_) && $_ ne "" } ($a, $d, $y));
    return $s;
}

sub emit_rss {
    my (%args) = @_;
    my $title = $args{title} // "Pamphletariat";
    my $link  = $args{link}  // "/";
    my $path  = $args{path}  // die "emit_rss missing path";
    my $items = $args{items} // [];

    my $rss_link = abs_url($link);
    my $chan_title = xml_escape($title);
    my $chan_link  = xml_escape($rss_link);
    my $build_date = xml_escape(rfc2822_date(time));

    my @out;
    push @out, qq{<?xml version="1.0" encoding="UTF-8"?>};
    push @out, qq{<rss version="2.0">};
    push @out, qq{<channel>};
    push @out, qq{  <title>$chan_title</title>};
    push @out, qq{  <link>$chan_link</link>};
    push @out, qq{  <description>$chan_title</description>};
    push @out, qq{  <lastBuildDate>$build_date</lastBuildDate>};

    for my $p (@$items) {
        my $it_title = xml_escape($p->{title} // "");
        my $it_link  = xml_escape(abs_url($p->{url} // "#"));
        my $it_guid  = $it_link;
        my $it_desc  = xml_escape(feed_item_summary($p));
        my $it_date  = xml_escape(rfc2822_date(time));

        push @out, qq{  <item>};
        push @out, qq{    <title>$it_title</title>};
        push @out, qq{    <link>$it_link</link>};
        push @out, qq{    <guid isPermaLink="true">$it_guid</guid>};
        push @out, qq{    <description>$it_desc</description>};
        push @out, qq{    <pubDate>$it_date</pubDate>};
        push @out, qq{  </item>};
    }

    push @out, qq{</channel>};
    push @out, qq{</rss>};

    write_file($path, join("\n", @out) . "\n");
}

sub emit_atom {
    my (%args) = @_;
    my $title = $args{title} // "Pamphletariat";
    my $link  = $args{link}  // "/";
    my $path  = $args{path}  // die "emit_atom missing path";
    my $items = $args{items} // [];
    my $self  = $args{self}  // ""; # feed URL path

    my $feed_id = xml_escape(abs_url($self || $link));
    my $feed_title = xml_escape($title);
    my $feed_link  = xml_escape(abs_url($link));
    my $feed_updated = xml_escape(rfc3339_now());

    my @out;
    push @out, qq{<?xml version="1.0" encoding="UTF-8"?>};
    push @out, qq{<feed xmlns="http://www.w3.org/2005/Atom">};
    push @out, qq{  <title>$feed_title</title>};
    push @out, qq{  <id>$feed_id</id>};
    push @out, qq{  <updated>$feed_updated</updated>};
    push @out, qq{  <link href="$feed_link" />};
    if ($self) {
        my $self_abs = xml_escape(abs_url($self));
        push @out, qq{  <link rel="self" href="$self_abs" />};
    }

    for my $p (@$items) {
        my $it_title = xml_escape($p->{title} // "");
        my $it_link  = xml_escape(abs_url($p->{url} // "#"));
        my $it_id    = $it_link;
        my $it_updated = xml_escape(atom_date_for_pamphlet($p));
        my $it_summary = xml_escape(feed_item_summary($p));

        push @out, qq{  <entry>};
        push @out, qq{    <title>$it_title</title>};
        push @out, qq{    <id>$it_id</id>};
        push @out, qq{    <updated>$it_updated</updated>};
        push @out, qq{    <link href="$it_link" />};
        push @out, qq{    <summary>$it_summary</summary>};
        push @out, qq{  </entry>};
    }

    push @out, qq{</feed>};

    write_file($path, join("\n", @out) . "\n");
}

sub emit_all_feeds {
    # Global feeds (all pamphlets; unlimited)
    emit_rss(
        title => "Pamphletariat — All Pamphlets",
        link  => "/",
        path  => "$OUT_DIR/feed.xml",
        items => \@pamphlets,
    );

    emit_atom(
        title => "Pamphletariat — All Pamphlets",
        link  => "/",
        self  => "/atom.xml",
        path  => "$OUT_DIR/atom.xml",
        items => \@pamphlets,
    );

    # Per-index feeds (unlimited; match how list pages are filtered)
    emit_index_feeds("domains",   \%by_domain);
    emit_index_feeds("subjects",  \%by_subject);
    emit_index_feeds("authors",   \%by_author);
    emit_index_feeds("years",     \%by_year);
    emit_index_feeds("eras",      \%by_era);
    emit_index_feeds("geography", \%by_geography);

    # Special case: subjects pages can be filtered by domain via ?domain=...
    emit_subject_domain_combo_feeds();
}

sub emit_index_feeds {
    my ($name, $index) = @_;
    for my $k (keys %$index) {
        my $items = $index->{$k} || [];
        my $slug = slugify($k);
        my $page = "/$name/$slug.html";

        # For eras, do not prefix the label at all (no "Era:" / "Eras:").
        my $pretty_title = ($name eq "eras") ? $k : ("$name: $k");

        emit_rss(
            title => "Pamphletariat — $pretty_title",
            link  => $page,
            path  => "$OUT_DIR/$name/$slug.xml",
            items => $items,
        );

        emit_atom(
            title => "Pamphletariat — $pretty_title",
            link  => $page,
            self  => "/$name/$slug.atom",
            path  => "$OUT_DIR/$name/$slug.atom",
            items => $items,
        );
    }
}

sub emit_subject_domain_combo_feeds {
    # For each domain, compute the subset of each subject within that domain.
    # File naming mirrors the on-page filtering via ?domain=... but is static:
    #   /subjects/<subjectSlug>--domain-<domainSlug>.xml|.atom
    for my $domain_label (keys %by_domain) {
        my $domain_items = $by_domain{$domain_label} || [];
        my $domain_slug  = slugify($domain_label);

        # Count items by subject within domain
        my %by_sub;
        for my $p (@$domain_items) {
            for my $s (@{ $p->{subjects} || [] }) {
                next unless defined $s && $s ne "";
                push @{ $by_sub{$s} }, $p;
            }
        }

        for my $subject_label (keys %by_sub) {
            my $subject_slug = slugify($subject_label);
            my $items = $by_sub{$subject_label} || [];

            my $stem = "$subject_slug--domain-$domain_slug";
            my $page = "/subjects/$subject_slug.html?domain=$domain_slug";

            emit_rss(
                title => "Pamphletariat — subjects: $subject_label (domain: $domain_label)",
                link  => $page,
                path  => "$OUT_DIR/subjects/$stem.xml",
                items => $items,
            );

            emit_atom(
                title => "Pamphletariat — subjects: $subject_label (domain: $domain_label)",
                link  => $page,
                self  => "/subjects/$stem.atom",
                path  => "$OUT_DIR/subjects/$stem.atom",
                items => $items,
            );
        }
    }
}
# -------------------------
# PARSING
# -------------------------

sub parse_pamphlet {
    my ($path) = @_;

    open my $fh, "<:encoding(UTF-8)", $path or die "Open $path: $!";
    my $raw = do { local $/; <$fh> };

    # Slug is authoritative from filename (NEW DIRECTIVE).
    # Frontmatter may contain its own required `slug` field, which is validated
    # per spec but is NOT used for output paths/URLs.
    my ($file_slug) = $path =~ m{/([^/]+)\.md$};
    $file_slug //= "untitled";

    # FRONTMATTER BOUNDARIES (authoritative): YAML between the first two lines containing only "---".
    # Everything before the first --- and after the second --- is NOT frontmatter.
    my @lines = split /\n/, ($raw // ""), -1;
    my $fm_start = -1;
    my $fm_end   = -1;
    for (my $i = 0; $i <= $#lines; $i++) {
        if ($lines[$i] eq "---") {
            $fm_start = $i;
            last;
        }
    }
    die "Missing frontmatter start delimiter (---) in $path\n" if $fm_start < 0;

    for (my $j = $fm_start + 1; $j <= $#lines; $j++) {
        if ($lines[$j] eq "---") {
            $fm_end = $j;
            last;
        }
    }
    die "Missing frontmatter end delimiter (---) in $path\n" if $fm_end < 0;

    my @fm_lines = @lines[ ($fm_start + 1) .. ($fm_end - 1) ];
    my $body = join("\n", @lines[ ($fm_end + 1) .. $#lines ]);

    # YAML parsing (template-driven, minimal subset):
    # - scalars: key: value (single line)
    # - lists: key: then subsequent "- item" lines
    # - comments: lines beginning with "#" inside frontmatter are ignored
    my %m;
    my %is_list = map { $_ => 1 } qw(related_domains geography response_to related);

    for (my $i = 0; $i <= $#fm_lines; $i++) {
        my $line = $fm_lines[$i];

        next if !defined $line;
        next if $line =~ /^#/;          # comment lines
        next if $line =~ /^\s*$/;       # ignore blank lines

        # key: value
        if ($line =~ /^([A-Za-z0-9_]+):\s*(.*)\z/) {
            my ($k, $v) = ($1, $2);

            # List field: key: (empty) followed by dash items
            if ($is_list{$k} && $v eq "") {
                my @vals;
                my $j = $i + 1;
                while ($j <= $#fm_lines) {
                    my $l = $fm_lines[$j];
                    last if !defined $l;
                    last if $l =~ /^#/;                 # comment breaks list
                    last if $l =~ /^\s*$/;             # blank breaks list
                    last if $l =~ /^[A-Za-z0-9_]+:\s*/; # next key breaks list

                    if ($l =~ /^\s*-\s*(.*)\z/) {
                        my $x = $1;
                        # preserve entry as an opaque string; only strip surrounding quotes
                        if ($x =~ /^"(.*)"\z/ || $x =~ /^'(.*)'\z/) { $x = $1; }
                        push @vals, $x;
                        $j++;
                        next;
                    }

                    # Any other non-key, non-dash line is invalid in this limited YAML subset.
                    die "Invalid frontmatter list item syntax in $path near: $l\n";
                }
                $m{$k} = \@vals;
                $i = $j - 1;
                next;
            }

            # Scalar value: preserve exactly (except strip surrounding quotes)
            if ($v =~ /^"(.*)"\z/ || $v =~ /^'(.*)'\z/) { $v = $1; }

            # public_domain must be boolean true/false only if present
            if ($k eq "public_domain") {
                die "Invalid public_domain (must be true/false) in $path\n"
                  unless ($v eq "true" || $v eq "false");
                $m{$k} = ($v eq "true") ? 1 : 0;
                next;
            }

            $m{$k} = $v;
            next;
        }

        die "Invalid frontmatter syntax in $path near: $line\n";
    }

    # Required fields (fatal if missing or invalid)
    for my $req (qw(title slug author_namespace author date domain subject reading_level)) {
        die "Missing required frontmatter field '$req' in $path\n"
          if !exists($m{$req});
    }
    for my $req (qw(title slug author_namespace author date domain subject reading_level)) {
        die "Empty required frontmatter field '$req' in $path\n"
          if (!defined($m{$req}) || $m{$req} eq "");
    }

    # Validation rules
    die "Invalid slug (must be lowercase and match [a-z0-9-]+) in $path\n"
      unless ($m{slug} =~ /^[a-z0-9-]+\z/);

    die "Invalid date (must be YYYY-MM-DD) in $path\n"
      unless ($m{date} =~ /^\d{4}-\d{2}-\d{2}\z/);

    die "Invalid reading_level (must be general|advanced) in $path\n"
      unless ($m{reading_level} eq "general" || $m{reading_level} eq "advanced");

    # domain must exactly match an allowed domain label
    die "Invalid domain '$m{domain}' in $path (not in allowed domain labels)\n"
      unless exists $DOMAINS{$m{domain}};

    # Optional scalar: missing and empty are equivalent
    if (exists $m{reader_warning} && (!defined($m{reader_warning}) || $m{reader_warning} eq "")) {
        delete $m{reader_warning};
    }

    # Optional list fields: if missing or empty, treat as empty list.
    for my $k (qw(related_domains geography response_to related)) {
        if (!exists $m{$k} || !defined $m{$k}) {
            $m{$k} = [];
            next;
        }
        if (ref($m{$k}) eq "ARRAY") {
            # present but empty => empty list (already)
            next;
        }
        # If present as scalar, it's invalid per spec (arrays of strings only)
        die "Invalid frontmatter field '$k' (must be a YAML list of strings) in $path\n";
    }

    # Year derived from strict date
    my ($year) = $m{date} =~ /^(\d{4})-/;
    $m{year} = $year;

    # Author identity
    $m{author_namespace} =~ s/^\s+|\s+$//g;
    $m{author}           =~ s/^\s+|\s+$//g;
    $m{author_id}        = $m{author_namespace} . ":" . $m{author};

    return {
        %m,
        # Output slug is from filename (NEW DIRECTIVE)
        slug => $file_slug,
        era  => era_for_year($m{year}),
        body => md_to_html($body),
        url  => "/pamphlets/$file_slug.html",
    };
}sub safe_year {
    my ($y) = @_;
    return ($y && $y =~ /^\d{4}$/) ? $y : 0;
}

sub format_month_year {
    my ($date, $fallback_year) = @_;

    # Accept YYYY, YYYY-MM, or YYYY-MM-DD.
    # Prefer full precision when available, rendering as: "December 5, 1788".
    if (defined $date && $date =~ /^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$/) {
        my ($y, $m, $d) = ($1, $2, $3);

        # If we only have a bare year, just return it.
        return $y if !defined($m) || $m eq "";

        my %mon = (
            "01" => "January",   "02" => "February", "03" => "March",
            "04" => "April",     "05" => "May",      "06" => "June",
            "07" => "July",      "08" => "August",   "09" => "September",
            "10" => "October",   "11" => "November", "12" => "December",
        );
        my $mn = $mon{$m};

        # Unknown month: fall back to year.
        return $y unless $mn;

        # Month + year only.
        return "$mn $y" if !defined($d) || $d eq "";

        # Month day, year (strip any leading zero from day).
        $d =~ s/^0//;
        return "$mn $d, $y";
    }

    return (defined $fallback_year && $fallback_year ne "") ? $fallback_year : "";
}
sub render_pamphlet_list_row {
    my ($p, $count_text) = @_;

    my $title  = html_escape($p->{title}  // "");
    my $href   = $p->{url} // "#";
    my $author_text = html_escape($p->{author} // "");
    my $author_href = html_escape(author_page_href($p));
    my $author = qq{<a class="author-link" href="$author_href">$author_text</a>};

    my $when   = html_escape(format_month_year($p->{date}, ($p->{year} // "")));

    my $meta_line = join " · ", grep { defined($_) && $_ ne "" } ($author_text, $when);
    my $count_html = ''; #defined($count_text) ? qq{<span class="toc-count">$count_text</span>} : "";

    return qq{        <tr class="toc-item">
          <td class="toc-cell">
            <a class="toc-link has-meta" href="$href">
              <span class="toc-title"><span class="toc-label">$title</span></span>
              <span class="toc-meta"><span class="toc-author">$author</span> · <span class="toc-when">$when</span></span>
              $count_html
            </a>
          </td>
        </tr>};
}
sub era_for_year {
    my ($y) = @_;
    return "" unless $y =~ /^\d{4}$/;
    return "18th-Century" if $y < 1800;
    return "19th-Century" if $y < 1900;
    return "20th-Century" if $y < 2000;

    # Use a modern, reader-friendly label for anything after 1999.
    return "Contemporary";
}
sub slugify {
    my ($s) = @_;
    $s = lc($s // "");
    $s =~ s/[^a-z0-9]+/-/g;
    $s =~ s/^-+|-+$//g;
    return $s || "index";
}
sub author_id_parts {
    my ($author_id) = @_;
    $author_id //= "";
    if ($author_id =~ /\A([^:]*):(.*)\z/) {
        return ($1, $2);
    }
    # Back-compat fallback: treat as display-only author in default namespace
    return ("default", $author_id);
}

sub author_page_href {
    my ($p) = @_;
    my $id = $p->{author_id} // ((($p->{author_namespace} // "default") . ":" . ($p->{author} // "Anonymous")));
    return "/authors/" . slugify($id) . ".html";
}

sub author_display_for_context {
    my (%args) = @_;
    my $author_id    = $args{author_id}    // "";
    my $display_name = $args{display_name} // "";
    my $show_ns      = $args{show_ns}      // 0;

    my ($ns, $name) = author_id_parts($author_id);
    $name = $display_name if defined($display_name) && $display_name ne "";

    return $name if !$show_ns;
    return $name . " (" . $ns . ")";
}
# -------------------------
# EMISSION
# -------------------------

sub emit_root_index {
    my $recent_max = 25;
    my $recent_end = ($#pamphlets < ($recent_max - 1)) ? $#pamphlets : ($recent_max - 1);

    my @recent_rows = map {
        my $domain = html_escape($_->{domain} // "Uncategorized");
        my $year   = html_escape($_->{year}   // "Unknown");

        my $meta_right = "$domain, $year";
        render_pamphlet_list_row($_, $meta_right);
    } @pamphlets[0 .. $recent_end];
    # Split into two equal-ish columns.
    my $half = int((scalar(@recent_rows) + 1) / 2);
    my $recent_left  = join "\n", @recent_rows[0 .. ($half - 1)];
    my $recent_right = join "\n", @recent_rows[$half .. $#recent_rows];
    # Domains to show on the home page.
    # Single source of truth is %DOMAINS; counts come from the pamphlet collection.
    # Home page ordering should be alphabetical.
    my @domains_to_show = sort { lc($a) cmp lc($b) } keys %DOMAINS;
    my %domain_counts = map { $_ => scalar(@{ $by_domain{$_} || [] }) } @domains_to_show;
    # --- HOME PAGE BROWSE TOCS: render as two real table columns (one table per column) ---

    my @domain_rows = map {
        my $label = $_;
        my $count = $domain_counts{$label} // 0;
        my $href  = "/domains/" . slugify($label) . ".html";

        my $count_display = ($count == 0)
          ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
          : $count;

        my $row_inner = qq{              <span class="toc-label">$label</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$count_display</span>};

        # Always link domains on the homepage, even when the count is 0.
        my $link = qq{            <a class="toc-link" href="$href">$row_inner</a>};

        qq{        <tr class="toc-item">
          <td class="toc-cell">
$link
          </td>
        </tr>};
    } @domains_to_show;
    my $domain_half = int((scalar(@domain_rows) + 1) / 2);
    my $domains_left  = join "\n", @domain_rows[0 .. ($domain_half - 1)];
    my $domains_right = join "\n", @domain_rows[$domain_half .. $#domain_rows];

    my $domains_toc = qq{<div class="toc-2col" role="navigation" aria-label="Browse domains">
      <table class="toc-col" role="presentation">
$domains_left
      </table>

      <table class="toc-col" role="presentation">
$domains_right
      </table>
    </div>};

    # Eras to show on the home page (newest to oldest) with a soft cap.
    # Order: Contemporary first, then Nth-century descending (e.g., 20th, 19th, 18th).
    my %era_counts = map { $_ => scalar(@{ $by_era{$_} || [] }) } keys %by_era;

    my $era_rank = sub {
        my ($e) = @_;
        return 10_000 if defined($e) && $e eq "Contemporary";
        return $1 if defined($e) && $e =~ /^(\d+)(?:st|nd|rd|th)-century$/;
        return -1; # unknown/other last
    };

    my @eras_to_show = sort {
        $era_rank->($b) <=> $era_rank->($a)
          ||
        lc($a) cmp lc($b)
    } keys %era_counts;

    my $max_eras = 8;
    @eras_to_show = @eras_to_show[0 .. $max_eras - 1]
        if @eras_to_show > $max_eras;

    my @era_rows = map {
        my $label = $_;
        my $count = $era_counts{$label} // 0;
        my $href  = "/eras/" . slugify($label) . ".html";

        my $count_display = ($count == 0)
          ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
          : $count;

        my $row_inner = qq{              <span class="toc-label">$label</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$count_display</span>};

        my $link_or_text = ($count > 0)
          ? qq{            <a class="toc-link" href="$href">$row_inner</a>}
          : qq{            <div class="toc-link is-disabled" aria-disabled="true">$row_inner</div>};

        qq{        <tr class="toc-item">
          <td class="toc-cell">
$link_or_text
          </td>
        </tr>};
    } @eras_to_show;

    my $era_half = int((scalar(@era_rows) + 1) / 2);
    my $eras_left  = join "\n", @era_rows[0 .. ($era_half - 1)];
    my $eras_right = join "\n", @era_rows[$era_half .. $#era_rows];

    my $eras_toc = qq{<div class="toc-2col" role="navigation" aria-label="Browse eras">
      <table class="toc-col" role="presentation">
$eras_left
      </table>

      <table class="toc-col" role="presentation">
$eras_right
      </table>
    </div>};

    # Other ways to browse (data-driven): unique authors / unique subjects.
    my $unique_authors  = scalar(keys %by_author);
    my $unique_subjects = scalar(keys %by_subject);

    my $authors_count_display  = ($unique_authors == 0)
      ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
      : $unique_authors;

    my $subjects_count_display = ($unique_subjects == 0)
      ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
      : $unique_subjects;

    my @other_rows;

    {
        my $row_inner = qq{              <span class="toc-label">Authors</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$authors_count_display</span>};

        my $link_or_text = ($unique_authors > 0)
          ? qq{            <a class="toc-link" href="/authors/">$row_inner</a>}
          : qq{            <div class="toc-link is-disabled" aria-disabled="true">$row_inner</div>};

        push @other_rows, qq{        <tr class="toc-item">
          <td class="toc-cell">
$link_or_text
          </td>
        </tr>};
    }

    {
        my $row_inner = qq{              <span class="toc-label">Subjects</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$subjects_count_display</span>};

        my $link_or_text = ($unique_subjects > 0)
          ? qq{            <a class="toc-link" href="/subjects/">$row_inner</a>}
          : qq{            <div class="toc-link is-disabled" aria-disabled="true">$row_inner</div>};

        push @other_rows, qq{        <tr class="toc-item">
          <td class="toc-cell">
$link_or_text
          </td>
        </tr>};
    }

    my $other_half = int((scalar(@other_rows) + 1) / 2);
    my $other_left  = join "\n", @other_rows[0 .. ($other_half - 1)];
    my $other_right = join "\n", @other_rows[$other_half .. $#other_rows];

    my $other_toc = qq{<div class="toc-2col" role="navigation" aria-label="Other ways to browse">
      <table class="toc-col" role="presentation">
$other_left
      </table>

      <table class="toc-col" role="presentation">
$other_right
      </table>
    </div>};

    my $inner = qq{
<section class="home-masthead">
  <h1 class="home-title">Pamphletariat</h1>
  <h2 class="home-subtitle">The competition of ideas, in writing.</h2>

<section class="home-pamphlets">
  @{[ render_site_nav() ]}
</section>
</section>


    <div class="toc-divider"></div>

    <div class="browse-grid">
      <nav class="toc">
        <h3 class="toc-heading">Domains</h3>
$domains_toc
      </nav>

      <nav class="toc">
        <h3 class="toc-heading">Eras</h3>
$eras_toc
      </nav>


      <nav class="toc">
        <h3 class="toc-heading">Other Ways to Browse</h3>
$other_toc
      </nav>

    </div>
  </section>


      <div class="toc-divider"></div>

    <h2>Latest Additions</h2>

    <div class="toc-2col" role="navigation" aria-label="Latest Additions">
      <table class="toc-col" role="presentation">
$recent_left
      </table>

      <table class="toc-col" role="presentation">
$recent_right
      </table>
    </div>

};
    write_file(
        "$OUT_DIR/index.html",
        wrap_layout("Pamphletariat", $inner, is_home => 1)
    );
}sub emit_pamphlet_pages {
    my $dir = "$OUT_DIR/pamphlets";
    make_path($dir);

    for my $p (@pamphlets) {
        write_file(
            "$dir/$p->{slug}.html",
            wrap_layout($p->{title}, render_pamphlet($p))
        );
    }
}
sub emit_index_group {
    my ($name, $index) = @_;
    my $dir = "$OUT_DIR/$name";
    make_path($dir);

    my @keys;
    if ($name eq "authors") {
        # Authors landing page should be alphabetical by the *display label* users see:
        #   NAME
        #   NAME (NAMESPACE)  -- only when disambiguation is needed
        # So we must compute duplicate-name disambiguation first, then sort by that label.
        my %count;
        for my $id (keys %$index) {
            my (undef, $nm) = author_id_parts($id);
            $count{$nm}++;
        }
        my %dup_name = map { $_ => 1 } grep { ($count{$_} // 0) > 1 } keys %count;

        my $label_for = sub {
            my ($id) = @_;
            my ($ns, $nm) = author_id_parts($id);
            return $dup_name{$nm} ? "$nm ($ns)" : $nm;
        };

        @keys = sort {
            lc($label_for->($a)) cmp lc($label_for->($b))
              ||
            lc($a) cmp lc($b) # stable tie-breaker
        } keys %$index;
    } else {
        @keys = sort keys %$index;
    }
    write_file(
        "$dir/index.html",
        wrap_layout(ucfirst($name), render_index_landing($name, \@keys))
    );
    for my $k (@keys) {
        my $items = $index->{$k};
        my $slug  = slugify($k);

        # Ensure ALL index listing pages are newest-to-oldest.
        # (Some index types also apply additional specialized behavior in their renderers.)
        my @sorted = sort_newest_first($items);
        $items = \@sorted;
        my $inner;
        if ($name eq "domains") {
            $inner = render_domain_index_page($k, $items);
        } elsif ($name eq "subjects") {
            # Subjects pages may be filtered by domain via ?domain=...
            # Provide feed links for both the base subject feed and the domain-filtered feed.
            my $base = "/subjects/$slug";

            my $domain_slug_js = qq{
<script>
(function () {
  var params = new URLSearchParams(window.location.search);
  var d = params.get('domain');
  if (!d) return;
  d = String(d).toLowerCase();
  var el = document.querySelector('[data-domain-feed-base]');
  if (!el) return;
  var stem = el.getAttribute('data-domain-feed-base');
  var rss  = '/subjects/' + stem + '--domain-' + d + '.xml';
  var atom = '/subjects/' + stem + '--domain-' + d + '.atom';
  var box = document.createElement('p');
  box.className = 'feed-links';
  box.innerHTML = '<a href="' + rss + '">RSS</a> · <a href="' + atom + '">Atom</a>'; 
  el.insertAdjacentElement('afterend', box);
})();
</script>
};

            $inner = render_index_page(
                "Subject: $k",
                $items,
                feed_base  => $base,
                feed_label => "Subject: $k",
            ) . qq{<div data-domain-feed-base="$slug"></div>} . $domain_slug_js;
        } else {
            my $base = "/$name/$slug";

            # For eras, do not prefix the label at all (no "Era:" / "Eras:").
            # Authors pages should read like: "Pamphlets by Brutus (historical)".
            # For other index types, keep a readable singular label.
            my $page_label;
            if ($name eq "eras") {
                $page_label = $k;
            } elsif ($name eq "authors") {
                my ($ns, $nm) = author_id_parts($k);
                my $count_total = scalar(@{ $items || [] });
                $page_label = "Pamphlets by $nm";
                $page_label .= " ($ns)" if defined($ns) && $ns ne "" && $ns ne "default";
                $page_label .= " — $count_total";
            } else {
                $page_label = ucfirst($name) . ": $k";
            }
            $inner = render_index_page(
                $page_label,
                $items,
                feed_base  => $base,
                feed_label => $page_label,
            );
        }
        write_file(
            "$dir/$slug.html",
            wrap_layout("$name: $k", $inner)
        );
    }
}
# -------------------------
# RENDERERS
# -------------------------

sub render_pamphlet {
    my ($p) = @_;

    my $author_text = html_escape($p->{author} // "");
    my $author_href = html_escape(author_page_href($p));
    my $author_html = qq{<a class="author-link" href="$author_href">$author_text</a>};

    my $year = html_escape($p->{year} // "");

    return qq{
<article class="pamphlet">
  <h1>$p->{title}</h1>
  <p class="meta">$author_html · $year</p>
  <div class="pamphlet-body">
$p->{body}
  </div>
</article>
};
}
sub render_index_landing {
    my ($name, $keys) = @_;

    # Special handling for authors:
    # keys are canonical author_id values (namespace:author)
    # Disambiguate duplicates by showing namespace in parentheses only when needed.
    my %dup_name;
    if ($name eq "authors") {
        my %count;
        for my $id (@$keys) {
            my (undef, $nm) = author_id_parts($id);
            $count{$nm}++;
        }
        $dup_name{$_} = 1 for grep { $count{$_} && $count{$_} > 1 } keys %count;
    }

    my @rows = map {
        my $key  = $_;
        my $href = "/$name/" . slugify($key) . ".html";

        my $label = $key;
        if ($name eq "authors") {
            my ($ns, $nm) = author_id_parts($key);
            $label = $dup_name{$nm} ? "$nm ($ns)" : $nm;
        }

        # Counts for landing pages: show how many pamphlets are in this bucket.
        my $count = 0;
        if ($name eq "authors") {
            $count = scalar(@{ $by_author{$key} || [] });
        }

        my $count_display = ($count == 0)
          ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
          : $count;

        $label = html_escape($label);

        qq{        <tr class="toc-item">
          <td class="toc-cell">
            <a class="toc-link" href="$href">
              <span class="toc-label">$label</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$count_display</span>
            </a>
          </td>
        </tr>};
    } @$keys;

    my $half = int((scalar(@rows) + 1) / 2);
    my $left  = join "\n", @rows[0 .. ($half - 1)];
    my $right = join "\n", @rows[$half .. $#rows];

    my $heading = ($name eq "authors") ? "<h1>Authors</h1>\n" : "";

    return qq{
$heading<div class="toc-2col" role="navigation" aria-label="Browse $name">
  <table class="toc-col" role="presentation">
$left
  </table>

  <table class="toc-col" role="presentation">
$right
  </table>
</div>
};
}sub render_index_page {    my ($label, $items, %opts) = @_;

    # Optional feed metadata
    my $feed_base  = $opts{feed_base}  // ""; # e.g. "/subjects/foo" (without extension)
    my $feed_label = $opts{feed_label} // $label;

    my $feeds = "";
    if ($feed_base) {
        my $rss  = html_escape($feed_base . ".xml");
        my $atom = html_escape($feed_base . ".atom");
        $feeds = qq{<p class="feed-links"><a href="$rss">RSS</a> · <a href="$atom">Atom</a></p>};
    }

    my @rows = map {
        my $year = html_escape($_->{year} // "");
        render_pamphlet_list_row($_, $year);
    } @$items;

    my $half = int((scalar(@rows) + 1) / 2);
    my $left  = $half ? join("\n", @rows[0 .. ($half - 1)]) : "";
    my $right = ($half && @rows > $half) ? join("\n", @rows[$half .. $#rows]) : "";

    return qq{
<section class="browse">
  <h1>} . html_escape($feed_label) . qq{</h1>
  $feeds
</section>

<div class="toc-2col" role="navigation" aria-label="$label">
  <table class="toc-col" role="presentation">
$left
  </table>

  <table class="toc-col" role="presentation">
$right
  </table>
</div>
};
}sub html_escape {
    my ($s) = @_;
    $s //= "";
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub sort_key_newest_first {
    my ($p) = @_;

    # Prefer full date if present:
    #   YYYY-MM-DD  -> YYYYMMDD
    #   YYYY-MM     -> YYYYMM00 (month resolution)
    # Otherwise fall back to year -> YYYY0000
    my $d = $p->{date} // "";
    if ($d =~ /^(\d{4})-(\d{2})-(\d{2})$/) {
        return ($1 * 10_000) + ($2 * 100) + $3;
    }
    if ($d =~ /^(\d{4})-(\d{2})$/) {
        return ($1 * 10_000) + ($2 * 100);
    }

    my $y = safe_year($p->{year});
    return $y * 10_000;
}

sub sort_newest_first {
    my ($items) = @_;
    return sort {
        sort_key_newest_first($b) <=> sort_key_newest_first($a)
          ||
        (($a->{title} // "") cmp ($b->{title} // ""))
    } @$items;
}
sub subject_counts_for_domain_items {
    my ($domain_items) = @_;
    my %counts;
    for my $p (@$domain_items) {
        for my $s (@{ $p->{subjects} || [] }) {
            next unless defined $s && $s ne "";
            $counts{$s}++;
        }
    }
    return \%counts;
}

sub render_domain_index_page {
    my ($domain_label, $domain_items) = @_;

    my @sorted = sort_newest_first($domain_items);

    # 1) Freshest Dozen pamphlets
    my $max = 12;
    my $end = ($#sorted < ($max - 1)) ? $#sorted : ($max - 1);
    my @recent_rows;
    if (@sorted) {
        @recent_rows = map {
            my $year = html_escape($_->{year} // "");
            render_pamphlet_list_row($_, $year);
        } @sorted[0 .. $end];    }

    my $half = int((scalar(@recent_rows) + 1) / 2);
    my $recent_left  = $half ? join("\n", @recent_rows[0 .. ($half - 1)]) : "";
    my $recent_right = ($half && @recent_rows > $half) ? join("\n", @recent_rows[$half .. $#recent_rows]) : "";

    my $pamphlets_toc = qq{<div class="toc-2col" role="navigation" aria-label="Freshest Dozen in $domain_label">
      <table class="toc-col" role="presentation">
$recent_left
      </table>

      <table class="toc-col" role="presentation">
$recent_right
      </table>
    </div>};

    # 2) Browse subjects in this domain (like other TOCs)
    my $domain_slug = slugify($domain_label);
    my $sc = subject_counts_for_domain_items($domain_items);
    my @subjects = sort { lc($a) cmp lc($b) } keys %$sc;

    my @subject_rows = map {
        my $label = $_;
        my $count = $sc->{$label} // 0;
        my $href  = "/subjects/" . slugify($label) . ".html?domain=$domain_slug";

        my $count_display = ($count == 0)
          ? qq{<span class="toc-zero" aria-label="none">&mdash;</span>}
          : $count;

        my $row_inner = qq{              <span class="toc-label">} . html_escape($label) . qq{</span>
              <span class="toc-leader" aria-hidden="true"></span>
              <span class="toc-count">$count_display</span>};

        my $link_or_text = ($count > 0)
          ? qq{            <a class="toc-link" href="$href">$row_inner</a>}
          : qq{            <div class="toc-link is-disabled" aria-disabled="true">$row_inner</div>};

        qq{        <tr class="toc-item">
          <td class="toc-cell">
$link_or_text
          </td>
        </tr>};
    } @subjects;

    my $sub_half = int((scalar(@subject_rows) + 1) / 2);
    my $sub_left  = $sub_half ? join("\n", @subject_rows[0 .. ($sub_half - 1)]) : "";
    my $sub_right = ($sub_half && @subject_rows > $sub_half) ? join("\n", @subject_rows[$sub_half .. $#subject_rows]) : "";

    my $subjects_toc = qq{<div class="toc-2col" role="navigation" aria-label="Browse subjects in $domain_label">
      <table class="toc-col" role="presentation">
$sub_left
      </table>

      <table class="toc-col" role="presentation">
$sub_right
      </table>
    </div>};

    my $count_total = scalar(@$domain_items);
    my $rss  = "/domains/$domain_slug.xml";
    my $atom = "/domains/$domain_slug.atom";

    my $desc = $DOMAINS{$domain_label} // "";
    my $desc_html = ($desc ne "") ? ("  <p class=\"domain-desc\">" . html_escape($desc) . "</p>\n") : "";

    return qq{

  <h1>} . html_escape($domain_label) . qq{ &mdash; $count_total</h1>
$desc_html  <p class="feed-links"><a href="$rss">RSS</a> · <a href="$atom">Atom</a></p>
<hr>
<section>
  <h2>Latest Additions</h2>
  $pamphlets_toc
</section>

<hr>


  <h2>Domain Subjects</h2>
  $subjects_toc

};
}# -------------------------
# LAYOUT
# -------------------------

sub render_site_nav {
    # Single source of truth for the site navigation links.
    # Used in both the home/header area and the footer.
    return qq{
<nav class="site-nav" aria-label="Site">
  <div class="nav-inner">
    <a href="/why/">Why</a> ·
    <a href="/submit/">Submissions</a> ·
    <a href="/involvement/">Get Involved</a>
  </div>
</nav>
};
}
sub wrap_layout {
    my ($title, $content, %opts) = @_;
    my $is_home = $opts{is_home} // 0;

    my $header = "";
    unless ($is_home) {
        $header = qq{
<header class="site-header">
  <div class="header-inner">
    <a class="site-title" href="/">Pamphletariat</a>
    <div class="site-caveat" aria-hidden="true">caveat lector</div>
  </div>
</header>
};
    }

    my $footer = qq{
<footer class="site-footer">
  @{[ render_site_nav() ]}
</footer>
};

    return qq{
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$title</title>
<link rel="stylesheet" href="/css/style.css">
</head>
<body>
$header
<main>
$content
</main>
$footer
</body>
</html>
};
}
# -------------------------
# FILE OPS
# -------------------------

sub write_file {
    my ($path, $content) = @_;
    open my $fh, ">:encoding(UTF-8)", $path or die "Write $path: $!";
    print $fh $content;
    close $fh;
}

sub copy_tree {
    my ($src, $dst) = @_;
    make_path($dst);

    find(
        {
            wanted => sub {
                my $from = $File::Find::name;
                return if $from eq $src;
                my $rel = $from; $rel =~ s/^\Q$src\E\/?//;
                my $to = File::Spec->catfile($dst, $rel);

                if (-d $from) { make_path($to); return }
                copy($from, $to) or die "Copy $from -> $to failed: $!";
            },
            no_chdir => 1,
        },
        $src
    );
}

# -------------------------
# MARKDOWN (minimal)
# -------------------------

sub md_to_html {
    my ($md) = @_;
    $md =~ s/\r\n?/\n/g;

    my @out;
    my @lines = split /\n/, $md;
    my @para;

    # Stack of active ordered lists by indent level (in spaces).
    # Each entry is a hash: { indent => N, open_li => 0|1 }
    my @ol_stack;

    my $close_open_li = sub {
        return unless @ol_stack;
        if ($ol_stack[-1]{open_li}) {
            push @out, "</li>";
            $ol_stack[-1]{open_li} = 0;
        }
    };

    my $close_ols_to_indent = sub {
        my ($target_indent) = @_; # close while current indent > target_indent
        while (@ol_stack && $ol_stack[-1]{indent} > $target_indent) {
            $close_open_li->();
            push @out, "</ol>";
            pop @ol_stack;
        }
    };

    my $close_all_ols = sub {
        $close_ols_to_indent->(-1);
    };

    my $flush_para = sub {
        push @out, "<p>" . md_inline(join " ", @para) . "</p>" if @para;
        @para = ();
    };

    for my $l (@lines) {
        # Blank line: ends paragraphs and lists
        if ($l =~ /^\s*$/) {
            $flush_para->();
            $close_all_ols->();
            next;
        }

        # Horizontal rule (Markdown: ---)
        if ($l =~ /^\s*---\s*$/) {
            $flush_para->();
            $close_all_ols->();
            push @out, "<hr>";
            next;
        }

        # ATX headings (Markdown: # .. ######)
        if ($l =~ /^\s*(#{1,6})\s+(.*)$/) {
            my $level = length($1);
            my $text  = $2;
            $text =~ s/\s+#+\s*$//;  # allow optional closing #'s
            $flush_para->();
            $close_all_ols->();
            push @out, "<h$level>" . md_inline($text) . "</h$level>";
            next;
        }

        # Blockquote
        if ($l =~ /^>\s?(.*)$/) {
            $flush_para->();
            $close_all_ols->();
            push @out, "<blockquote><p>" . md_inline($1) . "</p></blockquote>";
            next;
        }

        # Ordered list item: e.g., "1. Item"
        # Supports nesting based on leading spaces (2+ spaces deeper than parent).
        if ($l =~ /^(\s*)(\d+)\.\s+(.*)$/) {
            my $indent = length($1 // "");
            my $text   = $3;

            $flush_para->();

            # Close lists if indentation decreased
            my $current_indent = @ol_stack ? $ol_stack[-1]{indent} : -1;
            if (@ol_stack && $indent < $current_indent) {
                $close_ols_to_indent->($indent);
            }

            # If starting a new (possibly nested) list
            $current_indent = @ol_stack ? $ol_stack[-1]{indent} : -1;
            if (!@ol_stack || $indent > $current_indent) {
                # If nesting under an existing <li>, keep it open; otherwise ok.
                push @out, "<ol>";
                push @ol_stack, { indent => $indent, open_li => 0 };
            } else {
                # Same list level: close previous <li> if still open
                $close_open_li->();
            }

            push @out, "<li>" . md_inline($text);
            $ol_stack[-1]{open_li} = 1;
            next;
        }

        # Any other line: treat as paragraph text (and end any active list)
        $close_all_ols->();
        push @para, $l;
    }

    $flush_para->();
    $close_all_ols->();
    return join "\n", @out;
}
sub md_inline {
    my ($t) = @_;
    $t =~ s/&/&amp;/g;
    $t =~ s/</&lt;/g;
    $t =~ s/>/&gt;/g;
    $t =~ s/\*\*(.*?)\*\*/<strong>$1<\/strong>/g;
    $t =~ s/\*(.*?)\*/<em>$1<\/em>/g;
    return $t;
}

sub emit_static_pages {
    return unless -d $PAGES_DIR;

    find(
        {
            wanted => sub {
                return unless /\.(md|html)$/;
                my $path = $File::Find::name;

                open my $fh, "<:encoding(UTF-8)", $path
                    or die "Open $path: $!";
                my $raw = do { local $/; <$fh> };

                my %meta;
                my $body = $raw;

                # Frontmatter only if it starts the file
                # (supported for both .md and .html)
                if ($raw =~ /\A---\n(.*?)\n---\n(.*)\z/s) {
                    my $meta_raw = $1;
                    $body        = $2;

                    for my $line (split /\n/, $meta_raw) {
                        next unless $line =~ /^(\w+):\s*(.*)$/;
                        my ($k, $v) = ($1, $2);
                        $v =~ s/^\s+|\s+$//g;
                        $meta{$k} = $v;
                    }
                }

                my ($slug, $ext) = $path =~ m{/([^/]+)\.(md|html)$};
                $slug //= "page";
                $ext  //= "md";

                my $title = $meta{title} // ucfirst($slug);

                my $page_inner = ($ext eq "md") ? md_to_html($body) : $body;

                my $html = wrap_layout(
                    $title,
                    $page_inner
                );

                my $dir = "$OUT_DIR/$slug";
                make_path($dir);
                write_file("$dir/index.html", $html);
            },
            no_chdir => 1,
        },
        $PAGES_DIR
    );
}
