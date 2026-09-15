package PVE::HPEiLO::Exec;

# Runs a local helper with a hard timeout, with no shell involved.
#
# Shared by the smartctl enrichment and the Smart Array LED control. Both feed
# it values that ultimately come from hardware or from an API caller, so the
# list form of exec() is not a style preference: it is what stops an argument
# from ever being parsed as a command.

use strict;
use warnings;

# Returns (stdout, error). stdout is undef when the command could not be run
# or timed out; error is a short message in that case.
sub run {
    my ($timeout, @cmd) = @_;

    return (undef, 'no command given') if !@cmd;
    return (undef, "$cmd[0] is not executable") if !-x $cmd[0];

    my $pid = open(my $fh, '-|');
    return (undef, "cannot fork: $!") if !defined $pid;

    if (!$pid) {
	# Child. Helpers are chatty on stderr about hardware they cannot
	# identify, and none of it belongs in the journal.
	open(STDERR, '>', '/dev/null');
	exec(@cmd);
	exit 127;
    }

    my $out;
    eval {
	local $SIG{ALRM} = sub { die "timeout\n" };
	alarm($timeout);
	local $/;
	$out = <$fh>;
	alarm(0);
    };
    my $err = $@;

    if ($err) {
	kill('KILL', $pid);
	close($fh);
	chomp $err;
	return (undef, "timed out after ${timeout}s");
    }

    close($fh);

    return ($out, undef);
}

# Finds the first executable among a list of candidate paths.
sub find_binary {
    my (@candidates) = @_;

    for my $path (@candidates) {
	return $path if -x $path;
    }

    return undef;
}

1;
