#!/usr/bin/perl

# The LED control is the only part of the package that writes to hardware, and
# the drive location it is given comes from an API caller. exec() is used in
# list form so no shell is involved, but ssacli would still happily read a
# crafted argument as one of its own keywords -- so the validators are what
# actually contain this, and they are pinned here.
#
# Run: perl -I perl t/ssacli.t

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../perl";

use Test::More tests => 24;

use PVE::HPEiLO::Ssacli;

# --- locations the hardware really produces --------------------------------

for my $loc (qw(1I:3:4 2I:3:8 1E:1:12 2E:10:24 1:2 12:24)) {
    ok(PVE::HPEiLO::Ssacli::valid_location($loc), "location accepted: $loc");
}

# --- everything else -------------------------------------------------------

my @bad = (
    undef,
    '',
    '1I:3:4 modify led=on',        # a second command smuggled in
    '1I:3:4;reboot',
    '1I:3:4 all',
    'all',
    '../../etc/passwd',
    '-1:2:3',
    '1I:3:4\n2I:3:5',
    'led=on',
    '1I:3:4 ',                     # trailing space, and so a second word
);

for my $loc (@bad) {
    my $label = defined $loc ? "'$loc'" : 'undef';
    ok(!PVE::HPEiLO::Ssacli::valid_location($loc), "location rejected: $label");
}

# --- slots -----------------------------------------------------------------

ok(PVE::HPEiLO::Ssacli::valid_slot('0'), 'slot 0 accepted');
ok(PVE::HPEiLO::Ssacli::valid_slot('12'), 'slot 12 accepted');
ok(!PVE::HPEiLO::Ssacli::valid_slot('0 pd all'), 'slot with extra words rejected');
ok(!PVE::HPEiLO::Ssacli::valid_slot('-1'), 'negative slot rejected');
ok(!PVE::HPEiLO::Ssacli::valid_slot(undef), 'undef slot rejected');

# --- set_led refuses bad input before it ever reaches ssacli ---------------

{
    my $err = '';

    eval { PVE::HPEiLO::Ssacli::set_led(slot => '0', location => 'all', state => 'on') };
    $err = $@;
    like($err, qr/invalid drive location|not installed/,
	'set_led rejects a bad location');

    eval { PVE::HPEiLO::Ssacli::set_led(slot => '0', location => '1I:3:4', state => 'blink') };
    $err = $@;
    like($err, qr/must be on or off|not installed/,
	'set_led rejects a state that is not on or off');
}
