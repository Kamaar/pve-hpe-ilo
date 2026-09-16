package PVE::HPEiLO::Version;

# Single source of truth for the package version.
#
# Referenced by the CLI, the poller's startup log, the API response and from
# there the panel header, so a node can always be asked what it is running
# without comparing file contents.

use strict;
use warnings;

our $VERSION = '1.1.0';

sub version {
    return $VERSION;
}

1;
