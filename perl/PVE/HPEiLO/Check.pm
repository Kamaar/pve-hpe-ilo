package PVE::HPEiLO::Check;

# Turns a telemetry sample into a list of things that are wrong.
#
# One evaluation, two consumers: the banner at the top of the panel and the
# notifier that runs on a timer. Keeping them on the same function is the whole
# point -- two separate sets of rules would drift, and the day they disagree is
# the day the panel says everything is fine while the mail says otherwise.
#
# Pure: no I/O, no clock, no config. That is what makes it testable without a
# server, which matters more here than anywhere else in the package, because
# the conditions being detected are ones you cannot produce on demand.

use strict;
use warnings;

# A fan pinned near maximum is not itself a fault, but on HPE hardware it is
# how thermal trouble announces itself before anything reports unhealthy.
use constant FAN_ALARM_PERCENT => 90;

# How close a drive may get to its own trip temperature before it is worth
# saying so.
use constant DRIVE_TRIP_MARGIN => 5;

sub _issue {
    my ($severity, $key, $text) = @_;
    return { severity => $severity, key => $key, text => $text };
}

# iLO health enums. Anything not recognized is reported rather than assumed
# good: an unknown state on a RAID controller deserves a look.
sub _health_severity {
    my ($health) = @_;

    return undef if !defined $health;
    return undef if $health eq 'OK';
    return 'critical' if $health eq 'Critical';
    return 'warning';
}

sub _check_temperatures {
    my ($sample, $out) = @_;

    for my $t (@{ $sample->{temperatures} // [] }) {
	my $name = $t->{name} // 'sensor';
	my $c = $t->{celsius};

	if (my $sev = _health_severity($t->{health})) {
	    push @$out, _issue($sev, "temp:$name:health",
		"Sensor $name reports $t->{health}");
	    next;
	}

	next if !defined $c;

	# Thresholds are absent on plenty of iLO 4 sensors; skip rather than
	# invent a ceiling.
	if (defined $t->{critical} && $c >= $t->{critical}) {
	    push @$out, _issue('critical', "temp:$name:critical",
		"$name at ${c} \xB0C, critical threshold $t->{critical} \xB0C");
	} elsif (defined $t->{warning} && $c >= $t->{warning}) {
	    push @$out, _issue('warning', "temp:$name:warning",
		"$name at ${c} \xB0C, warning threshold $t->{warning} \xB0C");
	}
    }
}

sub _check_fans {
    my ($sample, $out) = @_;

    my @maxed;
    for my $f (@{ $sample->{fans} // [] }) {
	my $name = $f->{name} // 'fan';

	if (my $sev = _health_severity($f->{health})) {
	    push @$out, _issue($sev, "fan:$name:health",
		"Fan $name reports $f->{health}");
	}

	push @maxed, $name
	    if ($f->{units} // '') eq 'Percent'
	    && defined $f->{reading}
	    && $f->{reading} >= FAN_ALARM_PERCENT;
    }

    # One key for all of them: when fans ramp they ramp together, and eight
    # separate warnings would bury everything else.
    push @$out, _issue('warning', 'fan:maxed',
	sprintf('Fans running at %d%% or above (%s)', FAN_ALARM_PERCENT,
	    join(', ', @maxed)))
	if @maxed;
}

sub _check_power {
    my ($sample, $out) = @_;

    my $power = $sample->{power} or return;

    for my $ps (@{ $power->{supplies} // [] }) {
	my $name = $ps->{name} // 'PSU';
	if (my $sev = _health_severity($ps->{health})) {
	    push @$out, _issue($sev, "psu:$name:health",
		"$name reports $ps->{health}");
	}
    }
}

sub _check_storage {
    my ($sample, $out) = @_;

    my $storage = $sample->{storage} or return;

    for my $c (@{ $storage->{controllers} // [] }) {
	my $model = $c->{model} // 'Smart Array';

	if (my $sev = _health_severity($c->{health})) {
	    push @$out, _issue($sev, "ctrl:$model:health",
		"$model reports $c->{health}");
	}

	# A missing cache capacitor silently drops the controller to
	# write-through. Nothing else reports it and everything just gets slow.
	push @$out, _issue('warning', "ctrl:$model:backup",
	    "$model cache backup power is $c->{backup_power}")
	    if defined $c->{backup_power} && $c->{backup_power} eq 'NotPresent';

	for my $ld (@{ $c->{logical_drives} // [] }) {
	    my $num = $ld->{number} // '?';

	    if (my $sev = _health_severity($ld->{health})) {
		push @$out, _issue($sev, "ld:$num:health",
		    "Logical drive $num (RAID $ld->{raid}) reports $ld->{health}");
	    }

	    push @$out, _issue('info', "ld:$num:operation",
		"Logical drive $num $ld->{operation} at $ld->{progress}%")
		if defined $ld->{operation};
	}

	for my $pd (@{ $c->{drives} // [] }) {
	    my $bay = $pd->{location} // '?';

	    if (my $sev = _health_severity($pd->{health})) {
		push @$out, _issue($sev, "pd:$bay:health",
		    "Drive in bay $bay reports $pd->{health}");
	    }

	    # The earliest warning a spinning disk gives. Zero is the normal
	    # state and stays silent; any growth at all is worth a line.
	    push @$out, _issue('warning', "pd:$bay:defects",
		"Drive in bay $bay has $pd->{grown_defects} reallocated"
		. ' sector(s)')
		if ($pd->{grown_defects} // 0) > 0;

	    if (defined $pd->{celsius} && defined $pd->{trip_celsius}
		&& $pd->{celsius} >= $pd->{trip_celsius} - DRIVE_TRIP_MARGIN) {
		push @$out, _issue('critical', "pd:$bay:temp",
		    "Drive in bay $bay at $pd->{celsius} \xB0C, trips at"
		    . " $pd->{trip_celsius} \xB0C");
	    }
	}
    }
}

sub _check_system {
    my ($sample, $out) = @_;

    my $health = $sample->{health} or return;

    # Free-text entries such as FanRedundancy live here alongside the health
    # enums, so only the values that are unambiguously a health state are
    # judged; the rest are shown in the panel and left alone.
    my %known_good = map { $_ => 1 } qw(OK Redundant Enabled Ready Unavailable);

    for my $key (sort keys %$health) {
	my $value = $health->{$key};
	next if !defined $value || $known_good{$value};
	my $sev = $value eq 'Critical' ? 'critical' : 'warning';
	push @$out, _issue($sev, "sys:$key", "System $key reports $value");
    }
}

# Returns an arrayref of { severity, key, text }, most severe first.
#
# `key` is a stable identity for one condition and is what the notifier diffs
# between runs; `text` is for humans and may be reworded freely.
sub evaluate {
    my ($sample) = @_;

    return [] if !$sample || ref($sample) ne 'HASH';

    my @out;

    # A sample that never arrived says nothing about the hardware, so report
    # the collection failure itself and stop: everything below would be stale.
    my $status = $sample->{status} // 'error';
    if ($status ne 'ok') {
	my $text = $sample->{error} // "telemetry is $status";
	return [ _issue($status eq 'stale' ? 'warning' : 'critical',
	    "sample:$status", "Cannot read iLO: $text") ];
    }

    _check_system($sample, \@out);
    _check_temperatures($sample, \@out);
    _check_fans($sample, \@out);
    _check_power($sample, \@out);
    _check_storage($sample, \@out);

    for my $section (sort keys %{ $sample->{errors} // {} }) {
	push @out, _issue('warning', "section:$section",
	    "Could not read $section from iLO: $sample->{errors}->{$section}");
    }

    my %rank = (critical => 0, warning => 1, info => 2);
    @out = sort {
	($rank{$a->{severity}} // 9) <=> ($rank{$b->{severity}} // 9)
	    || $a->{key} cmp $b->{key}
    } @out;

    return \@out;
}

# What changed since the last run, given the keys reported then.
#
# Notifying on state rather than on every run is the difference between a
# mailbox someone reads and one they filter away: a drive that has been at
# three reallocated sectors for a month must not say so every fifteen minutes.
sub diff {
    my ($previous, $issues) = @_;

    my %prev = map { $_ => 1 } @{ $previous // [] };
    my %seen;
    my @new;

    for my $issue (@{ $issues // [] }) {
	$seen{ $issue->{key} } = 1;
	push @new, $issue if !$prev{ $issue->{key} };
    }

    my @cleared = grep { !$seen{$_} } sort keys %prev;

    return {
	new     => \@new,
	cleared => \@cleared,
	keys    => [ sort keys %seen ],
    };
}

# Highest severity present, or undef when the list is empty.
sub worst {
    my ($issues) = @_;

    my %rank = (critical => 0, warning => 1, info => 2);
    my $worst;
    for my $i (@{ $issues // [] }) {
	$worst = $i->{severity}
	    if !defined $worst
	    || ($rank{$i->{severity}} // 9) < ($rank{$worst} // 9);
    }

    return $worst;
}

1;
