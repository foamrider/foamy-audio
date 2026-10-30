const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const I = require('./i18n.cjs');
const manifest = require('../manifest.json');
const root = path.join(__dirname, '..');
const tokens = s => [...String(s).matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = v => (typeof v === 'object' ? Object.values(v) : [v]);

for (const [key, value] of Object.entries(I.en)) {
  assert.equal(typeof value === 'object' ? value.other : value, key, `English source key: ${key}`);
  assert.ok(Object.hasOwn(I.no, key), `Norwegian entry: ${key}`);
  for (const form of forms(I.no[key])) assert.deepEqual(tokens(form), tokens(key), key);
}
assert.deepEqual(Object.keys(I.no).sort(), Object.keys(I.en).sort());

// Every literal the plugin translates has an English catalog entry.
for (const file of fs.readdirSync(root).filter(f => f.endsWith('.qml'))) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  for (const match of text.matchAll(/FoamyI18n\.tn?\("((?:[^"\\]|\\.)*)"/g))
    assert.ok(Object.hasOwn(I.en, match[1]), `${file}: missing catalog entry ${match[1]}`);
}

assert.equal(manifest.barWidget?.defaults?.language, undefined);
assert.equal((manifest.barWidget?.schema || []).some(f => f.key === 'language'), false);
assert.equal(I.text('Unknown %1 {name}', 'no', ['$& %2']), 'Unknown $& %2 {name}');
assert.equal(I.text('constructor', 'no'), 'constructor');
assert.ok(I.source.includes('Qt.createQmlObject'), '4.0 must not statically require a 4.5 QML type');
assert.ok(!fs.existsSync(path.join(root, 'FoamyI18n.qml')), 'the forked FoamyI18n is gone');
