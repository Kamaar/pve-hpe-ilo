package PVE::HPEiLO::API;

# Registers GET /nodes/{node}/hpe-ilo on the existing PVE node API.
#
# There is no plugin loader for PVE::API2, so this module is pulled in by a
# single guarded line appended to PVE/API2/Nodes.pm (see scripts/patch.sh).
# Keeping all the logic here means that patch never has to change.
#
# The handler only reads the cache file written by pve-hpe-ilo-poller: it must
# never talk to iLO itself, because a slow BMC would block a pvedaemon worker.

use strict;
use warnings;

use JSON;

use PVE::JSONSchema qw(get_standard_option);

use PVE::HPEiLO::Config;
use PVE::HPEiLO::Ssacli;
use PVE::HPEiLO::Version;

my $registered = 0;

sub _read_cache {
    my $file = PVE::HPEiLO::Config::CACHE_FILE;

    if (!-e $file) {
	my $configured = -e PVE::HPEiLO::Config::CONFIG_FILE;
	return {
	    status => $configured ? 'stale' : 'unconfigured',
	    error  => $configured
		? 'no sample yet - is pve-hpe-ilo.service running?'
		: 'not configured - create ' . PVE::HPEiLO::Config::CONFIG_FILE,
	    temperatures => [],
	    fans => [],
	};
    }

    my $raw = '';
    if (open(my $fh, '<', $file)) {
	local $/;
	$raw = <$fh> // '';
	close($fh);
    }

    my $data = eval { decode_json($raw) };
    if ($@ || ref($data) ne 'HASH') {
	return {
	    status => 'error',
	    error  => 'cache file is unreadable or corrupt',
	    temperatures => [],
	    fans => [],
	};
    }

    return $data;
}

sub register {
    return if $registered++;

    PVE::API2::Nodes::Nodeinfo->register_method({
	name => 'hpe_ilo',
	path => 'hpe-ilo',
	method => 'GET',
	# Forces execution in pvedaemon (root), which is what can read the
	# 0600 cache file under /run.
	protected => 1,
	proxyto => 'node',
	permissions => {
	    check => ['perm', '/nodes/{node}', ['Sys.Audit']],
	},
	description => "Read HPE iLO hardware telemetry (temperatures, fan"
	    . " speeds, power draw) sampled by pve-hpe-ilo-poller.",
	parameters => {
	    additionalProperties => 0,
	    properties => {
		node => get_standard_option('pve-node'),
	    },
	},
	returns => {
	    type => 'object',
	    additionalProperties => 1,
	    properties => {
		status => {
		    type => 'string',
		    description => 'ok, stale, error or unconfigured.',
		},
		age => {
		    type => 'integer',
		    optional => 1,
		    description => 'Seconds since the sample was taken.',
		},
	    },
	},
	code => sub {
	    my $data = _read_cache();

	    if (defined $data->{timestamp}) {
		my $age = time() - $data->{timestamp};
		$age = 0 if $age < 0;
		$data->{age} = $age;

		# The poller's own interval plus slack; beyond that the panel
		# should say so rather than show numbers as if they were live.
		my $limit = ($data->{interval} // 30) * 3;
		if ($age > $limit && ($data->{status} // '') eq 'ok') {
		    $data->{status} = 'stale';
		    $data->{error} //= "last sample is ${age}s old";
		}
	    }

	    $data->{status} //= 'error';

	    # Comes from the module actually loaded in pvedaemon, so it reports
	    # what this node is running rather than what the cache was written by.
	    $data->{version} = $PVE::HPEiLO::Version::VERSION;

	    return $data;
	},
    });

    # The only write in the package. Separate path and separate privilege from
    # the read endpoint, so granting someone the panel does not grant them this.
    PVE::API2::Nodes::Nodeinfo->register_method({
	name => 'hpe_ilo_led',
	path => 'hpe-ilo-led',
	method => 'POST',
	protected => 1,
	proxyto => 'node',
	permissions => {
	    check => ['perm', '/nodes/{node}', ['Sys.Modify']],
	},
	description => "Turn the locate LED on a Smart Array drive bay on or"
	    . " off, so the right disk can be identified before pulling it.",
	parameters => {
	    additionalProperties => 0,
	    properties => {
		node => get_standard_option('pve-node'),
		slot => {
		    type => 'string',
		    pattern => '^[0-9]{1,3}$',
		    description => 'Smart Array controller slot number.',
		},
		drive => {
		    type => 'string',
		    pattern => '^([0-9]{1,2}[IE]:[0-9]{1,3}:[0-9]{1,3}|[0-9]{1,3}:[0-9]{1,3})$',
		    description => 'Drive bay, as port:box:bay (e.g. 1I:3:4).',
		},
		state => {
		    type => 'string',
		    enum => ['on', 'off'],
		    description => 'Whether to light the bay LED.',
		},
	    },
	},
	returns => { type => 'null' },
	code => sub {
	    my ($param) = @_;

	    # The schema already constrains these; Ssacli validates them again
	    # because it is also reachable from the command line.
	    PVE::HPEiLO::Ssacli::set_led(
		slot     => $param->{slot},
		location => $param->{drive},
		state    => $param->{state},
	    );

	    return undef;
	},
    });
}

1;
