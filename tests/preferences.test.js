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

test('invalid values cannot reach the Omarchy settings writer', () => {
  for (const [key, value] of [['unknown', true], ['language', 'invalid'], ['showPercentage', 'false'], ['scrollVolumeStep', 3]]) {
    assert.equal(Prefs.valid(Schema.fields, key, value), false)
    assert.equal(Prefs.save(null, 'foamy.audio', Schema.fields, {}, key, value).ok, false)
  }
})

test('saves inline through the bar when possible, else omarchy bar set, never setBarWidget', () => {
  const calls = []
  const bar = { shell: { updateEntryInline(id, settings) { calls.push([id, settings]); return true } } }
  const inline = Prefs.save(bar, 'foamy.audio', Schema.fields, { showPercentage: true, other: 1 }, 'showPercentage', false)
  assert.equal(inline.inline, true)
  assert.equal(JSON.stringify(calls), JSON.stringify([['foamy.audio', { showPercentage: false, other: 1 }]]))
  const cli = Prefs.save(null, 'foamy.audio', Schema.fields, {}, 'showPercentage', false)
  assert.equal(JSON.stringify(cli.command), JSON.stringify(['omarchy', 'bar', 'set', 'foamy.audio', 'showPercentage', 'false', '--json']))
  const source = fs.readFileSync(path.join(__dirname, '../Panel.qml'), 'utf8')
  assert.ok(!source.includes('setBarWidget'))
  assert.ok(!/moduleName:\s*"/.test(source), 'the host sets moduleName')
})
