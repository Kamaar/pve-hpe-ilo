# Development helpers. Installation happens on the node with ./install.sh.

PERL_MODULES := $(wildcard perl/PVE/HPEiLO/*.pm)
SCRIPTS      := sbin/pve-hpe-ilo sbin/pve-hpe-ilo-poller

.PHONY: test syntax check clean

test: syntax
	perl -I perl t/normalize.t
	perl -I perl t/smart.t
	bash t/patch.sh

# Everything compiles without a Proxmox node present; API.pm is the exception,
# since it calls into PVE::API2::Nodes, so it is only checked on a node.
syntax:
	@for f in $(PERL_MODULES); do \
		case "$$f" in *API.pm) continue;; esac; \
		perl -I perl -c $$f || exit 1; \
	done
	@for f in $(SCRIPTS); do perl -I perl -c $$f || exit 1; done
	@bash -n scripts/pve-hpe-ilo-patch && echo "scripts/pve-hpe-ilo-patch syntax OK"
	@bash -n install.sh && echo "install.sh syntax OK"
	@if command -v node >/dev/null 2>&1; then \
		node --check js/pve-hpe-ilo.js && echo "js/pve-hpe-ilo.js syntax OK"; \
	else \
		echo "node not found, skipping JS syntax check"; \
	fi

# Run on the node after installing, to confirm the hooks survived the last
# round of upgrades.
check:
	/usr/sbin/pve-hpe-ilo-patch --check
	systemctl is-active pve-hpe-ilo.service
	pve-hpe-ilo status

clean:
	rm -f perl/PVE/HPEiLO/*.bak
