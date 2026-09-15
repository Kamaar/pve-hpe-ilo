package PVE::HPEiLO::Smart;

# Optional in-band enrichment for the physical drive list.
#
# A Smart Array passes drive temperature and run time out of band only for
# drives whose firmware HPE recognizes; with third-party disks in HP carriers
# both iLO and ssacli report nothing. smartctl talks to each drive through the
# controller's passthrough instead, which sidesteps that entirely.
#
# smartmontools ships with Proxmox VE, so this adds no package dependency. If
# it is missing or fails, the panel simply keeps showing what iLO gave us.

use strict;
use warnings;

# Debian puts it in /usr/sbin, but do not bet the feature on that.
my @SMARTCTL_PATHS = qw(
    /usr/sbin/smartctl
    /sbin/smartctl
    /usr/bin/smartctl
    /usr/local/sbin/smartctl
);

my $binary;

sub binary {
    return $binary if defined $binary;
    for my $path (@SMARTCTL_PATHS) {
	next if !-x $path;
	$binary = $path;
	return $binary;
    }
    return undef;
}

# Physical drive slots to probe on the controller. Scanning stops early at the
# first index that returns nothing, so this is only an upper bound.
use constant MAX_INDEX => 32;

sub available {
    return defined binary();
}

# Runs a command with a hard timeout, returning its stdout or undef. No shell
# is involved: every argument is passed through as a separate word.
sub _run {
    my ($timeout, @cmd) = @_;

    my $pid = open(my $fh, '-|');
    return undef if !defined $pid;

    if (!$pid) {
	# Child. smartctl is chatty on stderr about drives it cannot identify.
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
	$out = undef;
    }

    close($fh);

    # smartctl's exit status is a bitmask and is non-zero for conditions as
    # mild as "a self-test log entry exists", so it says nothing useful about
    # whether the output is usable. Parse it and judge by what came back.
    return $out;
}

sub _parse {
    my ($text) = @_;

    return undef if !defined $text || $text eq '';

    my $out = {};

    # SAS drives report "Serial number:", SATA "Serial Number:".
    if ($text =~ /^Serial [Nn]umber:\s*(\S+)/m) {
	$out->{serial} = $1;
    }

    # SCSI/SAS form.
    if ($text =~ /^Current Drive Temperature:\s*(\d+)/m) {
	$out->{celsius} = $1 + 0;
    } elsif ($text =~ /^Temperature:\s*(\d+)\s*Celsius/m) {
	$out->{celsius} = $1 + 0;
    } elsif ($text =~ /^\s*194\s+Temperature_Celsius\s+\S+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)/m) {
	# ATA attribute table: the raw value is the last column.
	$out->{celsius} = $1 + 0;
    }

    if ($text =~ /^Drive Trip Temperature:\s*(\d+)/m) {
	$out->{trip_celsius} = $1 + 0;
    }

    if ($text =~ /^Accumulated power on time, hours:minutes\s+(\d+):/m) {
	$out->{power_hours} = $1 + 0;
    } elsif ($text =~ /^\s*9\s+Power_On_Hours\S*\s+\S+\s+\d+\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)/m) {
	$out->{power_hours} = $1 + 0;
    }

    return undef if !defined $out->{serial};
    return $out;
}

# Any scsi-generic node belonging to the controller addresses the same set of
# physical drives, so the first one that answers is as good as any.
sub find_device {
    my (%opt) = @_;

    my $timeout = $opt{timeout} // 10;

    for my $dev (sort glob('/dev/sg*')) {
	my $text = _run($timeout, binary(), '-i', '-d', 'cciss,0', $dev);
	my $info = _parse($text);
	return $dev if $info;
    }

    return undef;
}

# Returns drive data keyed by serial number.
#
# Keying by serial rather than by index is not optional: the cciss index order
# does not follow the bay order, so matching positionally attributes readings
# to the wrong disk.
sub collect {
    my (%opt) = @_;

    return undef if !available();

    my $timeout = $opt{timeout} // 10;
    my $expect = $opt{expect};     # drive count from the Redfish walk, if known
    my $device = $opt{device} // find_device(timeout => $timeout);

    return undef if !$device;

    my $limit = defined $expect && $expect > 0 ? $expect : MAX_INDEX;
    $limit = MAX_INDEX if $limit > MAX_INDEX;

    my %by_serial;
    for my $index (0 .. $limit - 1) {
	my $text = _run($timeout, binary(), '-a', '-d', "cciss,$index", $device);
	my $info = _parse($text);

	# An empty slot ends the scan: indexes are contiguous on a Smart Array.
	last if !$info;

	$by_serial{ $info->{serial} } = $info;
    }

    return undef if !%by_serial;

    return {
	device    => $device,
	by_serial => \%by_serial,
    };
}

# Fills the gaps in a storage section in place. Values already present from
# Redfish win: this only ever fills in what iLO left empty.
sub enrich {
    my ($storage, $smart) = @_;

    return 0 if !$storage || !$smart || !$smart->{by_serial};

    my $filled = 0;

    for my $ctrl (@{ $storage->{controllers} // [] }) {
	for my $drive (@{ $ctrl->{drives} // [] }) {
	    my $serial = $drive->{serial};
	    next if !defined $serial;

	    my $info = $smart->{by_serial}->{$serial};
	    next if !$info;

	    for my $field (qw(celsius power_hours)) {
		next if defined $drive->{$field};
		next if !defined $info->{$field};
		$drive->{$field} = $info->{$field};
		$filled++;
	    }

	    # The drive's own trip temperature is a better scale for the bar
	    # than a guessed ceiling, and iLO never provides it.
	    $drive->{trip_celsius} //= $info->{trip_celsius};
	    $drive->{smart} = 1;
	}
    }

    return $filled;
}

1;
