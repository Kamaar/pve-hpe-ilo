/*
 * Adds a "Hardware (iLO)" tab to the Proxmox VE node view.
 *
 * Loaded as a separate file after pvemanagerlib.js (one <script> line added to
 * index.html.tpl). Nothing in pvemanagerlib.js is modified: the tab is grafted
 * on with an ExtJS override, which survives pve-manager updates far better
 * than editing the bundle in place.
 *
 * Everything here is defensive. A broken third-party panel must never take the
 * rest of the PVE GUI down with it, so the override is wrapped and failures
 * are logged rather than thrown.
 */

Ext.ns('PVE.hpe');

/* Mirrors of the constants in PVE::HPEiLO::Check. They exist here only so the
 * bars can be coloured by the same rules the health check applies -- change
 * one and change the other, or the panel starts contradicting itself. */
PVE.hpe.FAN_ALARM_PERCENT = 90;
PVE.hpe.DRIVE_TRIP_MARGIN = 5;

PVE.hpe.HEALTH_ICONS = {
    OK: { cls: 'fa-check-circle', color: '#21BF4B' },
    Warning: { cls: 'fa-exclamation-circle', color: '#FF9900' },
    Critical: { cls: 'fa-times-circle', color: '#FF6C59' },
    Unknown: { cls: 'fa-question-circle', color: '#888888' },
};

PVE.hpe.renderHealth = function(value) {
    if (!value) {
	return '-';
    }
    // iLO reports redundancy fields as free text ("Redundant"), not as a
    // health enum, so anything unrecognized is shown as plain text.
    let icon = PVE.hpe.HEALTH_ICONS[value];
    if (!icon) {
	return Ext.htmlEncode(value);
    }
    return `<i class="fa ${icon.cls}" style="color:${icon.color};"></i> ` +
	Ext.htmlEncode(value);
};

/* A horizontal bar behind the value.
 *
 * `max` sets how full the bar looks; `thresholds` sets what colour it is, and
 * must be the same numbers PVE::HPEiLO::Check uses. Colouring on a percentage
 * of `max` instead was the obvious thing and it was wrong: a sensor at 50 °C
 * against a 60 °C limit is 83% of the way there and went amber, while the
 * banner -- correctly -- stayed green because the limit had not been crossed.
 * A panel that contradicts itself teaches people to ignore both halves.
 *
 * Omit `thresholds` for a gauge where being full is not a problem, such as
 * rebuild progress.
 */
PVE.hpe.renderBar = function(value, max, text, thresholds) {
    if (value === undefined || value === null) {
	return '-';
    }
    let ratio = max > 0 ? Math.min(value / max, 1) : 0;
    let pct = Math.round(ratio * 100);

    let color = '#21BF4B';
    if (thresholds) {
	let crit = thresholds.critical;
	let warn = thresholds.warning;
	if (crit !== undefined && crit !== null && value >= crit) {
	    color = '#FF6C59';
	} else if (warn !== undefined && warn !== null && value >= warn) {
	    color = '#FF9900';
	}
    }

    return `<div style="position:relative;height:14px;background:rgba(128,128,128,0.15);` +
	`border-radius:2px;overflow:hidden;">` +
	`<div style="position:absolute;left:0;top:0;bottom:0;width:${pct}%;background:${color};"></div>` +
	`<div style="position:relative;text-align:right;padding-right:4px;` +
	`font-size:11px;line-height:14px;">${Ext.htmlEncode(text)}</div></div>`;
};

Ext.define('PVE.hpe.TemperatureGrid', {
    extend: 'Ext.grid.GridPanel',
    xtype: 'pveHPEiLOTemperatures',

    title: gettext('Temperatures'),
    border: false,
    emptyText: gettext('No readings'),
    scrollable: true,
    // ExtJS grids suppress text selection by default, which makes a model
    // number or a serial impossible to copy out of the panel.
    viewConfig: { enableTextSelection: true },

    store: {
	fields: ['name', 'celsius', 'context', 'warning', 'critical', 'health'],
	sorters: [{ property: 'name' }],
	data: [],
    },

    columns: [
	{
	    header: gettext('Sensor'),
	    dataIndex: 'name',
	    flex: 2,
	    renderer: Ext.htmlEncode,
	},
	{
	    header: gettext('Location'),
	    dataIndex: 'context',
	    flex: 1,
	    renderer: (v) => v ? Ext.htmlEncode(v) : '-',
	},
	{
	    header: gettext('Temperature'),
	    dataIndex: 'celsius',
	    flex: 2,
	    renderer: function(value, meta, rec) {
		// Without a threshold there is no meaningful scale; 100 C is
		// a sane ceiling for anything inside a server chassis.
		let max = rec.data.critical || rec.data.warning || 100;
		return PVE.hpe.renderBar(value, max, `${value} °C`, {
		    warning: rec.data.warning,
		    critical: rec.data.critical,
		});
	    },
	},
	{
	    header: gettext('Critical'),
	    dataIndex: 'critical',
	    width: 90,
	    renderer: (v) => v ? `${v} °C` : '-',
	},
    ],
});

Ext.define('PVE.hpe.FanGrid', {
    extend: 'Ext.grid.GridPanel',
    xtype: 'pveHPEiLOFans',

    title: gettext('Fans'),
    border: false,
    emptyText: gettext('No readings'),
    scrollable: true,
    viewConfig: { enableTextSelection: true },

    store: {
	fields: ['name', 'reading', 'units', 'health'],
	sorters: [{ property: 'name' }],
	data: [],
    },

    columns: [
	{
	    header: gettext('Fan'),
	    dataIndex: 'name',
	    flex: 2,
	    renderer: Ext.htmlEncode,
	},
	{
	    header: gettext('Speed'),
	    dataIndex: 'reading',
	    flex: 3,
	    renderer: function(value, meta, rec) {
		// iLO 4 reports duty cycle in percent, iLO 5 may report RPM.
		let units = rec.data.units || 'Percent';
		if (units === 'Percent') {
		    // 90% is where Check starts calling it a problem, because
		    // on HPE hardware that is how thermal trouble announces
		    // itself before anything reports unhealthy.
		    return PVE.hpe.renderBar(value, 100, `${value} %`,
			{ warning: PVE.hpe.FAN_ALARM_PERCENT });
		}
		return `${value} ${Ext.htmlEncode(units)}`;
	    },
	},
	{
	    header: gettext('Health'),
	    dataIndex: 'health',
	    width: 110,
	    renderer: PVE.hpe.renderHealth,
	},
    ],
});

Ext.define('PVE.hpe.PowerPanel', {
    extend: 'Ext.panel.Panel',
    xtype: 'pveHPEiLOPower',

    title: gettext('Power'),
    border: false,
    layout: 'vbox',
    defaults: { width: '100%' },

    items: [
	{
	    xtype: 'component',
	    itemId: 'summary',
	    padding: '10 10 5 10',
	    style: 'user-select: text;',
	    html: '-',
	},
	{
	    xtype: 'grid',
	    itemId: 'supplies',
	    border: false,
	    flex: 1,
	    viewConfig: { enableTextSelection: true },
	    emptyText: gettext('No power supplies reported'),
	    store: {
		fields: ['name', 'model', 'output_watts', 'input_voltage',
		    'capacity', 'health'],
		data: [],
	    },
	    columns: [
		{
		    header: gettext('Power Supply'),
		    dataIndex: 'name',
		    flex: 2,
		    renderer: Ext.htmlEncode,
		},
		{
		    header: gettext('Model'),
		    dataIndex: 'model',
		    flex: 1,
		    renderer: (v) => v ? Ext.htmlEncode(v) : '-',
		},
		{
		    header: gettext('Output'),
		    dataIndex: 'output_watts',
		    width: 100,
		    renderer: (v) => v === undefined || v === null ? '-' : `${v} W`,
		},
		{
		    header: gettext('Input'),
		    dataIndex: 'input_voltage',
		    width: 100,
		    renderer: (v) => v === undefined || v === null ? '-' : `${v} V`,
		},
		{
		    header: gettext('Health'),
		    dataIndex: 'health',
		    width: 110,
		    renderer: PVE.hpe.renderHealth,
		},
	    ],
	},
    ],

    updateData: function(power) {
	let me = this;
	let summary = me.down('#summary');
	let grid = me.down('#supplies');

	if (!power) {
	    summary.setHtml(gettext('No power data'));
	    grid.getStore().loadData([]);
	    return;
	}

	let watts = power.consumed_watts;
	let parts = [];
	if (power.average_watts !== undefined && power.average_watts !== null) {
	    parts.push(`${gettext('Average')}: ${power.average_watts} W`);
	}
	if (power.min_watts !== undefined && power.min_watts !== null) {
	    parts.push(`${gettext('Min')}: ${power.min_watts} W`);
	}
	if (power.max_watts !== undefined && power.max_watts !== null) {
	    parts.push(`${gettext('Max')}: ${power.max_watts} W`);
	}
	if (power.interval_min) {
	    parts.push(`${gettext('over')} ${power.interval_min} min`);
	}
	// Headroom: useful when deciding whether another card or a shelf of
	// disks fits inside what the supplies can actually deliver.
	if (power.capacity_watts) {
	    let pct = watts ? ` (${Math.round((watts / power.capacity_watts) * 100)} %)` : '';
	    parts.push(`${gettext('Capacity')}: ${power.capacity_watts} W${pct}`);
	}

	let big = watts === undefined || watts === null ? '-' : `${watts} W`;
	summary.setHtml(
	    `<div style="font-size:24px;font-weight:600;">${big}</div>` +
	    `<div style="opacity:0.75;">${Ext.htmlEncode(parts.join(' · '))}</div>`);

	grid.getStore().loadData(power.supplies || []);
    },
});

/* iLO spells a lit bay either way depending on firmware and on whether the
 * controller blinks or holds it steady. */
PVE.hpe.ledIsOn = function(value) {
    return value === 'Blinking' || value === 'Lit';
};

/* The lit-bay colour for the action column. Injected once rather than shipped
 * as a stylesheet, so the panel stays a single file. */
(function() {
    if (document.getElementById('pve-hpe-ilo-style')) {
	return;
    }
    let style = document.createElement('style');
    style.id = 'pve-hpe-ilo-style';
    style.textContent = '.pve-hpe-led-on { color: #FF9900 !important; }';
    document.head.appendChild(style);
})();

PVE.hpe.formatMiB = function(mib) {
    if (mib === undefined || mib === null) {
	return '-';
    }
    return Proxmox.Utils.format_size(mib * 1024 * 1024);
};

Ext.define('PVE.hpe.StoragePanel', {
    extend: 'Ext.panel.Panel',
    xtype: 'pveHPEiLOStorage',

    title: gettext('Storage') + ' (Smart Array)',
    border: false,
    layout: 'vbox',
    defaults: { width: '100%' },

    items: [
	{
	    xtype: 'component',
	    itemId: 'controllers',
	    padding: '10 10 5 10',
	    style: 'user-select: text;',
	    html: '-',
	},
	{
	    xtype: 'grid',
	    itemId: 'logical',
	    title: gettext('Logical Drives'),
	    border: false,
	    height: 160,
	    viewConfig: { enableTextSelection: true },
	    emptyText: gettext('No logical drives reported'),
	    store: {
		fields: ['controller', 'number', 'raid', 'capacity_mib', 'device',
		    'operation', 'progress', 'health'],
		data: [],
	    },
	    columns: [
		{
		    header: gettext('Drive'),
		    dataIndex: 'number',
		    width: 80,
		    renderer: (v) => v === undefined || v === null ? '-' : `LD ${v}`,
		},
		{
		    header: 'RAID',
		    dataIndex: 'raid',
		    width: 90,
		    renderer: (v) => v ? `RAID ${Ext.htmlEncode(String(v))}` : '-',
		},
		{
		    header: gettext('Size'),
		    dataIndex: 'capacity_mib',
		    width: 110,
		    renderer: PVE.hpe.formatMiB,
		},
		{
		    header: gettext('Device'),
		    dataIndex: 'device',
		    width: 110,
		    renderer: (v) => v ? Ext.htmlEncode(v) : '-',
		},
		{
		    header: gettext('Status'),
		    dataIndex: 'health',
		    width: 110,
		    renderer: PVE.hpe.renderHealth,
		},
		{
		    // A rebuild is the one thing here worth watching live, so
		    // it gets the whole remaining width as a progress bar.
		    header: gettext('Operation'),
		    dataIndex: 'operation',
		    flex: 1,
		    renderer: function(value, meta, rec) {
			if (!value) {
			    return '-';
			}
			let pct = rec.data.progress;
			if (pct === undefined || pct === null) {
			    return Ext.htmlEncode(value);
			}
			return PVE.hpe.renderBar(pct, 100, `${value} ${pct} %`);
		    },
		},
	    ],
	},
	{
	    xtype: 'grid',
	    itemId: 'physical',
	    title: gettext('Physical Drives'),
	    border: false,
	    flex: 1,
	    minHeight: 160,
	    viewConfig: { enableTextSelection: true },
	    emptyText: gettext('No physical drives reported'),
	    store: {
		fields: ['controller', 'location', 'model', 'media', 'interface',
		    'capacity_gb', 'celsius', 'trip_celsius', 'power_hours', 'ssd_wear',
		    'grown_defects', 'led',
		    'slot', 'led_control',
		    'health'],
		sorters: [{ property: 'location' }],
		data: [],
	    },
	    columns: [
		{
		    header: gettext('Bay'),
		    dataIndex: 'location',
		    width: 100,
		    renderer: Ext.htmlEncode,
		},
		{
		    header: gettext('Model'),
		    dataIndex: 'model',
		    flex: 1,
		    renderer: (v) => v ? Ext.htmlEncode(v) : '-',
		},
		{
		    header: gettext('Type'),
		    dataIndex: 'media',
		    width: 90,
		    renderer: function(value, meta, rec) {
			let parts = [value, rec.data.interface].filter((p) => p);
			return parts.length ? Ext.htmlEncode(parts.join(' ')) : '-';
		    },
		},
		{
		    header: gettext('Capacity'),
		    dataIndex: 'capacity_gb',
		    width: 100,
		    renderer: (v) => v ? `${v} GB` : '-',
		},
		{
		    header: gettext('Temperature'),
		    dataIndex: 'celsius',
		    width: 130,
		    renderer: function(value, meta, rec) {
			if (value === undefined || value === null) {
			    return '-';
			}
			// The drive's own trip temperature is the honest scale
			// when smartctl supplied one.
			let max = rec.data.trip_celsius;
			if (!max) {
			    return `${value} °C`;
			}
			// Check warns within DRIVE_TRIP_MARGIN of the trip
			// point; the bar has to agree with it.
			return PVE.hpe.renderBar(value, max, `${value} °C`, {
			    warning: max - PVE.hpe.DRIVE_TRIP_MARGIN,
			    critical: max,
			});
		    },
		},
		{
		    header: gettext('Power On'),
		    dataIndex: 'power_hours',
		    width: 100,
		    // Hours mean little at this magnitude; years of spinning do.
		    renderer: function(v) {
			if (v === undefined || v === null) {
			    return '-';
			}
			return `${(v / 8766).toFixed(1)} ${gettext('years')}`;
		    },
		},
		{
		    // Two different wear indicators, one column: SSDs report
		    // endurance used, spinning disks report sectors remapped
		    // since manufacture. Neither applies to the other.
		    header: gettext('Wear / Defects'),
		    dataIndex: 'ssd_wear',
		    width: 120,
		    renderer: function(value, meta, rec) {
			if (value !== undefined && value !== null) {
			    return `${value} % ${gettext('used')}`;
			}

			let defects = rec.data.grown_defects;
			if (defects === undefined || defects === null) {
			    return '-';
			}
			if (defects === 0) {
			    return `<span style="opacity:0.7;">0 ${gettext('defects')}</span>`;
			}
			// Any growth at all is worth noticing on a SAS drive;
			// a count in the tens means plan a replacement.
			let color = defects >= 10 ? '#FF6C59' : '#FF9900';
			return `<span style="color:${color};">` +
			    `<i class="fa fa-exclamation-triangle"></i> ` +
			    `${defects} ${gettext('defects')}</span>`;
		    },
		},
		{
		    header: gettext('Status'),
		    dataIndex: 'health',
		    width: 110,
		    renderer: function(value, meta, rec) {
			let html = PVE.hpe.renderHealth(value);
			// A lit bay means somebody is locating that drive right
			// now; worth seeing next to its status.
			if (PVE.hpe.ledIsOn(rec.data.led)) {
			    html += ' <i class="fa fa-lightbulb-o" style="color:#FF9900;"></i>';
			}
			return html;
		    },
		},
		{
		    // The only control in the panel that writes to hardware.
		    // Lighting a bay is how you tell eight identical disks
		    // apart before pulling one.
		    xtype: 'actioncolumn',
		    header: gettext('Locate'),
		    width: 70,
		    align: 'center',
		    items: [{
			getClass: function(v, meta, rec) {
			    return PVE.hpe.ledIsOn(rec.data.led)
				? 'fa fa-lightbulb-o pve-hpe-led-on'
				: 'fa fa-lightbulb-o';
			},
			getTip: function(v, meta, rec) {
			    if (!rec.data.led_control) {
				return gettext('Needs ssacli installed on the node');
			    }
			    return PVE.hpe.ledIsOn(rec.data.led)
				? gettext('Turn the bay LED off')
				: gettext('Light this bay to identify the disk');
			},
			isDisabled: (view, r, c, i, rec) =>
			    !rec.data.led_control || rec.data.slot === undefined ||
			    rec.data.slot === null,
			handler: function(view, rowIndex, colIndex, item, e, rec) {
			    let panel = view.up('pveHPEiLOStorage');
			    let lit = PVE.hpe.ledIsOn(rec.get('led'));
			    let location = rec.get('location');
			    let wanted = lit ? 'Off' : 'Blinking';

			    Proxmox.Utils.API2Request({
				url: `/nodes/${panel.nodename}/hpe-ilo-led`,
				method: 'POST',
				params: {
				    slot: String(rec.get('slot')),
				    drive: location,
				    state: lit ? 'off' : 'on',
				},
				success: function() {
				    // iLO re-reads IndicatorLED only on the
				    // storage cycle, up to five minutes away.
				    // Remember what we asked for so the next
				    // refresh does not revert the icon and make
				    // the click look like it failed.
				    panel.ledOverrides[location] = wanted;
				    rec.set('led', wanted);
				    rec.commit();
				},
				failure: function(response) {
				    Ext.Msg.alert(gettext('Error'), response.htmlStatus);
				},
			    });
			},
		    }],
		},
	    ],
	},
    ],

    initComponent: function() {
	let me = this;
	// Bay -> LED state we asked for but iLO has not confirmed yet.
	me.ledOverrides = {};
	me.callParent();
    },

    updateData: function(storage, age) {
	let me = this;
	let header = me.down('#controllers');

	if (!storage) {
	    header.setHtml(gettext('No Smart Array data'));
	    me.down('#logical').getStore().loadData([]);
	    me.down('#physical').getStore().loadData([]);
	    return;
	}

	let lds = [];
	let pds = [];
	let lines = [];

	Ext.Array.each(storage.controllers || [], function(c) {
	    let label = c.model || gettext('Controller');
	    let bits = [];
	    if (c.location) {
		bits.push(Ext.htmlEncode(c.location));
	    }
	    if (c.mode) {
		bits.push(Ext.htmlEncode(c.mode));
	    }
	    if (c.cache_mib) {
		bits.push(`${gettext('Cache')} ${c.cache_mib} MiB`);
	    }
	    if (c.firmware) {
		bits.push(`fw ${Ext.htmlEncode(c.firmware)}`);
	    }
	    if (c.rebuild_priority) {
		bits.push(`${gettext('Rebuild')} ${Ext.htmlEncode(c.rebuild_priority)}`);
	    }
	    // Zero spares on a populated array is worth seeing written down: it
	    // is the difference between a rebuild that starts by itself and one
	    // that waits for someone to walk to the rack.
	    if (c.spares !== undefined && c.spares !== null) {
		bits.push(Ext.String.format(gettext('{0} spare(s)'), c.spares));
	    }
	    if (c.unassigned) {
		bits.push(Ext.String.format(gettext('{0} unassigned'), c.unassigned));
	    }

	    // A missing cache capacitor drops the controller back to
	    // write-through, which is a large silent performance loss.
	    // iLO reports one of Present, PresentAndCharged,
	    // PresentAndCharging or NotPresent; only the last is a fault, and
	    // charging is the normal transient state after a power loss.
	    let backup = '';
	    if (c.backup_power) {
		let good = c.backup_power.startsWith('Present');
		let color = good ? '#21BF4B' : '#FF6C59';
		backup = ` &middot; <span style="color:${color};">` +
		    `${gettext('Cache backup')}: ${Ext.htmlEncode(c.backup_power)}</span>`;
	    }

	    lines.push(`<div><b>${Ext.htmlEncode(label)}</b> ` +
		`${PVE.hpe.renderHealth(c.health)} &middot; ` +
		`${bits.join(' &middot; ')}${backup}</div>`);

	    if (c.truncated) {
		lines.push(`<div style="opacity:0.7;">` +
		    Ext.String.format(gettext('{0} further drives not listed'),
			c.truncated) + `</div>`);
	    }

	    Ext.Array.each(c.logical_drives || [], function(ld) {
		lds.push(Ext.apply({ controller: label }, ld));
	    });
	    Ext.Array.each(c.drives || [], function(pd) {
		// The LED control needs the controller slot and whether ssacli
		// is present; both live one level up from the drive.
		let row = Ext.apply({
		    controller: label,
		    slot: c.slot,
		    led_control: storage.led_control ? 1 : 0,
		}, pd);

		// Hold a locally requested LED state until iLO reports the
		// same thing, then stop overriding: the backend has caught up.
		let pending = me.ledOverrides[row.location];
		if (pending !== undefined) {
		    if (pending === row.led) {
			delete me.ledOverrides[row.location];
		    } else {
			row.led = pending;
		    }
		}

		pds.push(row);
	    });
	});

	if (age !== undefined && age !== null) {
	    lines.push(`<div style="margin-top:4px;opacity:0.7;">` +
		Ext.String.format(gettext('Smart Array sampled {0}s ago'), age) +
		`</div>`);
	}

	header.setHtml(lines.join('') || gettext('No controllers reported'));
	me.down('#logical').getStore().loadData(lds);
	me.down('#physical').getStore().loadData(pds);
    },
});

Ext.define('PVE.hpe.ILOPanel', {
    extend: 'Ext.panel.Panel',
    xtype: 'pveHPEiLOPanel',

    // Browser-side interval. The data behind it refreshes at the poller's own
    // pace (30s by default); polling faster only costs a file read.
    updateInterval: 5000,

    border: false,
    scrollable: true,
    layout: {
	type: 'vbox',
	align: 'stretch',
    },
    defaults: { margin: '0 0 8 0' },

    items: [
	{
	    // Deliberately the first thing on the page and impossible to miss.
	    // Everything below it is detail you go looking for; this is the part
	    // that has to work when nobody is looking for anything.
	    xtype: 'component',
	    itemId: 'banner',
	    padding: '10 12',
	    style: 'user-select: text;',
	    html: '',
	},
	{
	    xtype: 'component',
	    itemId: 'statusbar',
	    padding: 10,
	    style: 'user-select: text;',
	    html: gettext('Loading...'),
	},
	{
	    xtype: 'pveHPEiLOTemperatures',
	    itemId: 'temperatures',
	    height: 320,
	},
	{
	    xtype: 'pveHPEiLOFans',
	    itemId: 'fans',
	    height: 240,
	},
	{
	    xtype: 'pveHPEiLOPower',
	    itemId: 'power',
	    height: 260,
	},
	{
	    xtype: 'pveHPEiLOStorage',
	    itemId: 'storage',
	    height: 420,
	},
    ],

    setStatus: function(html) {
	this.down('#statusbar').setHtml(html);
    },

    // One banner summarising every rule in PVE::HPEiLO::Check, which is the
    // same evaluation the notifier sends by mail. If the two ever disagree,
    // the bug is here, not there.
    updateBanner: function(issues) {
	let me = this;
	let banner = me.down('#banner');

	let styles = {
	    critical: { bg: '#FDE7E4', border: '#FF6C59', fg: '#8B2114',
		icon: 'fa-times-circle' },
	    warning: { bg: '#FFF4E0', border: '#FF9900', fg: '#7A4A00',
		icon: 'fa-exclamation-triangle' },
	    info: { bg: '#E7F1FD', border: '#3892D4', fg: '#1B4E75',
		icon: 'fa-info-circle' },
	    ok: { bg: '#E8F7EC', border: '#21BF4B', fg: '#14622A',
		icon: 'fa-check-circle' },
	};

	issues = issues || [];

	let counts = { critical: 0, warning: 0, info: 0 };
	Ext.Array.each(issues, (i) => {
	    if (counts[i.severity] !== undefined) {
		counts[i.severity]++;
	    }
	});

	let level = 'ok';
	if (counts.critical) {
	    level = 'critical';
	} else if (counts.warning) {
	    level = 'warning';
	} else if (counts.info) {
	    level = 'info';
	}

	let s = styles[level];
	let headline;

	if (level === 'ok') {
	    headline = gettext('All hardware checks passing');
	} else {
	    let parts = [];
	    if (counts.critical) {
		parts.push(Ext.String.format(gettext('{0} critical'), counts.critical));
	    }
	    if (counts.warning) {
		parts.push(Ext.String.format(gettext('{0} warning(s)'), counts.warning));
	    }
	    if (counts.info) {
		parts.push(Ext.String.format(gettext('{0} in progress'), counts.info));
	    }
	    headline = parts.join(' · ');
	}

	let list = issues.map(
	    (i) => `<li style="margin-top:2px;">${Ext.htmlEncode(i.text)}</li>`).join('');

	banner.setHtml(
	    `<div style="background:${s.bg};border-left:4px solid ${s.border};` +
	    `color:${s.fg};border-radius:3px;padding:8px 12px;">` +
	    `<div style="font-size:14px;font-weight:600;">` +
	    `<i class="fa ${s.icon}"></i> ${Ext.htmlEncode(headline)}</div>` +
	    (list ? `<ul style="margin:6px 0 0 18px;padding:0;">${list}</ul>` : '') +
	    `</div>`);
    },

    updateView: function(data) {
	let me = this;

	me.updateBanner(data.issues);
	me.down('#temperatures').getStore().loadData(data.temperatures || []);
	me.down('#fans').getStore().loadData(data.fans || []);
	me.down('#power').updateData(data.power);
	me.down('#storage').updateData(data.storage, data.storage_age);

	let lines = [];

	if (data.status !== 'ok') {
	    let msg = data.error || gettext('No data');
	    lines.push(
		`<div style="color:#FF9900;"><i class="fa fa-exclamation-triangle"></i> ` +
		`${Ext.htmlEncode(data.status || 'error')}: ${Ext.htmlEncode(msg)}</div>`);
	}

	let server = data.server || {};
	let ilo = data.ilo || {};
	let descr = [];
	if (server.model) {
	    descr.push(Ext.htmlEncode(server.model));
	}
	if (server.serial) {
	    descr.push(`S/N ${Ext.htmlEncode(server.serial)}`);
	}
	if (server.bios) {
	    descr.push(`BIOS ${Ext.htmlEncode(server.bios)}`);
	}
	if (ilo.type) {
	    descr.push(`${Ext.htmlEncode(ilo.type)} ${Ext.htmlEncode(ilo.firmware || '')}`);
	}
	if (descr.length) {
	    lines.push(`<div style="font-weight:600;">${descr.join(' &middot; ')}</div>`);
	}

	let health = data.health || {};
	let badges = Object.keys(health).sort().map(
	    (key) => `<span style="margin-right:12px;white-space:nowrap;">` +
		`${Ext.htmlEncode(key)}: ${PVE.hpe.renderHealth(health[key])}</span>`);
	if (badges.length) {
	    lines.push(`<div style="margin-top:4px;">${badges.join('')}</div>`);
	}

	if (data.age !== undefined) {
	    let sampled = Ext.String.format(gettext('Sampled {0}s ago'), data.age);
	    if (data.version) {
		sampled += ` &middot; pve-hpe-ilo ${Ext.htmlEncode(data.version)}`;
	    }
	    lines.push(`<div style="margin-top:4px;opacity:0.7;">${sampled}</div>`);
	}

	// Section-level failures are worth showing: one dead endpoint on old
	// firmware should be visible, not silently missing data.
	let errors = data.errors || {};
	let failed = Object.keys(errors);
	if (failed.length) {
	    let detail = failed.map((k) => `${k}: ${Ext.htmlEncode(errors[k])}`).join('<br>');
	    lines.push(`<div style="margin-top:4px;opacity:0.7;">${detail}</div>`);
	}

	me.setStatus(lines.join(''));
    },

    reload: function() {
	let me = this;

	Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/hpe-ilo`,
	    method: 'GET',
	    success: function(response) {
		me.updateView(response.result.data || {});
	    },
	    failure: function(response) {
		// A 501 here means the API patch is missing, which is the
		// expected state right after a pve-manager upgrade.
		let hint = response.status === 501
		    ? gettext('API endpoint missing - run pve-hpe-ilo-patch')
		    : response.htmlStatus;
		me.setStatus(`<div style="color:#FF6C59;">` +
		    `<i class="fa fa-times-circle"></i> ${hint}</div>`);
	    },
	});
    },

    initComponent: function() {
	let me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	me.callParent();

	// The storage panel issues its own API calls for the LED control.
	me.down('#storage').nodename = me.nodename;

	me.updateTask = Ext.TaskManager.newTask({
	    run: () => me.reload(),
	    interval: me.updateInterval,
	});

	// Only poll while the tab is actually on screen.
	me.on('activate', () => me.updateTask.start());
	me.on('deactivate', () => me.updateTask.stop());
	me.on('destroy', () => me.updateTask.stop());
    },
});

/* Graft the tab onto the node view.
 *
 * The node view is a Proxmox.panel.Config. Its left-hand navigation is not a
 * tab bar but an Ext.list.Tree, and the toolkit builds that tree store ONCE in
 * initComponent, turning each entry of me.items into an Ext.data.TreeModel
 * node keyed by itemId. Calling add() afterwards therefore creates the card
 * but never the navigation entry: the panel exists, is unreachable, and
 * nothing throws.
 *
 * So the injection has to happen inside initComponent -- after
 * PVE.node.Config has finished filling me.items, and before the toolkit reads
 * it. Overriding the toolkit's own initComponent lands exactly in that gap,
 * with me still being the PVE.node.Config instance.
 */
/* A one-line version of the banner for the node Summary page, which is where
 * everyone lands. The Hardware tab is only useful to someone who already
 * suspects something; this is for the other 99% of visits.
 *
 * It renders nothing at all when the hardware is healthy. A permanent green
 * strip on the summary of every node would be noise, and noise is what people
 * learn to look past.
 */
Ext.define('PVE.hpe.SummaryBanner', {
    extend: 'Ext.panel.Panel',
    xtype: 'pveHPEiLOSummaryBanner',

    border: false,
    bodyPadding: 0,
    hidden: true,
    columnWidth: 1,

    // Slower than the hardware tab: this is a glance, not a dashboard.
    updateInterval: 30000,

    initComponent: function() {
	let me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	me.callParent();

	me.updateTask = Ext.TaskManager.newTask({
	    run: () => me.reload(),
	    interval: me.updateInterval,
	});

	me.on('afterrender', () => me.updateTask.start());
	me.on('destroy', () => me.updateTask.stop());
    },

    reload: function() {
	let me = this;

	Proxmox.Utils.API2Request({
	    url: `/nodes/${me.nodename}/hpe-ilo`,
	    method: 'GET',
	    success: function(response) {
		me.render_issues((response.result.data || {}).issues || []);
	    },
	    // Silent on failure. If the endpoint is missing or the user lacks
	    // Sys.Audit, the summary page should look exactly as it always did.
	    failure: () => me.setHidden(true),
	});
    },

    render_issues: function(issues) {
	let me = this;

	let counts = { critical: 0, warning: 0, info: 0 };
	Ext.Array.each(issues, (i) => {
	    if (counts[i.severity] !== undefined) {
		counts[i.severity]++;
	    }
	});

	// 'info' alone means something like a rebuild running: worth seeing on
	// the summary, but not worth colouring the page.
	if (!counts.critical && !counts.warning && !counts.info) {
	    me.setHidden(true);
	    return;
	}

	let level = counts.critical ? 'critical' : (counts.warning ? 'warning' : 'info');
	let style = {
	    critical: { bg: '#FDE7E4', border: '#FF6C59', fg: '#8B2114', icon: 'fa-times-circle' },
	    warning: { bg: '#FFF4E0', border: '#FF9900', fg: '#7A4A00', icon: 'fa-exclamation-triangle' },
	    info: { bg: '#E7F1FD', border: '#3892D4', fg: '#1B4E75', icon: 'fa-info-circle' },
	}[level];

	let lines = issues.map(
	    (i) => `<li style="margin-top:2px;">${Ext.htmlEncode(i.text)}</li>`).join('');

	me.setHtml(
	    `<div style="background:${style.bg};border-left:4px solid ${style.border};` +
	    `color:${style.fg};border-radius:3px;padding:8px 12px;">` +
	    `<div style="font-size:14px;font-weight:600;">` +
	    `<i class="fa ${style.icon}"></i> ` +
	    Ext.String.format(gettext('Server hardware: {0} issue(s)'), issues.length) +
	    `</div><ul style="margin:6px 0 0 18px;padding:0;">${lines}</ul>` +
	    `<div style="margin-top:6px;opacity:0.8;">` +
	    gettext('Details in the Hardware (iLO) tab') + `</div></div>`);

	me.setHidden(false);
    },
});

/* Both readable from the browser console: overrideInstalled names the class
 * that was actually patched, injected says whether the graft then happened. */
PVE.hpe.injected = false;
PVE.hpe.overrideInstalled = false;
PVE.hpe.summaryInjected = false;

/* The Summary page is an ordinary container, not the treelist-backed Config
 * panel, so inserting after callParent() genuinely renders here. Kept separate
 * from the tab graft on purpose: if this one ever stops working, the tab and
 * the notifications are unaffected.
 */
Ext.define('PVE.hpe.SummaryOverride', {
    override: 'PVE.node.Summary',

    initComponent: function() {
	let me = this;

	me.callParent();

	try {
	    let nodename = me.pveSelNode.data.node;
	    let caps = Ext.state.Manager.get('GuiCap');
	    let allowed = !caps || !caps.nodes || caps.nodes['Sys.Audit'];

	    if (nodename && allowed) {
		me.insert(0, {
		    xtype: 'pveHPEiLOSummaryBanner',
		    nodename: nodename,
		});
		PVE.hpe.summaryInjected = true;
	    }
	} catch (err) {
	    // The node summary is the first page everyone sees. It must survive
	    // anything going wrong here.
	    console.error('pve-hpe-ilo: could not add the summary banner', err);
	}
    },
});

PVE.hpe.nodeConfigOverride = function() {
    let me = this;

    try {
	// The same parent class backs the datacenter, guest and storage views.
	// Only the node view gets the extra entry.
	if (me.$className === 'PVE.node.Config' && Ext.isArray(me.items)) {
	    let nodename = me.pveSelNode.data.node;

	    // The API endpoint requires Sys.Audit on the node. Mirror that the
	    // way PVE gates its own entries, so a user without it is not
	    // offered a tab that can only fail.
	    let caps = Ext.state.Manager.get('GuiCap');
	    let allowed = !caps || !caps.nodes || caps.nodes['Sys.Audit'];

	    if (nodename && allowed) {
		me.items.push({
		    xtype: 'pveHPEiLOPanel',
		    itemId: 'hpe-ilo',
		    title: gettext('Hardware') + ' (iLO)',
		    iconCls: 'fa fa-thermometer-half',
		    nodename: nodename,
		});
		PVE.hpe.injected = true;
	    }
	}
    } catch (err) {
	// This runs for every config panel in the GUI and must never stop one
	// from initializing.
	console.error('pve-hpe-ilo: could not add hardware tab', err);
    }

    me.callParent();
};

/* Install the override on whatever class PVE.node.Config actually extends.
 *
 * Hardcoding that name does not work: it has moved between pve-manager
 * releases, and Ext.define({override: '...'}) on a class that is never defined
 * queues the override forever and reports nothing -- no tab, no error, nothing
 * in the console. Deriving it from the class itself cannot go stale.
 *
 * The immediate superclass is the right target by construction: it is where
 * PVE.node.Config.initComponent's own callParent() lands, which is precisely
 * the gap between "me.items is fully built" and "the toolkit turns it into
 * navigation nodes".
 */
PVE.hpe.installOverride = function() {
    if (PVE.hpe.overrideInstalled) {
	return true;
    }

    let cls = Ext.ClassManager.get('PVE.node.Config');
    let parent = cls && cls.superclass && cls.superclass.$className;
    if (!parent) {
	return false;
    }

    Ext.define('PVE.hpe.ConfigPanelOverride', {
	override: parent,
	initComponent: PVE.hpe.nodeConfigOverride,
    });

    PVE.hpe.overrideInstalled = parent;
    return true;
};

// Normally the class exists already, since this file loads after
// pvemanagerlib.js. Ext.onReady is the fallback, and still runs before any
// node view can be instantiated.
if (!PVE.hpe.installOverride()) {
    Ext.onReady(function() {
	if (!PVE.hpe.installOverride()) {
	    console.error('pve-hpe-ilo: PVE.node.Config not found, cannot add' +
		' the hardware tab');
	}
    });
}
