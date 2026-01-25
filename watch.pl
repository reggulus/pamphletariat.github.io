#!/usr/bin/env perl
use strict;
use warnings;

use File::ChangeNotify;
use Time::HiRes qw(sleep);
use POSIX qw(:sys_wait_h);

my @WATCH_DIRS = (
    "content",
    "css",
    "img",
    "build.pl",
);

# -------------------------
# start livereload server (quiet)
# -------------------------

my $server_pid = fork();
die "fork failed\n" unless defined $server_pid;

if ($server_pid == 0) {
    open STDOUT, ">/dev/null" or die "redirect STDOUT failed\n";
    open STDERR, ">/dev/null" or die "redirect STDERR failed\n";
    exec("python", "serve.py") or die "exec serve.py failed\n";
}

# -------------------------
# setup watcher
# -------------------------

my $watcher = File::ChangeNotify->instantiate_watcher(
    directories => \@WATCH_DIRS,
    filter      => qr/\.(md|html?|pl|css|png|jpg|jpeg|webp|svg)$/i,
);

# -------------------------
# initial build (quiet)
# -------------------------

{
    open my $oldout, ">&", \*STDOUT;
    open my $olderr, ">&", \*STDERR;
    open STDOUT, ">/dev/null";
    open STDERR, ">/dev/null";

    my $rc = system("perl", "build.pl");

    open STDOUT, ">&", $oldout;
    open STDERR, ">&", $olderr;

    die "Initial build failed\n" if $rc != 0;
}

# -------------------------
# clean shutdown on Ctrl-C
# -------------------------

$SIG{INT} = sub {
    kill 'TERM', $server_pid;
    waitpid($server_pid, 0);
    exit 0;
};

# -------------------------
# watch loop (quiet)
# -------------------------

while (1) {
    my @events = $watcher->wait_for_events(timeout => 1);
    next unless @events;

    my $rc;
    {
        open my $oldout, ">&", \*STDOUT;
        open my $olderr, ">&", \*STDERR;
        open STDOUT, ">/dev/null";
        open STDERR, ">/dev/null";

        $rc = system("perl", "build.pl");

        open STDOUT, ">&", $oldout;
        open STDERR, ">&", $olderr;
    }

    warn "Build failed\n" if $rc != 0;
    sleep 0.25;
}
