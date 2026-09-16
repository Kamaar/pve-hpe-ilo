package PVE::HPEiLO::Config;

use strict;
use warnings;

use JSON;

# Config lives outside /etc/pve on purpose: /etc/pve is group-readable by
# www-data (pveproxy), and this file holds the iLO password.
use constant CONFIG_FILE => '/etc/pve-hpe-ilo/config.json';
use constant CACHE_FILE  => '/run/pve-hpe-ilo/telemetry.json';

# What the notifier reported last time. Unlike the cache this must survive a
# reboot, or every boot would re-announce every standing issue.
use constant STATE_FILE  => '/var/lib/pve-hpe-ilo/check-state.json';

my $defaults = {
    port     => 443,
    insecure => 1,      # iLO ships a self-signed cert by default
    interval => 30,     # seconds between polls; iLO4 Redfish is slow
    timeout  => 15,
    chassis  => '1',
    system   => '1',
    storage  => 1,      # walk the Smart Array tree at all
    # Walking SmartStorage costs one request per physical drive, so it runs on
    # its own much slower cycle. RAID state does not change by the second, and
    # the one case where it does -- a rebuild -- takes hours.
    storage_interval => 300,
    # Fill drive temperature and run time from smartctl when iLO leaves them
    # empty, which is what happens with third-party disks in HP carriers.
    # Costs one local command per drive, on the storage cycle.
    smart => 1,
    smart_timeout => 10,
};

sub load {
    my ($file) = @_;
    $file //= CONFIG_FILE;

    open(my $fh, '<', $file) or die "cannot open $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close($fh);

    my $cfg = eval { decode_json($raw) };
    die "invalid JSON in $file: $@" if $@;

    for my $k (keys %$defaults) {
	$cfg->{$k} = $defaults->{$k} if !defined $cfg->{$k};
    }

    for my $k (qw(host username password)) {
	die "missing required option '$k' in $file\n" if !defined $cfg->{$k};
    }

    $cfg->{interval} = 10 if $cfg->{interval} < 10;   # do not hammer iLO4

    # Sampling storage more often than the base interval is meaningless, and
    # a low value here is the one setting that can genuinely overload iLO 4.
    $cfg->{storage_interval} = $cfg->{interval}
	if $cfg->{storage_interval} < $cfg->{interval};

    return $cfg;
}

1;
