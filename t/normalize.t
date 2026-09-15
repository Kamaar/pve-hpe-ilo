#!/usr/bin/perl

# Offline checks for the iLO 4 / iLO 5 schema normalization. The two firmware
# families name the same fan fields differently, which is the single most
# likely thing to break, so it is pinned here against recorded payloads.
#
# Run: perl -I perl t/normalize.t

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../perl";

use JSON;
use Test::More tests => 50;

use PVE::HPEiLO::Redfish;

sub fixture {
    my ($name) = @_;
    my $file = "$FindBin::Bin/fixtures/$name.json";
    open(my $fh, '<', $file) or die "cannot open $file: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return decode_json($raw);
}

# A client whose HTTP layer is replaced by the recorded payloads.
sub mock_client {
    my (%routes) = @_;

    my $client = PVE::HPEiLO::Redfish->new(
	host => '203.0.113.10', username => 'u', password => 'p',
    );
    $client->{base} = '/redfish/v1';
    $client->{root} = {
	RedfishVersion => '1.0.0',
	Oem => { Hp => { Manager => [ {
	    ManagerType => 'iLO 4',
	    ManagerFirmwareVersion => '2.82',
	} ] } },
    };
    $client->{_routes} = \%routes;

    no warnings 'redefine';
    # Per-object override is not possible on a plain blessed hash, so the
    # class method consults the route table planted above.
    *PVE::HPEiLO::Redfish::get = sub {
	my ($self, $path) = @_;
	my $data = $self->{_routes}->{$path};
	die "unexpected request to $path\n" if !$data;
	return $data;
    };

    return $client;
}

# --- iLO 4 (Gen9): FanName / CurrentReading / Units -------------------------

{
    my $client = mock_client(
	'/redfish/v1/Chassis/1/Thermal/' => fixture('ilo4-thermal'),
    );

    my $res = $client->read_thermal();

    is(scalar @{$res->{fans}}, 2, 'iLO4: absent fan bay dropped');
    is($res->{fans}->[0]->{name}, 'Fan 1', 'iLO4: FanName mapped to name');
    is($res->{fans}->[0]->{reading}, 23, 'iLO4: CurrentReading mapped');
    is($res->{fans}->[0]->{units}, 'Percent', 'iLO4: Units mapped');

    my @temps = @{$res->{temperatures}};
    is(scalar @temps, 3, 'iLO4: absent and zero-reading sensors dropped');
    is($temps[0]->{name}, '01-Inlet Ambient', 'iLO4: intake sensor kept');
    is($temps[0]->{celsius}, 21, 'iLO4: ReadingCelsius mapped');
    is($temps[0]->{context}, 'Intake', 'iLO4: PhysicalContext kept');
    is($temps[0]->{critical}, 46,
	'iLO4: null UpperThresholdFatal falls back to UpperThresholdCritical');
    is($temps[1]->{name}, '02-CPU 1', 'iLO4: populated CPU sensor kept');

    my ($chipset) = grep { $_->{name} =~ /Chipset/ } @temps;
    ok(!defined $chipset, 'iLO4: enabled-but-zero non-intake sensor dropped');

    # Real iLO 4 firmware sends 0 for thresholds that do not exist, so a plain
    # // fallback would claim the CPU goes critical at 0 C.
    my ($cpu) = grep { $_->{name} =~ /CPU 1/ } @temps;
    is($cpu->{critical}, 70,
	'iLO4: zero UpperThresholdFatal ignored in favour of the real threshold');

    my ($psu) = grep { $_->{name} =~ /PS 1 Inlet/ } @temps;
    ok(defined $psu, 'iLO4: sensor with no thresholds at all is still reported');
    ok(!defined $psu->{warning}, 'iLO4: all-zero warning threshold becomes undef');
    ok(!defined $psu->{critical}, 'iLO4: all-zero critical threshold becomes undef');
}

# --- iLO 5 (Gen10): Name / Reading / ReadingUnits --------------------------

{
    my $client = mock_client(
	'/redfish/v1/Chassis/1/Thermal/' => fixture('ilo5-thermal'),
    );

    my $res = $client->read_thermal();

    is(scalar @{$res->{fans}}, 2, 'iLO5: both fans kept');
    is($res->{fans}->[0]->{name}, 'Fan 1', 'iLO5: Name mapped to name');
    is($res->{fans}->[0]->{reading}, 18, 'iLO5: Reading mapped');
    is($res->{fans}->[0]->{units}, 'Percent', 'iLO5: ReadingUnits mapped');

    my $inlet = $res->{temperatures}->[0];
    is($inlet->{warning}, 42,
	'iLO5: UpperThresholdNonCritical preferred as warning level');
}

# --- power -----------------------------------------------------------------

{
    my $client = mock_client(
	'/redfish/v1/Chassis/1/Power/' => fixture('ilo4-power'),
    );

    my $p = $client->read_power();

    is($p->{consumed_watts}, 212, 'power: PowerControl[0] consumption read');
    is($p->{average_watts}, 208, 'power: PowerMetrics average read');
    is(scalar @{$p->{supplies}}, 2, 'power: absent PSU bay dropped');
    is($p->{supplies}->[0]->{input_voltage}, 231, 'power: PSU input voltage read');

    # Both supplies report the same generic Name, so the bay number is the
    # only thing that distinguishes them in the grid.
    is($p->{supplies}->[0]->{name}, 'PSU 1', 'power: PSU named by bay number');
    is($p->{supplies}->[1]->{name}, 'PSU 2', 'power: second PSU distinguishable');
}

# --- health rollup ---------------------------------------------------------

{
    my $client = mock_client(
	'/redfish/v1/Systems/1/' => fixture('ilo4-system'),
    );

    my $res = $client->read_health();

    is($res->{model}, 'ProLiant DL380 Gen9', 'system: model read');
    is($res->{health}->{powersupplies}, 'OK',
	'system: Oem.Hp aggregate health flattened');

    # Not every entry in that block is an object; the redundancy fields are
    # bare strings and used to be dropped on the floor.
    is($res->{health}->{fanredundancy}, 'Redundant',
	'system: string-valued redundancy entry kept');
    is($res->{health}->{powersupplyredundancy}, 'Redundant',
	'system: PSU redundancy kept');
}

# --- Smart Array (SmartStorage tree walk) ----------------------------------

{
    # The fixture is keyed by URI, which is exactly the route table shape.
    my %routes = %{ fixture('ilo4-smartstorage') };
    delete $routes{_comment};

    my $client = mock_client(%routes);
    my $st = $client->read_storage();

    is($st->{health}, 'Warning',
	'storage: HealthRollup preferred over Health for the rollup');
    is(scalar @{$st->{controllers}}, 1, 'storage: one controller found');

    my $c = $st->{controllers}->[0];
    is($c->{model}, 'Smart Array P440ar', 'controller: model read');
    is($c->{firmware}, '6.88',
	'controller: FirmwareVersion.Current.VersionString unwrapped');
    is($c->{cache_mib}, 2048, 'controller: cache size read');
    is($c->{backup_power}, 'PresentAndCharged',
	'controller: cache backup power status read');
    is($c->{mode}, 'RAID', 'controller: operating mode read');
    is($c->{health}, 'Warning', 'controller: health read');

    is(scalar @{$c->{logical_drives}}, 2, 'storage: both logical drives found');

    my ($ld1, $ld2) = @{$c->{logical_drives}};
    is($ld1->{raid}, '1', 'ld: raid level read');
    is($ld1->{device}, '/dev/sda', 'ld: DriveAccessName mapped to device');
    ok(!defined $ld1->{operation}, 'ld: idle drive reports no operation');

    is($ld2->{operation}, 'rebuilding',
	'ld: RebuildCompletionPercentage recognized as a rebuild');
    is($ld2->{progress}, 37, 'ld: rebuild progress read');

    is(scalar @{$c->{drives}}, 2, 'storage: both physical drives found');

    my ($pd1, $pd2) = @{$c->{drives}};
    is($pd1->{location}, '1I:1:1', 'pd: bay location read');
    is($pd1->{celsius}, 34, 'pd: temperature read');
    is($pd2->{health}, 'Critical', 'pd: failing drive health read');

    ok(!defined $pd2->{celsius},
	'pd: zero temperature treated as unavailable, not as 0 C');
    ok(!defined $pd2->{power_hours},
	'pd: zero power-on hours treated as unavailable');
}
