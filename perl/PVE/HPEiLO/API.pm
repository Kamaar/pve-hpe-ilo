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

	    return $data;
	},
    });
}

1;
