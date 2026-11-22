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
  for (const form of forms(no[key])) {
    // An empty entry falls back to English, the same failure as a missing one.
    assert.ok(typeof form === 'string' && form.trim() !== '', `Norwegian text for ${key}: ${JSON.stringify(form)}`);
    assert.deepEqual(tokens(form), tokens(key), key);
  }
}
assert.deepEqual(Object.keys(no).sort(), Object.keys(en).sort());

// The value of a quoted QML literal's body: its escapes as JSON reads them,
// with \' and a bare " (fine inside '...') made JSON-safe first.
function literalValue(file, at, body) {
  let json = '';
  for (let k = 0; k < body.length; k++) {
    if (body[k] === '\\' && k + 1 < body.length) {
      json += body[k + 1] === "'" ? "'" : body[k] + body[k + 1];
      k++;
    } else json += body[k] === '"' ? '\\"' : body[k];
  }
  try {
    return JSON.parse('"' + json + '"');
  } catch (error) {
    assert.fail(`${file}: cannot read the literal at offset ${at} (${error.message})`);
  }
}

// The string literals in the arguments of one call that starts at `start`
// (just after its open parenthesis): ternaries and `||` fallbacks included.
// A template literal could hide text and parentheses from this scan.
function callLiterals(file, text, start) {
  const found = [];
  let depth = 1;
  for (let i = start; i < text.length && depth > 0; i++) {
    const c = text[i];
    if (c === '(') depth++;
    else if (c === ')') depth--;
    else if (c === '`') assert.fail(`${file}: use a plain string literal in FoamyI18n calls (offset ${i})`);
    else if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < text.length && text[j] !== c) j += text[j] === '\\' ? 2 : 1;
      found.push(literalValue(file, i, text.slice(i + 1, j)));
      i = j;
    }
  }
  return found;
}

// Every literal the plugin translates has an English catalog entry.
let calls = 0;
for (const file of fs.readdirSync(root).filter(f => f.endsWith('.qml'))) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  for (const match of text.matchAll(/FoamyI18n\.tn?\(/g)) {
    calls++;
    for (const literal of callLiterals(file, text, match.index + match[0].length))
      assert.ok(Object.hasOwn(en, literal), `${file}: missing catalog entry ${literal}`);
  }
}
assert.ok(calls >= 30, `the QML scan found only ${calls} FoamyI18n calls`);

// The helper's fixed texts reach the popup through FoamyI18n.t: AirPlay
// errors (pactl's own stderr lines stay untranslated) and the firewall's
// "error" message, which Panel.qml shows as the helper sent it. A scan that
// no longer finds a known text means the call shapes changed: fail loudly.
const literal = '"((?:[^"\\\\]|\\\\.)+)"';
function scanned(label, source, patterns, known) {
  const texts = new Set(patterns.flatMap(pattern => [...source.matchAll(new RegExp(pattern + literal, 'g'))].map(m => m[1])));
  for (const text of known) assert.ok(texts.has(text), `the ${label} scan no longer finds ${text}`);
  for (const text of texts) assert.ok(Object.hasOwn(en, text), `${label}: missing catalog entry ${text}`);
}
const rust = name => fs.readFileSync(path.join(root, 'native/src', name), 'utf8');
scanned('airplay.rs', rust('airplay.rs'), ['(?:last_line\\(&result, |refuse\\(|failed_after_routing\\(\\s*|"error": )'], [
  'Could not inspect PipeWire modules',
  'PipeWire returned an invalid AirPlay module id',
  'Could not stop AirPlay discovery',
  'Output changed, but an earlier AirPlay group could not be removed.',
  'Output changed, but the AirPlay session could not be saved.',
]);
const ufw = rust('ufw.rs');
const errorMessage = ufw.slice(ufw.indexOf('fn error_message'), ufw.indexOf('\n}\n', ufw.indexOf('fn error_message')));
scanned('ufw.rs error_message', errorMessage, ['=> '], ['Could not apply UFW rules.', 'Could not remove UFW rules.']);
scanned('ufw.rs', ufw, ['"state": "error", "message": '], ['Could not complete the UFW check.']);

// The firewall texts Settings shows for each state.
const panel = fs.readFileSync(path.join(root, 'Panel.qml'), 'utf8');
const messages = panel.match(/firewallMessages: \(\{([^}]*)\}\)/);
assert.ok(messages, 'Panel.qml firewallMessages not found');
const values = [...messages[1].matchAll(/: "((?:[^"\\]|\\.)+)"/g)].map(m => m[1]);
assert.ok(values.length >= 10, `firewallMessages has ${values.length} texts`);
for (const text of values) assert.ok(Object.hasOwn(en, text), `Panel.qml firewallMessages: missing catalog entry ${text}`);
