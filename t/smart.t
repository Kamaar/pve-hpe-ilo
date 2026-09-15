#!/usr/bin/perl

# Offline checks for the smartctl enrichment. The parser runs against recorded
# smartctl output, and the merge is verified to join by serial number -- the
# cciss index order does not follow the bay order, so a positional join would
# quietly attribute readings to the wrong disk.
#
# Run: perl -I perl t/smart.t

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../perl";

use Test::More tests => 19;

use PVE::HPEiLO::Smart;

sub fixture {
    my ($name) = @_;
    open(my $fh, '<', "$FindBin::Bin/fixtures/$name") or die "cannot open $name: $!";
    local $/;
    my $raw = <$fh>;
    close($fh);
    return $raw;
}

# --- SAS parsing -----------------------------------------------------------

{
    my $info = PVE::HPEiLO::Smart::_parse(fixture('smartctl-sas.txt'));

    ok(defined $info, 'sas: output recognized');
    is($info->{serial}, 'S3LEXAMPLE0000000001', 'sas: serial number read');
    is($info->{celsius}, 46, 'sas: current temperature read');
    is($info->{trip_celsius}, 68, 'sas: trip temperature read');
    is($info->{power_hours}, 72939,
	'sas: power on hours taken from the hours:minutes field');
    is($info->{grown_defects}, 0,
	'sas: grown defect list read, and zero is a value not an absence');
}

# --- rejection -------------------------------------------------------------

{
    ok(!defined PVE::HPEiLO::Smart::_parse(undef), 'undef input rejected');
    ok(!defined PVE::HPEiLO::Smart::_parse(''), 'empty input rejected');
    ok(!defined PVE::HPEiLO::Smart::_parse("smartctl: no such device\n"),
	'output without a serial rejected, so the scan stops at an empty slot');
}

# --- ATA fallback ----------------------------------------------------------

{
    my $ata = <<'EOF';
Device Model:     WDC WD40EFRX-68N32N0
Serial Number:    WD-WCC7K0123456
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   200   200   140    Pre-fail  Always       -       7
  9 Power_On_Hours          0x0032   061   061   000    Old_age   Always       -       28911
194 Temperature_Celsius     0x0022   119   106   000    Old_age   Always       -       33
EOF

    my $info = PVE::HPEiLO::Smart::_parse($ata);
    is($info->{serial}, 'WD-WCC7K0123456', 'ata: serial number read');
    is($info->{celsius}, 33, 'ata: temperature taken from the attribute table');
    is($info->{power_hours}, 28911, 'ata: power on hours from the attribute table');
    is($info->{grown_defects}, 7,
	'ata: reallocated sectors stand in for the grown defect list');
}

# --- the merge -------------------------------------------------------------

{
    # Mirrors the real machine: cciss index 0 is the drive in bay 1I:3:4, not
    # the one in bay 1I:3:1.
    my $storage = {
	controllers => [ {
	    drives => [
		{ location => '1I:3:1', serial => 'AAA', celsius => undef },
		{ location => '1I:3:4', serial => 'BBB', celsius => undef },
		{ location => '2I:3:5', serial => 'CCC', celsius => 40 },
	    ],
	} ],
    };

    my $smart = { by_serial => {
	AAA => { serial => 'AAA', celsius => 44, power_hours => 70000, trip_celsius => 68 },
	BBB => { serial => 'BBB', celsius => 46, power_hours => 72939, trip_celsius => 68 },
	CCC => { serial => 'CCC', celsius => 99, power_hours => 71000 },
    } };

    my $filled = PVE::HPEiLO::Smart::enrich($storage, $smart);

    my $drives = $storage->{controllers}->[0]->{drives};
    is($drives->[0]->{celsius}, 44, 'merge: bay 1 got its own reading');
    is($drives->[1]->{celsius}, 46,
	'merge: joined by serial, not by position in the list');
    is($drives->[2]->{celsius}, 40,
	'merge: an existing Redfish value is never overwritten');
    is($drives->[1]->{trip_celsius}, 68, 'merge: trip temperature carried over');
    is($filled, 5, 'merge: reports how many empty fields were filled');
}

# --- no data ---------------------------------------------------------------

{
    is(PVE::HPEiLO::Smart::enrich(undef, undef), 0,
	'merge: missing input is a no-op, not a crash');
}
