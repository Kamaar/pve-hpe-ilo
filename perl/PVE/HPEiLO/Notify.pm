package PVE::HPEiLO::Notify;

# Sends a notification through Proxmox VE's own notification system, so it
# arrives wherever the node already sends backup mail -- SMTP, Gotify, whatever
# the admin configured -- instead of this package growing its own mail client
# and its own set of credentials to get wrong.
#
# PVE::Notify is not a supported public API. It is part of libpve-notify-perl
# and Proxmox may change it without notice. So every call is wrapped, and a
# failure degrades to writing the message to stderr, where the systemd unit
# puts it in the journal. A monitor that dies because its own alerting broke is
# worse than no monitor at all.

use strict;
use warnings;

# PVE severities, which are not the same words the checks use.
my %SEVERITY = (
    critical => 'error',
    warning  => 'warning',
    info     => 'info',
    recovery => 'notice',
);

sub available {
    return eval { require PVE::Notify; 1 } ? 1 : 0;
}

sub _journal_priority {
    my ($severity) = @_;
    return { error => 3, warning => 4, notice => 5, info => 6 }->{$severity} // 6;
}

# Returns (1, undef) when Proxmox accepted it, or (0, reason) when it did not
# and the message was written to stderr instead.
sub send_notification {
    my (%param) = @_;

    my $severity = $SEVERITY{ $param{severity} // 'info' } // 'info';
    my $title = $param{title} // 'HPE iLO';
    my $message = $param{message} // '';

    my $ok = eval {
	require PVE::Notify;

	# common_template_data() supplies the hostname and similar context the
	# stock templates expect; without it the rendered mail is missing its
	# usual header.
	my $common = eval { PVE::Notify::common_template_data() } // {};

	PVE::Notify::notify(
	    $severity,
	    'simple',
	    { %$common, title => $title, message => $message },
	    { origin => 'pve-hpe-ilo' },
	);
	1;
    };

    return (1, undef) if $ok;

    my $err = $@ || 'unknown error';
    chomp $err;

    # The journal is the fallback channel, not a silent drop.
    my $prio = _journal_priority($severity);
    print STDERR "<$prio>$title\n";
    for my $line (split(/\n/, $message)) {
	print STDERR "<$prio>  $line\n";
    }
    print STDERR "<4>could not reach the Proxmox notification system: $err\n";

    return (0, $err);
}

1;
