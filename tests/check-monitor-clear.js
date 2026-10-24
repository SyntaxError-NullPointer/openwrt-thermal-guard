// SPDX-License-Identifier: GPL-2.0-only
// Feeds the Clear wait of the monitor page with status sequences and checks
// how it ends. Plain Node, no dependencies. Usage: node tests/check-monitor-clear.js
// [path to monitor.js]; exit 1 on any failed case.
'use strict';

var nodeFs = require('fs');
var path = require('path');

var file = process.argv[2] || path.join(__dirname, '..', 'luci-app-thermal-guard',
	'htdocs', 'luci-static', 'resources', 'view', 'thermal-guard', 'monitor.js');
var src = nodeFs.readFileSync(file, 'utf8');

// LuCI adds format() to strings; the page relies on %s, %d and %%.
if (!String.prototype.format) {
	String.prototype.format = function() {
		var args = arguments, i = 0;
		return this.replace(/%([sd%])/g, function(m, c) {
			if (c === '%')
				return '%';
			var v = args[i++];
			return c === 'd' ? String(parseInt(v, 10)) : String(v);
		});
	};
}

var clock = 1700000000000;
Date.now = function() { return clock; };

var notes = [];
var execResult = null;
var rendered = null;

function E(tag, attrs, children) {
	return { tag: tag, attrs: attrs, children: children };
}

var stubs = {
	view: { extend: function(o) { return o; } },
	poll: { add: function() {} },
	dom: { content: function(node, children) { rendered = children; } },
	fs: {
		read: function() { return Promise.reject(new Error('not in this check')); },
		exec: function() { return Promise.resolve(execResult); }
	},
	ui: {
		addNotification: function(title, node, type) {
			notes.push([ type, typeof node.children === 'string' ? node.children : String(node.children) ]);
		},
		createHandlerFn: function() { return function() {}; }
	},
	_: function(s) { return s; },
	E: E,
	L: { bind: function(fn, ctx) { return fn.bind(ctx); } }
};

// The view file is a LuCI module body: its top level return is only valid
// inside a function, which is how LuCI loads it too.
var proto = new Function('view', 'poll', 'dom', 'fs', 'ui', '_', 'E', 'L', src)(
	stubs.view, stubs.poll, stubs.dom, stubs.fs, stubs.ui, stubs._, stubs.E, stubs.L);

var A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
var B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

var STARTED = [ 'info', 'Clearing started, the result follows in a moment.' ];
var CLEARED = [ 'info', 'Protection stages cleared.' ];
var RESTARTED = [ 'warning', 'The router restarted while clearing, the result is unknown.' ];
var EVICTED = [ 'warning', 'The result of this clear is no longer available. See the status and the log.' ];
var UNKNOWN = [ 'warning', 'No result for this clear arrived in time, the outcome is unknown.' ];
var ABORTED = [ 'warning', 'Clearing was aborted.' ];

function startOut(boot, gen, pid, ts, joined) {
	return 'reset_boot=' + boot + '\nreset_id=' + gen + '-' + pid + '\nreset_gen=' + gen +
		'\nreset_ts=' + ts + '\n' + (joined ? 'reset_joined=1\n' : '');
}

// A status record: cur and prev are [ id, state, failed, ts ]. The current
// request's list is its own key; the warning list starts out the same.
function status(boot, cur, prev) {
	var st = { now: '1000', reset_boot: boot, reset_id: '', reset_gen: '', reset_state: '',
		reset_ts: '', reset_failed: '', reset_req_failed: '', reset_kind: 'page',
		reset_prev_id: '', reset_prev_gen: '', reset_prev_state: '', reset_prev_failed: '',
		reset_prev_ts: '' };
	if (cur) {
		st.reset_id = cur[0]; st.reset_gen = cur[0].split('-')[0]; st.reset_state = cur[1];
		st.reset_failed = st.reset_req_failed = cur[2] || '';
		st.reset_ts = String(cur[3] || 1000);
	}
	if (prev) {
		st.reset_prev_id = prev[0]; st.reset_prev_gen = prev[0].split('-')[0];
		st.reset_prev_state = prev[1]; st.reset_prev_failed = prev[2] || '';
		st.reset_prev_ts = String(prev[3] || 1000);
	}
	return st;
}

// The daemon's own boot key, which older daemons do not write.
function withBoot(st, boot) {
	st.boot_id = boot;
	return st;
}

// The warning list as a stage entry after the clear leaves it.
function withWarning(st, list) {
	st.reset_failed = list;
	return st;
}

// A daemon from before reset_req_failed: the warning list is all there is.
function legacy(st) {
	delete st.reset_req_failed;
	return st;
}

// steps: status objects, null for a failed read, or { advance: seconds }.
var cases = [
	{
		name: 'previous record carries its own failure list',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '3-100', 'running', '', 1000 ], [ '2-90', 'done', '', 990 ]),
			status(A, [ '4-200', 'failed', 'wifi_off', 1005 ], [ '3-100', 'failed', 'fan', 1000 ])
		],
		notes: [ [ 'warning', 'Clearing could not undo everything. Still in force: fan' ] ],
		waiting: false
	},
	{
		name: 'previous done is not blamed for the current failure',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '4-200', 'failed', 'wifi_off', 1005 ], [ '3-100', 'done', '', 1000 ]) ],
		notes: [ CLEARED ],
		waiting: false
	},
	{
		name: 'previous done with an earlier leftover names its own list',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '4-200', 'done', 'wifi_off', 1005 ], [ '3-100', 'done', 'fan', 1000 ]) ],
		notes: [ [ 'info', 'Protection stages cleared. Still in force from an earlier clear: fan' ] ],
		waiting: false
	},
	{
		name: 'current record ends the wait with its list',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '3-100', 'starting', '', 1000 ], [ '2-90', 'failed', 'fan', 990 ]),
			status(A, [ '3-100', 'failed', 'wifi_off', 1000 ], [ '2-90', 'failed', 'fan', 990 ])
		],
		notes: [ [ 'warning', 'Clearing could not undo everything. Still in force: wifi_off' ] ],
		waiting: false
	},
	{
		name: 'old id of the same second never ends a wait',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '2-90', 'done', '', 1000 ], [ '1-80', 'done', '', 1000 ]),
			status(A, [ '2-90', 'busy', '', 1000 ], [ '1-80', 'failed', 'fan', 1000 ])
		],
		notes: [],
		waiting: true
	},
	{
		name: 'old id first, own result later',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '2-90', 'done', '', 1000 ], [ '1-80', 'done', '', 1000 ]),
			status(A, [ '3-100', 'done', '', 1000 ], [ '2-90', 'done', '', 1000 ])
		],
		notes: [ CLEARED ],
		waiting: false
	},
	{
		name: 'same id and generation from another boot is interrupted, not success',
		start: startOut(A, 1, 500, 1000),
		steps: [ status(B, [ '1-500', 'done', '', 1000 ], null) ],
		notes: [ RESTARTED ],
		waiting: false
	},
	{
		name: 'higher generations of another boot are interrupted, not evicted',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(B, [ '5-300', 'done', '', 1010 ], [ '4-200', 'done', '', 1005 ]) ],
		notes: [ RESTARTED ],
		waiting: false
	},
	{
		name: 'two higher generations in this boot: no longer available at once',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '5-300', 'done', '', 1000 ], [ '4-200', 'done', '', 1000 ]) ],
		notes: [ EVICTED ],
		waiting: false
	},
	{
		name: 'one higher generation and this request as previous is a result',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '4-200', 'running', '', 1001 ], [ '3-100', 'done', '', 1000 ]) ],
		notes: [ CLEARED ],
		waiting: false
	},
	{
		name: 'timeout gives unknown, never running or success',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '3-100', 'running', '', 1000 ], null),
			{ advance: 200 },
			null,
			{ advance: 301 },
			status(A, [ '3-100', 'running', '', 1000 ], null)
		],
		notes: [ UNKNOWN ],
		waiting: false
	},
	{
		// Lock wait, budget, final flush and admission: about 480 s at worst.
		name: 'the slowest clear that still ends is waited for',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '3-100', 'running', '', 1000 ], null),
			{ advance: 480 },
			status(A, [ '3-100', 'running', '', 1000 ], null)
		],
		notes: [],
		waiting: true
	},
	{
		name: 'the wait holds up to RESET_WAIT plus RESET_BUDGET plus 60 s',
		start: startOut(A, 3, 100, 1000),
		steps: [ { advance: 500 }, null ],
		notes: [],
		waiting: true
	},
	{
		name: 'timeout on a failed read gives unknown',
		start: startOut(A, 3, 100, 1000),
		steps: [ { advance: 501 }, null ],
		notes: [ UNKNOWN ],
		waiting: false
	},
	{
		name: 'aborted current ends without success',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '3-100', 'aborted', '', 1000 ], [ '2-90', 'done', '', 990 ]) ],
		notes: [ ABORTED ],
		waiting: false
	},
	{
		name: 'aborted previous ends without success',
		start: startOut(A, 3, 100, 1000),
		steps: [ status(A, [ '4-200', 'done', '', 1003 ], [ '3-100', 'aborted', '', 1000 ]) ],
		notes: [ ABORTED ],
		waiting: false
	},
	{
		name: 'backward clock: equal or lower reset_ts of another request is no completion',
		start: startOut(A, 3, 100, 1000),
		steps: [
			status(A, [ '2-90', 'done', '', 1000 ], null),
			status(A, [ '2-90', 'done', '', 995 ], [ '1-80', 'done', '', 1000 ]),
			status(A, [ '2-90', 'failed', 'fan', 2000 ], [ '1-80', 'done', '', 1000 ])
		],
		notes: [],
		waiting: true
	},
	{
		name: 'joined start waits for the joined id',
		start: startOut(A, 3, 100, 990, true),
		steps: [
			status(A, [ '3-100', 'running', '', 990 ], [ '2-90', 'done', '', 980 ]),
			status(A, [ '3-100', 'busy', '', 990 ], [ '2-90', 'done', '', 980 ])
		],
		notes: [ [ 'warning', 'The daemon is busy with a stage action, try again in a minute.' ] ],
		waiting: false
	},
	{
		name: 'joined start is not ended by the request it did not join',
		start: startOut(A, 3, 100, 990, true),
		steps: [ status(A, [ '2-90', 'done', '', 990 ], [ '1-80', 'done', '', 980 ]) ],
		notes: [],
		waiting: true
	},
	{
		name: 'a start without request id never reports success',
		start: 'reset_ts=1000\n',
		steps: [ status(A, [ '3-100', 'done', '', 1000 ], null), { advance: 501 }, null ],
		notes: [ UNKNOWN ],
		waiting: false
	},
	{
		name: 'a status without instance keeps waiting',
		start: startOut(A, 3, 100, 1000),
		steps: [ status('', [ '3-100', 'done', '', 1000 ], null) ],
		notes: [],
		waiting: true
	},
	{
		name: 'a new boot without a request record is a restart',
		start: startOut(A, 3, 100, 1000),
		steps: [ withBoot(status('', null, null), B) ],
		notes: [ RESTARTED ],
		waiting: false
	},
	{
		name: 'this boot without a request record keeps waiting',
		start: startOut(A, 3, 100, 1000),
		steps: [ withBoot(status('', null, null), A) ],
		notes: [],
		waiting: true
	},
	{
		name: 'this boot with its own result still completes',
		start: startOut(A, 3, 100, 1000),
		steps: [ withBoot(status(A, [ '3-100', 'done', '', 1000 ], null), A) ],
		notes: [ CLEARED ],
		waiting: false
	},
	{
		name: 'a failed clear keeps its list after a stage emptied the warning',
		start: startOut(A, 3, 100, 1000),
		steps: [ withWarning(status(A, [ '3-100', 'failed', 'wifi_off', 1000 ], null), '') ],
		notes: [ [ 'warning', 'Clearing could not undo everything. Still in force: wifi_off' ] ],
		waiting: false
	},
	{
		name: 'a done clear names its leftover after a stage emptied the warning',
		start: startOut(A, 3, 100, 1000),
		steps: [ withWarning(status(A, [ '3-100', 'done', 'wifi_off', 1000 ], null), '') ],
		notes: [ [ 'info',
			'Protection stages cleared. Still in force from an earlier clear: wifi_off' ] ],
		waiting: false
	},
	{
		name: 'the current warning list is never taken for the request list',
		start: startOut(A, 3, 100, 1000),
		steps: [ withWarning(status(A, [ '3-100', 'done', '', 1000 ], null), 'fan') ],
		notes: [ CLEARED ],
		waiting: false
	},
	{
		name: 'an older daemon without the request list falls back to the warning list',
		start: startOut(A, 3, 100, 1000),
		steps: [ legacy(status(A, [ '3-100', 'failed', 'wifi_off', 1000 ], null)) ],
		notes: [ [ 'warning', 'Clearing could not undo everything. Still in force: wifi_off' ] ],
		waiting: false
	}
];

// The stage banner, from a status file as the daemon writes it.
var banners = [
	{
		name: 'a recorded fan still forced while the settings say none',
		status: 'now=1000\nstage=0\nfan_mode=none\nfan_control=pwm\n',
		banner: 'Stage 1 of 3 active: fan at full speed'
	},
	{
		name: 'no fan in control',
		status: 'now=1000\nstage=0\nfan_mode=none\nfan_control=none\n',
		banner: 'Stage 1 of 3 active: warning, fan left to its own controller'
	},
	{
		name: 'an older daemon without fan_control goes by fan_mode',
		status: 'now=1000\nstage=0\nfan_mode=none\n',
		banner: 'Stage 1 of 3 active: warning, fan left to its own controller'
	}
];

// Depth first, the text of the first strong element.
function strongText(n) {
	var i, t;
	if (n === null || typeof n !== 'object')
		return null;
	if (Array.isArray(n)) {
		for (i = 0; i < n.length; i++)
			if ((t = strongText(n[i])) !== null)
				return t;
		return null;
	}
	if (n.tag === 'strong')
		return typeof n.children === 'string' ? n.children : String(n.children);
	return strongText(n.children);
}

function runBanner(b) {
	var v = Object.create(proto);
	rendered = null;
	clock = 1000 * 1000;
	v.update({}, b.status);
	var got = strongText(rendered);
	if (got !== b.banner)
		throw new Error('banner ' + JSON.stringify(got) + ', expected ' + JSON.stringify(b.banner));
}

function same(a, b) {
	return JSON.stringify(a) === JSON.stringify(b);
}

function run(c) {
	var v = Object.create(proto);
	notes = [];
	clock = 1700000000000;
	execResult = { code: 0, stdout: c.start, stderr: '' };
	return Promise.resolve(v.handleClear()).then(function() {
		if (!same(notes, [ STARTED ]))
			throw new Error('start notes ' + JSON.stringify(notes));
		notes = [];
		c.steps.forEach(function(s) {
			if (s && typeof s.advance === 'number')
				clock += s.advance * 1000;
			else
				v.checkClear(s);
		});
		if (!same(notes, c.notes))
			throw new Error('notes ' + JSON.stringify(notes) + ', expected ' + JSON.stringify(c.notes));
		if (Boolean(v.clearWait) !== c.waiting)
			throw new Error(c.waiting ? 'wait ended' : 'still waiting');
	});
}

var failed = 0;
cases.reduce(function(p, c) {
	return p.then(function() {
		return run(c).catch(function(err) {
			failed++;
			console.log('FAIL ' + c.name + ': ' + (err && err.message || err));
		});
	});
}, Promise.resolve()).then(function() {
	var total = cases.length + banners.length;
	banners.forEach(function(b) {
		try {
			runBanner(b);
		} catch (err) {
			failed++;
			console.log('FAIL ' + b.name + ': ' + (err && err.message || err));
		}
	});
	if (failed) {
		console.log('check-monitor-clear: ' + failed + ' of ' + total + ' cases failed');
		process.exit(1);
	}
	console.log('check-monitor-clear: all ' + total + ' cases passed');
});
