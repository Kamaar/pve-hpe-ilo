package PVE::HPEiLO::Redfish;

# Minimal Redfish client for HPE iLO, normalizing the schema differences
# between iLO 4 (Gen8/Gen9) and iLO 5/6 (Gen10+).
#
# Deliberately built on core Perl only (HTTP::Tiny, MIME::Base64) plus JSON,
# all of which are present on a stock Proxmox VE node -- no extra packages.

use strict;
use warnings;

use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);
use JSON;

sub new {
    my ($class, %param) = @_;

    my $self = bless {
	host     => $param{host},
	port     => $param{port} // 443,
	username => $param{username},
	password => $param{password},
	insecure => $param{insecure} // 1,
	timeout  => $param{timeout} // 15,
	chassis  => $param{chassis} // '1',
	system   => $param{system} // '1',
	base     => undef,   # discovered: /redfish/v1 or /rest/v1
	token    => undef,   # X-Auth-Token when session auth is in use
    }, $class;

    my %opts = (
	timeout         => $self->{timeout},
	agent           => 'pve-hpe-ilo/1.0 ',
	keep_alive      => 1,
	default_headers => { 'Accept' => 'application/json' },
    );
    # iLO ships a self-signed certificate; verification is opt-in.
    $opts{verify_SSL} = $self->{insecure} ? 0 : 1;
    $opts{SSL_options} = { SSL_verify_mode => 0 } if $self->{insecure};

    $self->{ua} = HTTP::Tiny->new(%opts);

    return $self;
}

sub _url {
    my ($self, $path) = @_;
    my $host = $self->{host};
    $host = "[$host]" if $host =~ /:/ && $host !~ /^\[/;   # bare IPv6
    return "https://${host}:$self->{port}$path";
}

sub _auth_headers {
    my ($self) = @_;

    return { 'X-Auth-Token' => $self->{token} } if defined $self->{token};

    my $basic = encode_base64("$self->{username}:$self->{password}", '');
    return { 'Authorization' => "Basic $basic" };
}

# GET a Redfish resource. Returns the decoded body, or dies with a message
# that is safe to surface in the GUI (it never contains credentials).
sub get {
    my ($self, $path) = @_;

    my $res = $self->{ua}->get($self->_url($path), {
	headers => $self->_auth_headers(),
    });

    if (!$res->{success}) {
	my $status = $res->{status} // 0;
	# 599 is HTTP::Tiny's internal code for transport-level failures.
	my $reason = $status == 599 ? ($res->{content} // 'connection failed')
	                            : ($res->{reason} // 'unknown error');
	chomp $reason;
	die "GET $path failed: $status $reason\n";
    }

    my $data = eval { decode_json($res->{content}) };
    die "GET $path returned unparsable JSON\n" if $@;

    return $data;
}

# iLO 4 firmware older than 2.00 predates Redfish and only serves the legacy
# HP REST API at /rest/v1. The resources we read have the same shape there.
sub discover_base {
    my ($self) = @_;

    return $self->{base} if defined $self->{base};

    my @err;
    for my $base ('/redfish/v1', '/rest/v1') {
	my $root = eval { $self->get("$base/") };
	if ($root) {
	    $self->{base} = $base;
	    $self->{root} = $root;
	    return $base;
	}
	my $msg = $@;
	chomp $msg;
	push @err, "$base: $msg";
    }

    die "no Redfish or legacy REST endpoint on $self->{host} ("
	. join('; ', @err) . ")\n";
}

# Oem blocks are keyed 'Hp' on iLO 4 and 'Hpe' on iLO 5+.
sub _oem {
    my ($node) = @_;
    return undef if !$node || ref($node) ne 'HASH';
    my $oem = $node->{Oem} or return undef;
    return $oem->{Hpe} // $oem->{Hp};
}

# iLO reports "no such threshold" as 0 rather than null on most sensors, so a
# plain // fallback picks the zero and claims the CPU is critical at 0 C.
sub _threshold {
    for my $v (@_) {
	return $v if defined $v && $v > 0;
    }
    return undef;
}

# Same idea for readings that are simply not wired up: 0 means "no value", not
# a drive sitting at freezing point or a brand new disk.
sub _nonzero {
    my ($v) = @_;
    return undef if !defined $v || $v == 0;
    return $v;
}

sub _state_ok {
    my ($entry) = @_;
    my $state = $entry->{Status}->{State} // 'Enabled';
    # Unpopulated fan bays and unwired sensors report Absent; iLO still lists
    # them, with a reading of 0, which would otherwise pollute the display.
    return 0 if $state eq 'Absent' || $state eq 'Disabled';
    return 1;
}

sub read_thermal {
    my ($self) = @_;

    my $base = $self->discover_base();
    my $data = $self->get("$base/Chassis/$self->{chassis}/Thermal/");

    my @temps;
    for my $t (@{ $data->{Temperatures} // [] }) {
	next if !_state_ok($t);
	my $reading = $t->{ReadingCelsius};
	next if !defined $reading;
	# A wired-but-idle sensor reports 0; keep 0 only for intake sensors,
	# where it can legitimately be near freezing.
	next if $reading == 0 && ($t->{PhysicalContext} // '') ne 'Intake';

	push @temps, {
	    name     => $t->{Name} // 'unknown',
	    celsius  => $reading + 0,
	    context  => $t->{PhysicalContext},
	    warning  => _threshold($t->{UpperThresholdNonCritical},
		$t->{UpperThresholdCritical}),
	    critical => _threshold($t->{UpperThresholdFatal},
		$t->{UpperThresholdCritical}),
	    health   => $t->{Status}->{Health} // 'OK',
	};
    }

    my @fans;
    for my $f (@{ $data->{Fans} // [] }) {
	next if !_state_ok($f);

	# iLO 4:  FanName / CurrentReading / Units
	# iLO 5+: Name / Reading / ReadingUnits
	my $name    = $f->{FanName} // $f->{Name} // 'unknown';
	my $reading = $f->{CurrentReading} // $f->{Reading};
	next if !defined $reading;

	push @fans, {
	    name    => $name,
	    reading => $reading + 0,
	    units   => $f->{Units} // $f->{ReadingUnits} // 'Percent',
	    health  => $f->{Status}->{Health} // 'OK',
	};
    }

    return { temperatures => \@temps, fans => \@fans };
}

sub read_power {
    my ($self) = @_;

    my $base = $self->discover_base();
    my $data = $self->get("$base/Chassis/$self->{chassis}/Power/");

    my $ctrl = ($data->{PowerControl} // [])->[0] // {};
    my $metrics = $ctrl->{PowerMetrics} // {};

    my @supplies;
    my $index = 0;
    for my $ps (@{ $data->{PowerSupplies} // [] }) {
	$index++;
	next if !_state_ok($ps);

	# Every PSU reports the same generic Name ("HpServerPowerSupply"), so
	# the bay number is the only thing that tells them apart.
	my $oem = _oem($ps);
	my $bay = $oem ? $oem->{BayNumber} : undef;
	$bay //= $index;

	push @supplies, {
	    name          => "PSU $bay",
	    reported_name => $ps->{Name},
	    model         => $ps->{Model},
	    serial        => $ps->{SerialNumber},
	    output_watts  => $ps->{LastPowerOutputWatts},
	    capacity      => $ps->{PowerCapacityWatts},
	    input_voltage => $ps->{LineInputVoltage},
	    health        => $ps->{Status}->{Health} // 'OK',
	};
    }

    return {
	consumed_watts => $ctrl->{PowerConsumedWatts},
	capacity_watts => $ctrl->{PowerCapacityWatts},
	average_watts  => $metrics->{AverageConsumedWatts},
	min_watts      => $metrics->{MinConsumedWatts},
	max_watts      => $metrics->{MaxConsumedWatts},
	interval_min   => $metrics->{IntervalInMin},
	supplies       => \@supplies,
    };
}

# Collection members are listed as Members[]/@odata.id under Redfish and as
# links.Member[].href under the legacy HP REST API.
sub _members {
    my ($data) = @_;

    my @out;
    if (ref($data->{Members}) eq 'ARRAY') {
	@out = map { $_->{'@odata.id'} } @{ $data->{Members} };
    } elsif ($data->{links} && ref($data->{links}->{Member}) eq 'ARRAY') {
	@out = map { $_->{href} } @{ $data->{links}->{Member} };
    }

    return grep { defined && length } @out;
}

# Sub-collection URI, preferring the link the controller advertises over a
# path built by hand.
sub _sub_uri {
    my ($resource, $uri, $name) = @_;

    my $link = $resource->{Links}->{$name} // $resource->{links}->{$name};
    if (ref($link) eq 'HASH') {
	my $href = $link->{'@odata.id'} // $link->{href};
	return $href if defined $href && length $href;
    }

    $uri =~ s{/$}{};
    return "$uri/$name/";
}

sub _fw_version {
    my ($resource) = @_;
    my $fw = $resource->{FirmwareVersion};
    return undef if ref($fw) ne 'HASH';
    return $fw->{Current}->{VersionString};
}

# Guard against a pathological enclosure: every drive is one HTTP round trip,
# and iLO 4 needs one to three seconds for each.
use constant MAX_DRIVES => 64;

# HPE Smart Array state, via the OEM SmartStorage tree. Gen9 reports this
# out-of-band through the controller's sideband channel; some fields (drive
# temperatures in particular) only populate when AMS runs on the host.
#
# This is by far the most expensive thing the poller does, which is why it
# runs on its own slower schedule -- see storage_interval in the config.
sub read_storage {
    my ($self) = @_;

    my $base = $self->discover_base();
    my $root = $self->get("$base/Systems/$self->{system}/SmartStorage/");

    my $out = {
	health      => $root->{Status}->{HealthRollup} // $root->{Status}->{HealthRollUp}
	    // $root->{Status}->{Health} // 'Unknown',
	controllers => [],
    };

    my $ctrl_uri = _sub_uri($root, "$base/Systems/$self->{system}/SmartStorage/",
	'ArrayControllers');
    my $ctrls = $self->get($ctrl_uri);

    for my $uri (_members($ctrls)) {
	my $c = $self->get($uri);

	my $ctrl = {
	    model            => $c->{Model},
	    serial           => $c->{SerialNumber},
	    location         => $c->{Location},
	    firmware         => _fw_version($c),
	    mode             => $c->{CurrentOperatingMode},
	    cache_mib        => $c->{CacheMemorySizeMiB},
	    # The cache backup capacitor. A failed one silently disables
	    # write-back caching, which shows up only as "everything got slow".
	    backup_power     => $c->{BackupPowerSourceStatus},
	    rebuild_priority => $c->{RebuildPriority},
	    encryption       => $c->{EncryptionEnabled} ? 1 : 0,
	    unassigned       => $c->{UnassignedPhysicalDriveCount},
	    spares           => $c->{SparePhysicalDriveCount},
	    health           => $c->{Status}->{Health} // 'Unknown',
	    logical_drives   => [],
	    drives           => [],
	};

	my $ld_coll = eval { $self->get(_sub_uri($c, $uri, 'LogicalDrives')) };
	for my $ld_uri (_members($ld_coll // {})) {
	    my $ld = $self->get($ld_uri);

	    # Exactly one of these is non-null while an operation is running.
	    my $progress = $ld->{RebuildCompletionPercentage}
		// $ld->{ParityInitializationCompletionPercentage}
		// $ld->{TransformationCompletionPercentage};
	    my $operation;
	    if (defined $ld->{RebuildCompletionPercentage}) {
		$operation = 'rebuilding';
	    } elsif (defined $ld->{ParityInitializationCompletionPercentage}) {
		$operation = 'parity init';
	    } elsif (defined $ld->{TransformationCompletionPercentage}) {
		$operation = 'transforming';
	    }

	    push @{ $ctrl->{logical_drives} }, {
		name       => $ld->{LogicalDriveName},
		number     => $ld->{LogicalDriveNumber},
		raid       => $ld->{Raid},
		capacity_mib => $ld->{CapacityMiB},
		device     => $ld->{DriveAccessName},
		type       => $ld->{LogicalDriveType},
		strip_bytes => $ld->{StripSizeBytes},
		operation  => $operation,
		progress   => $progress,
		health     => $ld->{Status}->{Health} // 'Unknown',
	    };
	}

	my $pd_coll = eval { $self->get(_sub_uri($c, $uri, 'DiskDrives')) };
	my @pd_uris = _members($pd_coll // {});
	my $truncated = 0;
	if (@pd_uris > MAX_DRIVES) {
	    $truncated = scalar(@pd_uris) - MAX_DRIVES;
	    @pd_uris = @pd_uris[0 .. MAX_DRIVES - 1];
	}

	for my $pd_uri (@pd_uris) {
	    my $pd = $self->get($pd_uri);

	    push @{ $ctrl->{drives} }, {
		location    => $pd->{Location},
		model       => $pd->{Model},
		serial      => $pd->{SerialNumber},
		firmware    => _fw_version($pd),
		media       => $pd->{MediaType},
		interface   => $pd->{InterfaceType},
		capacity_gb => $pd->{CapacityGB},
		# A P440ar does not always pass drive temperature and run time
		# out of band; it sends 0 rather than omitting the field.
		celsius     => _nonzero($pd->{CurrentTemperatureCelsius}),
		max_celsius => _nonzero($pd->{MaximumTemperatureCelsius}),
		power_hours => _nonzero($pd->{PowerOnHours}),
		rpm         => $pd->{RotationalSpeedRpm},
		# Only meaningful on SSDs; 100 means the endurance is used up.
		ssd_wear    => $pd->{SSDEnduranceUtilizationPercentage},
		led         => $pd->{IndicatorLED},
		health      => $pd->{Status}->{Health} // 'Unknown',
	    };
	}

	$ctrl->{truncated} = $truncated if $truncated;

	push @{ $out->{controllers} }, $ctrl;
    }

    return $out;
}

# iLO exposes a per-subsystem health rollup that is far more useful than the
# single Status.Health on the computer system resource.
sub read_health {
    my ($self) = @_;

    my $base = $self->discover_base();
    my $sys = $self->get("$base/Systems/$self->{system}/");

    my $health = { system => $sys->{Status}->{Health} // 'Unknown' };

    my $oem = _oem($sys);
    my $agg = $oem ? $oem->{AggregateHealthStatus} : undef;
    if ($agg && ref($agg) eq 'HASH') {
	for my $key (sort keys %$agg) {
	    my $val = $agg->{$key};

	    if (ref($val) eq 'HASH') {
		my $status = $val->{Status}->{Health} // $val->{Status}->{State};
		$health->{lc($key)} = $status if defined $status;
	    } elsif (!ref($val) && defined $val && length $val) {
		# Not everything in this block is an object: the redundancy
		# fields are plain strings ("Redundant"), and losing them
		# would drop the most useful summary iLO offers.
		$health->{lc($key)} = $val;
	    }
	}
    }

    return {
	health   => $health,
	model    => $sys->{Model},
	serial   => $sys->{SerialNumber},
	bios     => $sys->{BiosVersion},
	power    => $sys->{PowerState},
	hostname => $sys->{HostName},
    };
}

sub read_ilo_info {
    my ($self) = @_;

    my $base = $self->discover_base();
    my $root = $self->{root} // $self->get("$base/");
    my $oem = _oem($root) // {};
    my $mgr = ref($oem->{Manager}) eq 'ARRAY' ? $oem->{Manager}->[0] : {};

    return {
	redfish_version => $root->{RedfishVersion},
	firmware        => $mgr->{ManagerFirmwareVersion},
	type            => $mgr->{ManagerType},
	api             => $base eq '/rest/v1' ? 'legacy-rest' : 'redfish',
    };
}

# One full sample. Sections fail independently so that a single unsupported
# endpoint does not blank the whole panel.
#
# Pass storage => 1 to walk the SmartStorage tree as well. That costs one HTTP
# round trip per drive, so the poller asks for it far less often than the rest.
sub collect {
    my ($self, %opt) = @_;

    my $out = {
	timestamp => time(),
	host      => $self->{host},
	errors    => {},
    };

    my $sections = {
	ilo     => sub { $self->read_ilo_info() },
	thermal => sub { $self->read_thermal() },
	power   => sub { $self->read_power() },
	system  => sub { $self->read_health() },
	storage => sub { $self->read_storage() },
    };

    my @wanted = qw(ilo thermal power system);
    push @wanted, 'storage' if $opt{storage};

    for my $name (@wanted) {
	my $res = eval { $sections->{$name}->() };
	if ($@) {
	    my $msg = $@;
	    chomp $msg;
	    $out->{errors}->{$name} = $msg;
	    next;
	}
	if ($name eq 'thermal') {
	    $out->{temperatures} = $res->{temperatures};
	    $out->{fans} = $res->{fans};
	} elsif ($name eq 'system') {
	    $out->{health} = $res->{health};
	    $out->{server} = {
		model    => $res->{model},
		serial   => $res->{serial},
		bios     => $res->{bios},
		power    => $res->{power},
		hostname => $res->{hostname},
	    };
	} else {
	    $out->{$name} = $res;
	}
    }

    $out->{temperatures} //= [];
    $out->{fans} //= [];

    # A sample with no readings at all counts as a failure for the panel.
    $out->{status} = (@{$out->{temperatures}} || @{$out->{fans}} || $out->{power})
	? 'ok' : 'error';

    return $out;
}

1;
