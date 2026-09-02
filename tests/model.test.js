// Unit tests for Model.js — plain-JS helpers used by the QML. Run with:
//   node --test tests/
'use strict'

const fs = require('node:fs')
const path = require('node:path')
const test = require('node:test')
const assert = require('node:assert/strict')

// Model.js is a QML `.pragma library` file: strip that line, then evaluate the
// function declarations in an isolated scope and hand them back.
function loadModel () {
  const src = fs
    .readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8')
    .replace(/^\s*\.pragma\s+library\s*$/m, '')
  const names = [
    'plainText', 'deviceGlyph', 'isProximityToken', 'rssiToPercent', 'rssiToBars',
    'tooltipMessage', 'statusBadgeColor', 'signalBarsIcon',
    'claimPollLease', 'releasePollLease', 'holdsPollLease'
  ]
  // eslint-disable-next-line no-new-func
  return new Function(`${src}\nreturn { ${names.join(', ')} }`)()
}

const g = (cp) => String.fromCodePoint(cp)

test('plainText strips markup and normalises null/undefined', () => {
  const M = loadModel()
  assert.equal(M.plainText('<b>hi</b> there'), 'hi there')
  assert.equal(M.plainText('<img src=x onerror=alert(1)>'), '')
  assert.equal(M.plainText(null), '')
  assert.equal(M.plainText(undefined), '')
  assert.equal(M.plainText(42), '42')
})

test('deviceGlyph maps known Bluetooth icon classes', () => {
  const M = loadModel()
  assert.equal(M.deviceGlyph('phone'), g(0xF011C))
  assert.equal(M.deviceGlyph('input-keyboard'), g(0xF030C))
  assert.equal(M.deviceGlyph('input-mouse'), g(0xF037D))
  assert.equal(M.deviceGlyph('audio-headphones'), g(0xF02CB))
  assert.equal(M.deviceGlyph('watch'), g(0xF0520))
  assert.equal(M.deviceGlyph('something-else'), g(0xF00AF)) // bluetooth fallback
  assert.equal(M.deviceGlyph(''), g(0xF00AF))
  assert.equal(M.deviceGlyph(null), g(0xF00AF))
})

test('isProximityToken hides desk accessories, keeps carried devices', () => {
  const M = loadModel()
  for (const icon of ['phone', 'watch', 'computer', 'unknown', '', null]) {
    assert.equal(M.isProximityToken(icon), true, `${icon} should be a token`)
  }
  for (const icon of ['input-mouse', 'input-keyboard', 'audio-headphones',
    'audio-headset', 'audio-card', 'printer', 'input-gaming']) {
    assert.equal(M.isProximityToken(icon), false, `${icon} should be hidden`)
  }
})

test('rssiToPercent clamps to 0..100 and is monotonic', () => {
  const M = loadModel()
  assert.equal(M.rssiToPercent(null), 50)
  assert.equal(M.rssiToPercent(-45), 100)
  assert.equal(M.rssiToPercent(-30), 100) // clamped
  assert.equal(M.rssiToPercent(-100), 0)
  assert.equal(M.rssiToPercent(-120), 0) // clamped
  assert.ok(M.rssiToPercent(-60) > M.rssiToPercent(-80))
})

test('tooltipMessage covers each state', () => {
  const M = loadModel()
  assert.match(M.tooltipMessage(false, 'iPhone'), /Paused/)
  assert.match(M.tooltipMessage(true, ''), /No phone paired/)
  assert.match(M.tooltipMessage(true, 'iPhone', false, null, false, 0, 3, true), /not found in Bluetooth/)
  assert.match(M.tooltipMessage(true, 'iPhone', true, -44, false, 0, 3, false), /Nearby.*-44 dBm/s)
  assert.match(M.tooltipMessage(true, 'iPhone', false, -85, true, 2, 3, false), /weak signal.*2\/3/s)
  assert.match(M.tooltipMessage(true, 'iPhone', false, null, false, 0, 3, false), /Away/)
})

test('poll lease is single-holder with a TTL takeover', () => {
  const M = loadModel() // fresh lease state per load

  assert.equal(M.claimPollLease('A', 1000), true) // first claim wins
  assert.equal(M.holdsPollLease('A'), true)
  assert.equal(M.claimPollLease('B', 1000), false) // held by A
  assert.equal(M.holdsPollLease('B'), false)

  assert.equal(M.claimPollLease('A', 5000), true) // holder renews freely
  assert.equal(M.claimPollLease('B', 5000 + 25001), true) // stale -> B takes over
  assert.equal(M.holdsPollLease('A'), false)

  M.releasePollLease('A') // releasing a lease you don't hold is a no-op
  assert.equal(M.holdsPollLease('B'), true)

  M.releasePollLease('B')
  assert.equal(M.holdsPollLease('B'), false)
  assert.equal(M.claimPollLease('C', 5000), true) // free again immediately
})
