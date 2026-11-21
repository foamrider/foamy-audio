const test = require('node:test')
const assert = require('node:assert/strict')
const Schema = require('../Preferences.js')
const Prefs = require('../kit/node-loader.cjs').load('FoamyPrefs', { console: { log() {}, warn() {} } })
const manifest = require('../manifest.json')

test('manifest and panel share defaults and supported settings', () => {
  assert.deepEqual(Schema.fields, manifest.barWidget.schema)
  for (const field of Schema.fields) {
    assert.equal(Prefs.value(Schema.fields, {}, field.key), manifest.barWidget.defaults[field.key])
    assert.equal(Prefs.valid(Schema.fields, field.key, field.defaultValue), true)
  }
})
