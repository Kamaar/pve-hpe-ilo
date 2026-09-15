package PVE::HPEiLO::Ssacli;

# Locate-LED control for Smart Array bays.
#
# This is the one part of the package that writes to the hardware, and it is
# deliberately the smallest write it could be: light a bay so you know which
# disk to pull. Creating, deleting or transforming arrays is out of scope and
# must stay that way -- a status panel should not be able to destroy data.
#
# ssacli comes from HPE's Management Component Pack, which is not installed by
# default. available() is false without it and the panel hides the control.

use strict;
use warnings;

use PVE::HPEiLO::Exec;

my @SSACLI_PATHS = qw(
    /usr/sbin/ssacli
    /usr/sbin/hpssacli
    /usr/bin/ssacli
    /opt/smartstorageadmin/ssacli/bin/ssacli
);

my $binary;

sub binary {
    $binary //= PVE::HPEiLO::Exec::find_binary(@SSACLI_PATHS);
    return $binary;
}

sub available {
    return defined binary();
}

# The two validators below are load-bearing. exec() is called in list form so
# no shell ever sees these strings, but an unchecked value could still be read
# by ssacli itself as a different keyword. Only the exact shapes the hardware
# produces are allowed through.

sub valid_slot {
    my ($slot) = @_;
    return defined $slot && $slot =~ /^[0-9]{1,3}$/;
}

sub valid_location {
    my ($loc) = @_;

    return 0 if !defined $loc;
    # port:box:bay, as reported by iLO and ssacli alike (1I:3:4, 2E:1:12).
    return 1 if $loc =~ /^[0-9]{1,2}[IE]:[0-9]{1,3}:[0-9]{1,3}$/;
    # Some controllers report the shorter box:bay form.
    return 1 if $loc =~ /^[0-9]{1,3}:[0-9]{1,3}$/;
    return 0;
}

sub set_led {
    my (%param) = @_;

    my $slot = $param{slot};
    my $location = $param{location};
    my $state = $param{state};
    my $timeout = $param{timeout} // 20;

    die "ssacli is not installed on this node\n" if !available();
    die "invalid controller slot\n" if !valid_slot($slot);
    die "invalid drive location\n" if !valid_location($location);
    die "LED state must be on or off\n"
	if !defined $state || ($state ne 'on' && $state ne 'off');

    my @cmd = (binary(), 'ctrl', "slot=$slot", 'pd', $location,
	'modify', "led=$state");

    my ($out, $err) = PVE::HPEiLO::Exec::run($timeout, @cmd);
    die "$err\n" if defined $err;

    # ssacli reports problems in its output rather than in a reliable exit
    # status, so the text is what has to be checked.
    if (defined $out && $out =~ /^\s*Error:\s*(.+?)\s*$/m) {
	die "ssacli: $1\n";
    }

    return $out // '';
}

1;
