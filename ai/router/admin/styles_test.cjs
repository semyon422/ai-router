const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const css = readFileSync(join(__dirname, 'dashboard.css'), 'utf8');

test('decorative navigation icon styles do not leak onto usage chart SVGs', () => {
	// A global svg stroke is inherited by transparent chart-hit rectangles,
	// turning every hourly hit target into a visible black grid cell.
	assert.doesNotMatch(css, /(?:^|[},])\s*svg\s*\{/m);
	assert.match(css, /\.brand-mark svg, \.nav-link svg\s*\{/);
	assert.match(css, /\.chart-hit\s*\{\s*fill: transparent;/);
});
