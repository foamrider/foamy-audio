const test = require('node:test')
const assert = require('node:assert/strict')
const Schema = require('../Preferences.js')
const fs = require('node:fs')
const path = require('node:path')
const Prefs = require('../kit/node-loader.cjs').load('FoamyPrefs', { console: { log() {}, warn() {} } })
const manifest = require('../manifest.json')

test('manifest and panel share defaults and supported settings', () => {
  assert.deepEqual(Schema.fields, manifest.barWidget.schema)
  for (const field of Schema.fields) {
    assert.equal(Prefs.value(Schema.fields, {}, field.key), manifest.barWidget.defaults[field.key])
    assert.equal(Prefs.valid(Schema.fields, field.key, field.defaultValue), true)
  }
})

test('manifest: the id the IPC calls use, the entry point, and the stock panel it replaces', () => {
  // omarchy.clonedFrom routes the stock Super+Ctrl+A shortcut to this panel
  // and lets Omarchy put the stock widget back when this one is removed.
  assert.equal(manifest.omarchy?.clonedFrom, 'omarchy.audio')
  // `omarchy-shell foamy.audio …` and tests/runtime.py call this target.
  assert.equal(manifest.id, 'foamy.audio')
  assert.ok(fs.existsSync(path.join(__dirname, '..', manifest.entryPoints.barWidget)), manifest.entryPoints.barWidget)
  assert.deepEqual(Object.keys(manifest.barWidget.defaults).sort(), Schema.fields.map(field => field.key).sort())
})
