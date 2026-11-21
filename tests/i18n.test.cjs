const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const en = require('../i18n/en.json');
const no = require('../i18n/no.json');
const root = path.join(__dirname, '..');
const tokens = s => [...String(s).matchAll(/%[1-9][0-9]*|\{\w+\}/g)].map(m => m[0]).sort();
const forms = v => (typeof v === 'object' ? Object.values(v) : [v]);

for (const [key, value] of Object.entries(en)) {
  assert.equal(typeof value === 'object' ? value.other : value, key, `English source key: ${key}`);
  assert.ok(Object.hasOwn(no, key), `Norwegian entry: ${key}`);
  for (const form of forms(no[key])) assert.deepEqual(tokens(form), tokens(key), key);
}
assert.deepEqual(Object.keys(no).sort(), Object.keys(en).sort());

// Every literal the plugin translates has an English catalog entry.
for (const file of fs.readdirSync(root).filter(f => f.endsWith('.qml'))) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  for (const match of text.matchAll(/FoamyI18n\.tn?\("((?:[^"\\]|\\.)*)"/g))
    assert.ok(Object.hasOwn(en, match[1]), `${file}: missing catalog entry ${match[1]}`);
}

// The AirPlay helper's fixed error texts reach FoamyI18n.t(airplayError) in
// AudioView: each needs an entry (pactl's own stderr lines stay untranslated).
const airplay = fs.readFileSync(path.join(root, 'native/src/airplay.rs'), 'utf8');
for (const match of airplay.matchAll(/(?:last_line\(&result, |refuse\(|"error": )"((?:[^"\\]|\\.)+)"/g))
  assert.ok(Object.hasOwn(en, match[1]), `airplay.rs: missing catalog entry ${match[1]}`);
