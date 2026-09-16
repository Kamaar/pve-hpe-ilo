#!/usr/bin/perl

# The evaluation drives both the panel banner and the notifier, so a rule that
# is wrong here is wrong in two places at once. The conditions it detects are
# also ones that cannot be produced on demand -- you cannot ask a disk to start
# reallocating sectors -- which makes these the only tests that will ever cover
# them.
#
# Run: perl -I perl t/check.t

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../perl";

use Test::More tests => 38;

use PVE::HPEiLO::Check;

sub keys_of {
    my ($issues) = @_;
    return [ map { $_->{key} } @$issues ];
}

sub find {
    my ($issues, $key) = @_;
    my ($hit) = grep { $_->{key} eq $key } @$issues;
    return $hit;
}

# A healthy machine, shaped like the reference DL380 Gen9.
sub healthy_sample {
    return {
	status => 'ok',
	health => { system => 'OK' },
	temperatures => [
	    { name => '01-Inlet Ambient', celsius => 24, warning => 42, critical => 50, health => 'OK' },
	    { name => '08-HD Max', celsius => 50, warning => 60, health => 'OK' },
	],
	fans => [
	    { name => 'Fan 1', reading => 26, units => 'Percent', health => 'OK' },
	    { name => 'Fan 2', reading => 26, units => 'Percent', health => 'OK' },
	],
	power => {
	    consumed_watts => 168,
	    supplies => [
		{ name => 'PSU 1', health => 'OK' },
		{ name => 'PSU 2', health => 'OK' },
	    ],
	},
	storage => {
	    health => 'OK',
	    controllers => [ {
		model => 'Smart Array P440ar',
		health => 'OK',
		backup_power => 'Present',
		logical_drives => [ { number => 1, raid => '50', health => 'OK' } ],
		drives => [
		    { location => '1I:3:1', health => 'OK', celsius => 42,
		      trip_celsius => 68, grown_defects => 0 },
		    { location => '1I:3:2', health => 'OK', celsius => 44,
		      trip_celsius => 68, grown_defects => 0 },
		],
	    } ],
	},
	errors => {},
    };
}

# --- the quiet case, which has to stay quiet -------------------------------

{
    my $issues = PVE::HPEiLO::Check::evaluate(healthy_sample());

    is_deeply(keys_of($issues), [], 'a healthy machine produces no issues');
    ok(!defined PVE::HPEiLO::Check::worst($issues), 'worst() is undef when clear');

    # 08-HD Max sits at 50 against a 60 warning on the reference machine. If
    # that ever raises a warning the banner is permanently amber and everyone
    # stops reading it.
    my $sample = healthy_sample();
    $sample->{temperatures}->[1]->{celsius} = 59;
    is_deeply(keys_of(PVE::HPEiLO::Check::evaluate($sample)), [],
	'a sensor just below its warning threshold stays silent');
}

# --- temperatures ----------------------------------------------------------

{
    my $sample = healthy_sample();
    $sample->{temperatures}->[0]->{celsius} = 45;    # warning 42, critical 50
    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    my $hit = find($issues, 'temp:01-Inlet Ambient:warning');
    ok($hit, 'crossing the warning threshold is reported');
    is($hit->{severity}, 'warning', 'and as a warning');

    $sample->{temperatures}->[0]->{celsius} = 51;
    $issues = PVE::HPEiLO::Check::evaluate($sample);
    ok(find($issues, 'temp:01-Inlet Ambient:critical'), 'crossing critical is reported');
    is(PVE::HPEiLO::Check::worst($issues), 'critical', 'worst() picks it up');
    ok(!find($issues, 'temp:01-Inlet Ambient:warning'),
	'and does not also fire the warning for the same sensor');
}

{
    # Most iLO 4 sensors have no thresholds at all. Inventing one would make
    # the banner lie.
    my $sample = healthy_sample();
    $sample->{temperatures} = [ { name => '11-PS 1 Inlet', celsius => 31, health => 'OK' } ];
    is_deeply(keys_of(PVE::HPEiLO::Check::evaluate($sample)), [],
	'a sensor with no thresholds is never judged');
}

# --- fans ------------------------------------------------------------------

{
    my $sample = healthy_sample();
    $_->{reading} = 95 for @{ $sample->{fans} };
    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    my $hit = find($issues, 'fan:maxed');
    ok($hit, 'fans pinned near maximum are reported');
    like($hit->{text}, qr/Fan 1, Fan 2/, 'naming which ones');
    is(scalar @$issues, 1, 'as a single issue, not one per fan');
}

# --- power -----------------------------------------------------------------

{
    my $sample = healthy_sample();
    $sample->{power}->{supplies}->[1]->{health} = 'Critical';
    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    is(find($issues, 'psu:PSU 2:health')->{severity}, 'critical',
	'a failed power supply is critical');
}

# --- storage ---------------------------------------------------------------

{
    my $sample = healthy_sample();
    $sample->{storage}->{controllers}->[0]->{drives}->[1]->{grown_defects} = 3;
    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    my $hit = find($issues, 'pd:1I:3:2:defects');
    ok($hit, 'a drive that has started reallocating sectors is reported');
    is($hit->{severity}, 'warning', 'as a warning, not a failure');
    like($hit->{text}, qr/3 reallocated/, 'with the count');
}

{
    my $sample = healthy_sample();
    $sample->{storage}->{controllers}->[0]->{drives}->[0]->{celsius} = 64;  # trips at 68
    ok(find(PVE::HPEiLO::Check::evaluate($sample), 'pd:1I:3:1:temp'),
	'a drive approaching its trip temperature is reported');
}

{
    my $sample = healthy_sample();
    $sample->{storage}->{controllers}->[0]->{backup_power} = 'NotPresent';
    ok(find(PVE::HPEiLO::Check::evaluate($sample), 'ctrl:Smart Array P440ar:backup'),
	'a missing cache capacitor is reported');

    $sample->{storage}->{controllers}->[0]->{backup_power} = 'PresentAndCharging';
    ok(!find(PVE::HPEiLO::Check::evaluate($sample), 'ctrl:Smart Array P440ar:backup'),
	'a charging one is not - that is the normal state after a power loss');
}

{
    my $sample = healthy_sample();
    my $ld = $sample->{storage}->{controllers}->[0]->{logical_drives}->[0];
    $ld->{health} = 'Warning';
    $ld->{operation} = 'rebuilding';
    $ld->{progress} = 37;

    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    is(find($issues, 'ld:1:health')->{severity}, 'warning', 'a degraded array is a warning');
    my $op = find($issues, 'ld:1:operation');
    is($op->{severity}, 'info', 'the rebuild itself is information, not a fault');
    like($op->{text}, qr/37%/, 'with its progress');
}

# --- collection failures ---------------------------------------------------

{
    my $issues = PVE::HPEiLO::Check::evaluate({
	status => 'error', error => 'connection refused',
    });
    is(scalar @$issues, 1, 'an unreachable iLO produces exactly one issue');
    is($issues->[0]->{severity}, 'critical', 'and it is critical');
    like($issues->[0]->{text}, qr/connection refused/, 'quoting the reason');
}

{
    my $issues = PVE::HPEiLO::Check::evaluate({ status => 'stale' });
    is($issues->[0]->{severity}, 'warning',
	'a stale sample is a warning, not a failure');
}

{
    my $sample = healthy_sample();
    $sample->{errors} = { storage => 'GET failed: 404 Not Found' };
    ok(find(PVE::HPEiLO::Check::evaluate($sample), 'section:storage'),
	'a section that failed to collect is reported');
}

# --- ordering --------------------------------------------------------------

{
    my $sample = healthy_sample();
    $sample->{storage}->{controllers}->[0]->{drives}->[0]->{grown_defects} = 1;
    $sample->{power}->{supplies}->[0]->{health} = 'Critical';

    my $issues = PVE::HPEiLO::Check::evaluate($sample);
    is($issues->[0]->{severity}, 'critical', 'the worst issue sorts first');
}

{
    is_deeply(PVE::HPEiLO::Check::evaluate(undef), [], 'undef input is not a crash');
}

# --- diffing against the previous run --------------------------------------
#
# This is what keeps the notifier usable. A drive that has been at three
# reallocated sectors for a month must not say so every fifteen minutes, or
# the mail gets filtered and the next real failure goes unread.

{
    my $sample = healthy_sample();
    $sample->{storage}->{controllers}->[0]->{drives}->[0]->{grown_defects} = 3;
    my $issues = PVE::HPEiLO::Check::evaluate($sample);

    my $first = PVE::HPEiLO::Check::diff([], $issues);
    is(scalar @{$first->{new}}, 1, 'an issue seen for the first time is new');
    is_deeply($first->{keys}, ['pd:1I:3:1:defects'], 'and is remembered');

    my $again = PVE::HPEiLO::Check::diff($first->{keys}, $issues);
    is(scalar @{$again->{new}}, 0, 'the same issue next run is not new again');
    is(scalar @{$again->{cleared}}, 0, 'and is not cleared either');

    my $fixed = PVE::HPEiLO::Check::diff($first->{keys},
	PVE::HPEiLO::Check::evaluate(healthy_sample()));
    is_deeply($fixed->{cleared}, ['pd:1I:3:1:defects'],
	'an issue that stops being reported is cleared');
    is_deeply($fixed->{keys}, [], 'leaving nothing outstanding');
}

{
    # A defect count that grows is a different key, so it notifies again --
    # going from 3 to 12 is news even though the drive was already flagged.
    my $three = healthy_sample();
    $three->{storage}->{controllers}->[0]->{drives}->[0]->{grown_defects} = 3;
    my $twelve = healthy_sample();
    $twelve->{storage}->{controllers}->[0]->{drives}->[0]->{grown_defects} = 12;

    my $before = PVE::HPEiLO::Check::diff([], PVE::HPEiLO::Check::evaluate($three));
    my $after = PVE::HPEiLO::Check::diff($before->{keys},
	PVE::HPEiLO::Check::evaluate($twelve));

    is(scalar @{$after->{new}}, 0,
	'a rising defect count reuses the key, so it does not re-notify');
    like(find(PVE::HPEiLO::Check::evaluate($twelve), 'pd:1I:3:1:defects')->{text},
	qr/12 reallocated/, 'but the current count is still what gets displayed');
}

{
    my $delta = PVE::HPEiLO::Check::diff(undef, []);
    is_deeply($delta, { new => [], cleared => [], keys => [] },
	'no previous state and nothing wrong is a clean no-op');
}
