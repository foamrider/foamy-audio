const test = require('node:test')
const assert = require('node:assert/strict')
const Preferences = require('../Preferences.js')
const manifest = require('../manifest.json')

test('manifest and panel share defaults and supported settings', () => {
  assert.deepEqual(Preferences.fields, manifest.barWidget.schema)
  for (const field of Preferences.fields) {
    assert.equal(Preferences.value({}, field.key), manifest.barWidget.defaults[field.key])
    assert.equal(Preferences.valid(field.key, field.defaultValue), true)
  }
})
test('invalid values cannot reach the Omarchy settings writer', () => {
  for (const [key, value] of [['unknown', true], ['language', 'invalid'], ['showPercentage', 'false'], ['scrollVolumeStep', 3], ['scrollVolumeStep', '100']]) {
    assert.equal(Preferences.valid(key, value), false)
    assert.deepEqual(Preferences.saveCommand(key, value), [])
  }
})
test('writes target the foamy.audio shell.json widget through Omarchy IPC', () => {
  const command = Preferences.saveCommand('showPercentage', false)
  assert.deepEqual(command.slice(0, 5), ['omarchy-shell', 'shell', 'setBarWidget', 'foamy.audio', 'showPercentage'])
  assert.equal(JSON.parse(command[5]), false)
  assert.deepEqual(JSON.parse(command[6]), {})
  assert.deepEqual(Preferences.saveCommand('language', 'nb'), [])
})
